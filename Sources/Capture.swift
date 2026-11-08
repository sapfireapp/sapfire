import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Capture Image (как в Arc): картинка со страницы — в полном размере

/// Наводишь на картинку — она подсвечивается с размером, клик — Sapfire берёт её оригинал:
/// ссылку на полный файл (если картинка — ссылка на него), самый крупный вариант из srcset,
/// «полные» адреса известных сайтов (Twitter/X, Pinterest, Википедия, Google, YouTube, Reddit, WordPress…).
/// Качаем через саму вкладку (WKDownload): те же входы, куки и прокси/туннель, что у страницы.
/// Итог — карточка справа сверху: Copy, Save, Open, можно утащить мышью. ⇧⌘2, «⋯», правый клик.
@Observable
final class ImageCapture: NSObject, WKDownloadDelegate {
    static let shared = ImageCapture()

    struct Shot {
        let image: NSImage?
        let data: Data
        let type: UTType
        let name: String
        let source: URL?
        let pixels: CGSize
        let incognito: Bool
    }

    /// Идёт выбор картинки на странице
    private(set) var picking = false
    /// Качаем полный размер
    private(set) var busy = false
    private(set) var shot: Shot?
    /// Вкладка, к которой относится карточка
    private(set) var tabID: UUID?
    var visible: Bool { busy || shot != nil }

    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private weak var model: BrowserModel?
    @ObservationIgnored private var candidates: [URL] = []
    @ObservationIgnored private var referer: String?
    @ObservationIgnored private var current: WKDownload?
    @ObservationIgnored private var dest: URL?
    @ObservationIgnored private var mime: String?
    @ObservationIgnored private var incognito = false

    // MARK: Запуск

    /// Выбрать картинку на странице (наведение и клик)
    func pick(_ m: BrowserModel) {
        guard Module.capture.isOn, let t = m.activeTab, let wv = t.webView, t.url?.host != nil else { return }
        if picking { cancelPick(); return }
        close()
        picking = true
        run(wv, mode: "pick", model: m, tab: t)
    }

    /// Правый клик по картинке — сразу её
    func captureContextTarget(_ wv: WKWebView, model m: BrowserModel) {
        guard let t = m.tab(for: wv) else { return }
        close()
        run(wv, mode: "ctx", model: m, tab: t)
    }

    func cancelPick() {
        webView?.evaluateJavaScript("window.__sfCap && window.__sfCap.cancel()", in: nil, in: .defaultClient) { _ in }
        picking = false
    }

    func close() {
        current?.cancel { _ in }
        current = nil
        candidates = []
        busy = false
        shot = nil
    }

    private func run(_ wv: WKWebView, mode: String, model m: BrowserModel, tab t: Tab) {
        webView = wv
        model = m
        tabID = t.id
        incognito = !wv.configuration.websiteDataStore.isPersistent
        referer = t.url?.absoluteString
        wv.callAsyncJavaScript(Self.script, arguments: ["mode": mode], in: nil, in: .defaultClient) { [weak self] r in
            guard let self else { return }
            self.picking = false
            guard case .success(let v) = r, let p = v as? [String: Any] else { return }
            self.received(p)
        }
    }

    // MARK: Что пришло со страницы

    private func received(_ p: [String: Any]) {
        let kind = p["kind"] as? String
        let name = (p["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if kind == "svg", let svg = p["svg"] as? String, let d = svg.data(using: .utf8) {
            finish(data: d, mime: "image/svg+xml", source: nil, name: name ?? "Image.svg")
        } else if kind == "data", let s = p["data"] as? String, let (d, mime) = Self.decodeDataURL(s) {
            finish(data: d, mime: mime, source: nil, name: name ?? "Image")
        } else if kind == "url", let list = p["urls"] as? [String] {
            var urls: [URL] = []
            for s in list {
                guard let u = URL(string: s), ["http", "https"].contains(u.scheme ?? "") else { continue }
                for c in Self.fullSize(u) + [u] where !urls.contains(c) { urls.append(c) }
            }
            guard !urls.isEmpty else { model?.showToast("Couldn’t get this picture"); return }
            candidates = urls
            busy = true
            next()
        }
    }

    /// Следующий адрес из списка (прошлый не открылся или оказался не картинкой)
    private func next() {
        guard busy else { return }
        guard let wv = webView, !candidates.isEmpty else {
            busy = false
            model?.showToast("Couldn’t get this picture")
            return
        }
        let u = candidates.removeFirst()
        var req = URLRequest(url: u)
        req.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let r = referer { req.setValue(r, forHTTPHeaderField: "Referer") }
        wv.startDownload(using: req) { [weak self] d in
            guard let self else { return }
            self.current = d
            d.delegate = self
        }
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let type = response.mimeType ?? ""
        let ok = type.hasPrefix("image/") || type == "application/octet-stream" || type == "binary/octet-stream"
        if let h = response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { completionHandler(nil); advance(download); return }
        guard ok else { completionHandler(nil); advance(download); return }
        mime = type
        // Во временную папку — прочитаем и сразу сотрём (из инкогнито на диске ничего не остаётся)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sf-capture-\(UUID().uuidString)")
        dest = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard download === current, let url = dest else { return }
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        dest = nil
        current = nil
        guard let data, !data.isEmpty, Self.isImage(data, mime: mime) else { next(); return }
        let src = download.originalRequest?.url
        finish(data: data, mime: mime ?? "", source: src, name: src.map(Self.fileName) ?? "Image")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let d = dest { try? FileManager.default.removeItem(at: d); dest = nil }
        advance(download)
    }

    private func advance(_ download: WKDownload) {
        guard download === current else { return }
        current = nil
        DispatchQueue.main.async { self.next() }
    }

    // MARK: Готово

    private func finish(data: Data, mime: String, source: URL?, name: String) {
        busy = false
        candidates = []
        let src = CGImageSourceCreateWithData(data as CFData, nil)
        var type = UTType(mimeType: mime) ?? src.flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) } ?? .png
        if mime.isEmpty || mime.hasSuffix("octet-stream"), let s = src, let t = CGImageSourceGetType(s).flatMap({ UTType($0 as String) }) { type = t }
        var px = CGSize.zero
        if let s = src, let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] {
            px = CGSize(width: props[kCGImagePropertyPixelWidth] as? Int ?? 0, height: props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
        let img = NSImage(data: data)
        if px == .zero, let img { px = img.size }
        // Имя файла — с расширением его настоящего формата
        var n = (name as NSString).deletingPathExtension
        if n.isEmpty { n = "Image" }
        n += "." + (type.preferredFilenameExtension ?? "png")
        shot = Shot(image: img, data: data, type: type, name: n, source: source, pixels: px, incognito: incognito)
    }

    // MARK: Действия карточки

    func copy() {
        guard let s = shot else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(s.data, forType: NSPasteboard.PasteboardType(s.type.identifier))
        // Для программ, что не знают WebP/AVIF/SVG, — ещё и PNG
        if s.type != .png, let img = s.image, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
        model?.showToast("Image copied")
    }

    func save() {
        guard let s = shot else { return }
        if let dir = WebEngine.downloadFolder {
            let url = Self.unique(dir.appendingPathComponent(s.name))
            do {
                try s.data.write(to: url)
                model?.showToast("Saved to \(dir.lastPathComponent) — \(url.lastPathComponent)")
            } catch { model?.showToast("Couldn’t save the picture") }
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = s.name
            panel.allowedContentTypes = [s.type]
            if panel.runModal() == .OK, let url = panel.url { try? s.data.write(to: url) }
        }
    }

    func open() {
        guard let u = shot?.source else { return }
        model?.newTab(url: u)
    }

    /// Утащить мышью: в Finder — файлом (кроме инкогнито), в программы — картинкой
    func dragItem() -> NSItemProvider {
        guard let s = shot else { return NSItemProvider() }
        if !s.incognito {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(s.name)
            try? s.data.write(to: url)
            if let p = NSItemProvider(contentsOf: url) { return p }
        }
        return s.image.map { NSItemProvider(object: $0) } ?? NSItemProvider()
    }

    // MARK: Полный размер: известные сайты

    /// «Полные» адреса по виду ссылки (пробуем первыми; не открылся — берём как есть)
    static func fullSize(_ u: URL) -> [URL] {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false), let host = c.host?.lowercased() else { return [] }
        var out: [URL] = []
        let path = c.path
        func add(_ s: String?) { if let s, let x = URL(string: s), x != u, !out.contains(x) { out.append(x) } }
        func withPath(_ p: String, query: [URLQueryItem]? = nil) -> String? {
            var k = c; k.path = p; k.queryItems = query; return k.url?.absoluteString
        }
        if host == "pbs.twimg.com" {
            var q = (c.queryItems ?? []).filter { $0.name != "name" }
            q.append(URLQueryItem(name: "name", value: "orig"))
            c.queryItems = q; add(c.url?.absoluteString)
        } else if host.hasSuffix("pinimg.com"), let r = path.range(of: #"^/\d+x\d*/"#, options: .regularExpression) {
            add(withPath(path.replacingCharacters(in: r, with: "/originals/")))
        } else if host == "upload.wikimedia.org", path.contains("/thumb/") {
            var parts = path.components(separatedBy: "/")
            parts.removeLast()
            add(withPath(parts.joined(separator: "/").replacingOccurrences(of: "/thumb/", with: "/")))
        } else if host.hasSuffix("googleusercontent.com") || host.hasSuffix("ggpht.com") {
            if let r = u.absoluteString.range(of: #"=[swh]\d+[^/?]*$"#, options: .regularExpression) {
                add(u.absoluteString.replacingCharacters(in: r, with: "=s0"))
            }
        } else if host == "i.ytimg.com" || host.hasSuffix(".ytimg.com") {
            if let r = path.range(of: #"(hq|mq|sd)?default(_live)?\.(jpg|webp)$"#, options: .regularExpression) {
                add(withPath(path.replacingCharacters(in: r, with: "maxresdefault.jpg"), query: nil))
            }
        } else if host == "preview.redd.it" || host == "external-preview.redd.it" {
            if host == "preview.redd.it" { add("https://i.redd.it" + path) }
        } else if host.hasSuffix("wp.com") || host.hasSuffix("wordpress.com") {
            add(withPath(path, query: nil))
        }
        // WordPress и многие CMS: имя-300x200.jpg → имя.jpg; Shopify: имя_600x.jpg → имя.jpg
        if let r = path.range(of: #"-\d{2,4}x\d{2,4}(?=\.[A-Za-z]{3,4}$)"#, options: .regularExpression) {
            add(withPath(path.replacingCharacters(in: r, with: ""), query: c.queryItems))
        }
        if host.contains("shopify"), let r = path.range(of: #"_\d*x\d*(?=\.[A-Za-z]{3,4}$)"#, options: .regularExpression) {
            add(withPath(path.replacingCharacters(in: r, with: ""), query: nil))
        }
        // Размер в параметрах (?w=400&h=300, ?width=…, ?resize=…) — без них
        let sizeKeys: Set<String> = ["w", "h", "width", "height", "resize", "size", "fit", "crop", "quality", "q", "dpr"]
        if let q = c.queryItems, q.contains(where: { sizeKeys.contains($0.name.lowercased()) }) {
            let rest = q.filter { !sizeKeys.contains($0.name.lowercased()) }
            add(withPath(path, query: rest.isEmpty ? nil : rest))
        }
        return out
    }

    // MARK: Мелочи

    private static func decodeDataURL(_ s: String) -> (Data, String)? {
        guard s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") else { return nil }
        let head = s[s.index(s.startIndex, offsetBy: 5)..<comma]
        let mime = head.split(separator: ";").first.map(String.init) ?? "image/png"
        let body = String(s[s.index(after: comma)...])
        if head.contains("base64") { return Data(base64Encoded: body).map { ($0, mime) } }
        return body.removingPercentEncoding?.data(using: .utf8).map { ($0, mime) }
    }

    private static func isImage(_ d: Data, mime: String?) -> Bool {
        if mime == "image/svg+xml" { return true }
        if let s = CGImageSourceCreateWithData(d as CFData, nil), CGImageSourceGetCount(s) > 0 { return true }
        return NSImage(data: d) != nil
    }

    private static func fileName(_ u: URL) -> String {
        let n = u.lastPathComponent
        return n.isEmpty || n == "/" ? (u.host ?? "Image") : (n.removingPercentEncoding ?? n)
    }

    private static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for i in 2... {
            let u = url.deletingLastPathComponent().appendingPathComponent("\(base) \(i)" + (ext.isEmpty ? "" : ".\(ext)"))
            if !fm.fileExists(atPath: u.path) { return u }
        }
        return url
    }

    /// Правый клик — какой элемент под курсором (в своём мире скриптов, странице не видно)
    static let contextScript = WKUserScript(source: """
    document.addEventListener('contextmenu', function(e){ window.__sfCtxEl = e.target; }, true);
    """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)

    /// Выбор картинки на странице. Возвращает {kind: url|data|svg, urls, data, svg, name} или null (Esc).
    static let script = #"""
    const IMG_EXT = /\.(jpe?g|png|gif|webp|avif|bmp|tiff?|heic|svg)(\?|#|$)/i;
    function bgURL(el) {
      if (!(el instanceof Element)) return null;
      const b = getComputedStyle(el).backgroundImage;
      if (!b || b === 'none') return null;
      const m = b.match(/url\(["']?(.*?)["']?\)/);
      return m ? m[1] : null;
    }
    function srcset(ss) {
      const out = []; if (!ss) return out;
      const re = /\s*([^\s,][^\s]*?)(?:\s+([\d.]+)([wx]))?\s*(?:,|$)/g; let m;
      while ((m = re.exec(ss)) && m[0]) { out.push({url: m[1], score: m[2] ? parseFloat(m[2]) * (m[3] === 'x' ? 1000 : 1) : 1}); }
      return out;
    }
    function abs(u) { try { return new URL(u, document.baseURI).href; } catch (e) { return null; } }
    function big(r) { return r.width >= 16 && r.height >= 16; }
    // Что под точкой: картинка, svg, холст, видео или фон
    function candidate(stack) {
      for (const el of stack) {
        if (el.id === '__sfCapBox' || el.id === '__sfCapTag') continue;
        const r = el.getBoundingClientRect(); if (!big(r)) continue;
        if (el.tagName === 'IMG') return {el, kind: 'img', w: el.naturalWidth, h: el.naturalHeight};
        if (el.tagName === 'CANVAS') return {el, kind: 'canvas', w: el.width, h: el.height};
        if (el.tagName === 'VIDEO') return {el, kind: 'video', w: el.videoWidth, h: el.videoHeight};
        const svg = el.closest && el.closest('svg');
        if (svg && !svg.ownerSVGElement) { const s = svg.getBoundingClientRect(); if (big(s)) return {el: svg, kind: 'svg', w: Math.round(s.width), h: Math.round(s.height)}; }
        const bg = bgURL(el);
        if (bg && !bg.startsWith('data:image/svg')) return {el, kind: 'bg', url: bg, w: Math.round(r.width), h: Math.round(r.height)};
      }
      return null;
    }
    function toData(url) {
      return fetch(url).then(r => r.blob()).then(b => new Promise(res => { const f = new FileReader(); f.onload = () => res(f.result); f.readAsDataURL(b); }));
    }
    async function payload(c) {
      const el = c.el;
      const name = (el.getAttribute && (el.getAttribute('alt') || el.getAttribute('title') || el.getAttribute('aria-label'))) || '';
      if (c.kind === 'svg') {
        const s = el.cloneNode(true);
        if (!s.getAttribute('xmlns')) s.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
        const r = el.getBoundingClientRect();
        if (!s.getAttribute('width')) s.setAttribute('width', Math.round(r.width));
        if (!s.getAttribute('height')) s.setAttribute('height', Math.round(r.height));
        return {kind: 'svg', svg: s.outerHTML, name};
      }
      if (c.kind === 'canvas') { try { return {kind: 'data', data: el.toDataURL('image/png'), name}; } catch (e) { return null; } }
      if (c.kind === 'video') {
        try {
          const cv = document.createElement('canvas'); cv.width = el.videoWidth; cv.height = el.videoHeight;
          cv.getContext('2d').drawImage(el, 0, 0); return {kind: 'data', data: cv.toDataURL('image/png'), name};
        } catch (e) { return el.poster ? {kind: 'url', urls: [abs(el.poster)], name} : null; }
      }
      let urls = [];
      if (c.kind === 'img') {
        // Картинка — ссылка на свой полный файл
        const a = el.closest('a[href]'); if (a && IMG_EXT.test(a.href)) urls.push(a.href);
        const list = srcset(el.getAttribute('srcset'));
        const pic = el.closest('picture');
        if (pic) for (const s of pic.querySelectorAll('source')) list.push(...srcset(s.getAttribute('srcset')));
        list.sort((x, y) => y.score - x.score);
        for (const s of list) urls.push(abs(s.url));
        urls.push(el.currentSrc, el.src);
      } else urls.push(abs(c.url));
      urls = urls.filter((u, i) => u && urls.indexOf(u) === i);
      const first = urls[0] || '';
      if (first.startsWith('blob:') || first.startsWith('data:')) {
        try { return {kind: 'data', data: await toData(first), name}; } catch (e) { return null; }
      }
      return {kind: 'url', urls, name};
    }
    if (mode === 'ctx') {
      const t = window.__sfCtxEl; if (!t) return null;
      const r = t.getBoundingClientRect();
      const c = candidate([t, ...document.elementsFromPoint(r.left + r.width / 2, r.top + r.height / 2)]);
      return c ? await payload(c) : null;
    }
    // Выбор мышью: рамка с размером, клик — взять, Esc — отмена
    if (window.__sfCap) window.__sfCap.cancel();
    return await new Promise(resolve => {
      const box = document.createElement('div'); box.id = '__sfCapBox';
      box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border:2px solid #3b82f6;border-radius:6px;background:rgba(59,130,246,.14);box-shadow:0 0 0 1px rgba(255,255,255,.6);transition:all .08s ease-out;display:none';
      const tag = document.createElement('div'); tag.id = '__sfCapTag';
      tag.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;font:600 11px -apple-system,system-ui;color:#fff;background:#3b82f6;padding:2px 7px;border-radius:9px;display:none';
      document.documentElement.append(box, tag);
      const cursor = document.documentElement.style.cursor;
      document.documentElement.style.cursor = 'crosshair';
      let cur = null, lx = -1, ly = -1;
      function show(x, y) {
        lx = x; ly = y;
        cur = candidate(document.elementsFromPoint(x, y));
        if (!cur) { box.style.display = tag.style.display = 'none'; return; }
        const r = cur.el.getBoundingClientRect();
        Object.assign(box.style, {display: 'block', left: r.left - 2 + 'px', top: r.top - 2 + 'px', width: r.width + 'px', height: r.height + 'px'});
        tag.textContent = cur.w && cur.h ? cur.w + ' × ' + cur.h : 'Image';
        Object.assign(tag.style, {display: 'block', left: Math.max(4, r.left + 6) + 'px', top: Math.max(4, r.top + 6) + 'px'});
      }
      const move = e => show(e.clientX, e.clientY);
      const scroll = () => { if (lx >= 0) show(lx, ly); };
      const block = e => { e.preventDefault(); e.stopImmediatePropagation(); };
      const click = async e => { block(e); const c = cur; if (!c) return; done(); resolve(await payload(c)); };
      const key = e => { if (e.key === 'Escape') { block(e); done(); resolve(null); } };
      function done() {
        removeEventListener('mousemove', move, true); removeEventListener('scroll', scroll, true);
        removeEventListener('click', click, true); removeEventListener('keydown', key, true);
        for (const t of ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'contextmenu']) removeEventListener(t, block, true);
        box.remove(); tag.remove(); document.documentElement.style.cursor = cursor; window.__sfCap = null;
      }
      addEventListener('mousemove', move, true); addEventListener('scroll', scroll, true);
      addEventListener('click', click, true); addEventListener('keydown', key, true);
      for (const t of ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'contextmenu']) addEventListener(t, block, true);
      window.__sfCap = { cancel() { done(); resolve(null); } };
    });
    """#
}

// MARK: - Карточка

/// Взятая картинка — карточкой справа сверху: превью, размер, Copy / Save / Open; утащить мышью
struct CaptureCard: View {
    @Environment(BrowserModel.self) private var model
    @State private var cap = ImageCapture.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "photo").foregroundStyle(Color.accentColor)
                Text(cap.shot?.name ?? "Getting full size…").font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button { cap.close() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close — Esc")
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()
            if let s = cap.shot {
                Group {
                    if let img = s.image {
                        Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.tertiary).frame(height: 120)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 300)
                .padding(12)
                .onDrag { cap.dragItem() }
                .help("Drag the picture to Finder or another app")
                Text(info(s)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                HStack(spacing: 8) {
                    Button("Copy") { cap.copy() }
                    Button("Save") { cap.save() }
                    if s.source != nil { Button("Open in Tab") { cap.open() } }
                    Spacer()
                }
                .controlSize(.small)
                .padding(14)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Getting the full-size picture…").foregroundStyle(.secondary) }
                    .font(.system(size: 12))
                    .padding(14)
            }
        }
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .circular))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .circular).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
    }

    private func info(_ s: ImageCapture.Shot) -> String {
        var parts: [String] = []
        if s.pixels.width > 0 { parts.append("\(Int(s.pixels.width)) × \(Int(s.pixels.height))") }
        parts.append((s.type.preferredFilenameExtension ?? "image").uppercased())
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(s.data.count), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

/// Пока выбираешь картинку — подсказка сверху
struct CaptureHint: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "viewfinder")
            Text("Click a picture to capture it at full size · Esc to cancel")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14).frame(height: 30)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }
}
