import AppKit
import SwiftUI
import WebKit

// MARK: - Твики страницы: стереть элементы, тёмная страница, без липких шапок

/// Для каждого сайта: какие элементы стёрты (CSS-селекторы), тёмная ли страница, убраны ли липкие шапки.
/// Всё применяется стилем поверх сайта — сам сайт не меняется, «Reset» возвращает как было.
final class PageTweaks: NSObject, WKScriptMessageHandler {
    static let shared = PageTweaks()

    struct Site: Codable, Equatable {
        var erased: [String] = []
        var dark = false
        var unstick = false
        var font = "default"      // default / serif / sans / mono
    }

    private(set) var sites: [String: Site] = {
        guard let d = UserDefaults.standard.data(forKey: "pageTweaks"),
              let v = try? JSONDecoder().decode([String: Site].self, from: d) else { return [:] }
        return v
    }()

    /// Действующие твики (на паузе — никаких). incognito — правки инкогнито (в памяти) видны только ему
    func site(_ url: URL?, incognito: Bool = false) -> Site { SiteSettings.shared.isPaused(url, incognito: incognito) ? Site() : raw(url, incognito: incognito) }
    func raw(_ url: URL?, incognito: Bool = false) -> Site { SiteSettings.site(url).flatMap { (incognito ? temp[$0] : nil) ?? sites[$0] } ?? Site() }

    /// Сброс сайта — и сохранённое, и правки инкогнито
    func reset(_ s: String) {
        temp.removeValue(forKey: s)
        if sites.removeValue(forKey: s) != nil, let d = try? JSONEncoder().encode(sites) { UserDefaults.standard.set(d, forKey: "pageTweaks") }
    }

    /// Правки из инкогнито — только в памяти
    private var temp: [String: Site] = [:]
    func forgetTemp() { temp = [:] }

    /// Правка из окна настроек — в сохранённые
    func updateSaved(_ s: String, _ change: (inout Site) -> Void) {
        var v = sites[s] ?? Site()
        change(&v)
        if v == Site() { sites.removeValue(forKey: s) } else { sites[s] = v }
        if let d = try? JSONEncoder().encode(sites) { UserDefaults.standard.set(d, forKey: "pageTweaks") }
    }

    func update(_ url: URL?, incognito: Bool? = nil, _ change: (inout Site) -> Void) {
        guard let s = SiteSettings.site(url) else { return }
        if incognito ?? BrowserModel.current.currentSpace.isIncognito {
            var v = temp[s] ?? sites[s] ?? Site()
            change(&v)
            temp[s] = v
            return
        }
        var v = sites[s] ?? Site()
        change(&v)
        if v == Site() { sites.removeValue(forKey: s) } else { sites[s] = v }
        if let d = try? JSONEncoder().encode(sites) { UserDefaults.standard.set(d, forKey: "pageTweaks") }
    }

    /// Обработчик — в своём мире скриптов (сайт его не видит) и слушает только главную рамку,
    /// пока идёт стирание: иначе любая рекламная рамка могла бы дописать сайту свой стиль
    func install(in c: WKUserContentController) {
        c.add(self, contentWorld: .defaultClient, name: "sfErase")
    }

    /// Страницы, где сейчас идёт стирание (Erase… нажали, Esc ещё нет)
    private var erasing = Set<ObjectIdentifier>()

    /// Селектор от выбиралки: только #id, тег.класс, :nth-of-type(n) и « > » — ни скобок стиля, ни url()
    private static func isSelector(_ s: String) -> Bool {
        s.count <= 300 && !s.isEmpty && s.unicodeScalars.allSatisfy { Self.selectorChars.contains($0) }
    }
    private static let selectorChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " #.>:()_-"))

    /// Наложить стиль сайта на страницу (после загрузки и после каждой правки)
    func apply(_ wv: WKWebView) {
        let s = site(wv.url, incognito: BrowserModel.isIncognito(wv))
        var css = s.erased.map { "\($0){display:none!important}" }.joined(separator: "\n")
        if s.font != "default" {
            // Свой шрифт для текста (значки-шрифты и код не трогаем)
            let f = s.font == "serif" ? "\"New York\", \"Iowan Old Style\", Georgia, serif"
                  : s.font == "mono" ? "ui-monospace, Menlo, monospace" : "-apple-system, \"SF Pro Text\", Helvetica, sans-serif"
            css += "\n:is(p,li,h1,h2,h3,h4,h5,h6,blockquote,td,th,dd,dt,label,a,article,section,figcaption,input,textarea,button):not([class*=icon]):not([class*=fa-]) { font-family: \(f) !important; }"
        }
        if s.dark {
            // Мягкая тёмная тема: фон и текст — по ползункам (не чисто чёрный и не чисто белый),
            // картинки и видео не трогаем — меняются только цвета фона, текста и рамок
            let bg = Self.gray(Self.darkBg), bg2 = Self.gray(Self.darkBg + 0.05), fg = Self.gray(Self.darkFg)
            let mute = Self.gray((Self.darkBg + Self.darkFg) / 2)
            css += """

            html, body { background-color: \(bg) !important; color: \(fg) !important; }
            body *:not(img):not(video):not(picture):not(canvas):not(svg):not(iframe) {
              background-color: transparent !important; color: \(fg) !important; border-color: \(mute) !important;
              text-shadow: none !important; box-shadow: none !important; }
            input, textarea, select, button, [role=button], dialog, [role=dialog], pre, code {
              background-color: \(bg2) !important; }
            a, a * { color: #8fb4f0 !important; }
            svg:not([fill]) { fill: \(fg); }
            """
        }
        let js = """
        (function(){
          var s = document.getElementById('sf-tweaks');
          if (!s) { s = document.createElement('style'); s.id = 'sf-tweaks'; (document.head || document.documentElement).appendChild(s); }
          s.textContent = \(Self.quote(css));
          \(s.unstick ? Self.unstickJS : "")
        })();
        """
        wv.evaluateJavaScript(js)
    }

    /// Режим «стереть»: наводишь — элемент подсвечивается, кликаешь — пропадает на этом сайте. Esc — выход.
    func startErasing(_ wv: WKWebView) {
        erasing.insert(ObjectIdentifier(wv))
        wv.evaluateJavaScript(Self.pickerJS, in: nil, in: .defaultClient) { _ in }
        wv.window?.makeFirstResponder(wv)
        BrowserModel.shared.showToast("Click elements to erase · Esc to finish")
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let wv = message.webView, message.frameInfo.isMainFrame, erasing.contains(ObjectIdentifier(wv)),
              let sel = message.body as? String else { return }
        if sel == "stop" { erasing.remove(ObjectIdentifier(wv)); return }
        guard Self.isSelector(sel) else { return }
        update(wv.url, incognito: BrowserModel.isIncognito(wv)) { if !$0.erased.contains(sel) { $0.erased.append(sel) } }
        apply(wv)
    }

    /// Мягкая тёмная тема: яркость фона и текста (общие для всех сайтов)
    static var darkBg: Double { let v = UserDefaults.standard.object(forKey: "darkBg") as? Double; return v ?? 0.14 }
    static var darkFg: Double { let v = UserDefaults.standard.object(forKey: "darkFg") as? Double; return v ?? 0.8 }
    private static func gray(_ v: Double) -> String {
        // Чуть тёплый серый — спокойнее для глаз, чем нейтральный
        let c = NSColor(hue: 0.08, saturation: 0.06, brightness: max(0, min(1, v)), alpha: 1).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    private static func quote(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s])
        let a = d.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(a.dropFirst().dropLast())
    }

    /// Липкие шапки и плашки (position: fixed / sticky у верхнего или нижнего края) — в обычный поток
    private static let unstickJS = """
    (function un(){
      var all = document.querySelectorAll('body *'), h = innerHeight;
      for (var i = 0; i < all.length && i < 6000; i++) {
        var e = all[i], p = getComputedStyle(e).position;
        if (p !== 'fixed' && p !== 'sticky') continue;
        var r = e.getBoundingClientRect();
        if (r.height > h * 0.6) continue;              // не трогаем полноэкранные слои (модальные окна)
        if (r.top <= 2 || r.bottom >= h - 2) e.style.setProperty('position', p === 'fixed' ? 'absolute' : 'static', 'important');
      }
      if (!window.__sfUnstick) { window.__sfUnstick = 1; var t; addEventListener('scroll', function(){ clearTimeout(t); t = setTimeout(un, 300); }, {passive: true}); }
    })();
    """

    private static let pickerJS = """
    (function(){
      if (window.__sfPick) return;
      var box = document.createElement('div');
      box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border:2px solid #ff3b30;background:rgba(255,59,48,.12);border-radius:4px;transition:all .06s';
      document.documentElement.appendChild(box);
      var cur = null;
      function sel(e){
        if (e.id && /^[A-Za-z][\\w-]*$/.test(e.id) && document.querySelectorAll('#' + e.id).length === 1) return '#' + e.id;
        var parts = [];
        while (e && e.nodeType === 1 && e !== document.body && parts.length < 5) {
          var s = e.tagName.toLowerCase();
          var cls = Array.prototype.filter.call(e.classList, function(c){ return /^[A-Za-z][\\w-]{1,40}$/.test(c) && !/\\d{3,}/.test(c); }).slice(0, 2);
          if (cls.length) s += '.' + cls.join('.');
          var p = e.parentElement;
          if (p) { var same = Array.prototype.filter.call(p.children, function(x){ return x.tagName === e.tagName; });
            if (same.length > 1 && !cls.length) s += ':nth-of-type(' + (same.indexOf(e) + 1) + ')'; }
          parts.unshift(s);
          if (e.id && /^[A-Za-z][\\w-]*$/.test(e.id)) { parts[0] = '#' + e.id; break; }
          e = p;
        }
        return parts.join(' > ');
      }
      function move(ev){
        var e = document.elementFromPoint(ev.clientX, ev.clientY);
        if (!e || e === box || e === document.documentElement || e === document.body) { box.style.display = 'none'; cur = null; return; }
        cur = e; var r = e.getBoundingClientRect();
        box.style.display = 'block';
        box.style.left = r.left + 'px'; box.style.top = r.top + 'px'; box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
      }
      function click(ev){
        ev.preventDefault(); ev.stopPropagation();
        if (!cur) return;
        var s = sel(cur); cur.style.setProperty('display', 'none', 'important'); box.style.display = 'none';
        try { window.webkit.messageHandlers.sfErase.postMessage(s); } catch(e){}
      }
      function stop(ev){ if (ev && ev.key && ev.key !== 'Escape') return;
        document.removeEventListener('mousemove', move, true); document.removeEventListener('click', click, true);
        document.removeEventListener('keydown', stop, true); box.remove(); window.__sfPick = null;
        try { window.webkit.messageHandlers.sfErase.postMessage('stop'); } catch(e){} }
      window.__sfPick = stop;
      document.addEventListener('mousemove', move, true);
      document.addEventListener('click', click, true);
      document.addEventListener('keydown', stop, true);
    })();
    """
}

/// Раздел «Вид страницы» в центре сайта — как блок Reader / Translate:
/// строка с темой (светлая / тёмная), шрифтом и размером; ниже переключатель «без липких шапок» и «стереть элементы».
struct PageTweakControls: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab
    @State private var tick = 0
    @State private var darkEditor = false
    @AppStorage("darkBg") private var darkBg = 0.14
    @AppStorage("darkFg") private var darkFg = 0.8

    var body: some View {
        let s = PageTweaks.shared.site(tab.url, incognito: tab.isIncognito)
        let zoom = SiteSettings.shared.prefs(tab.url, incognito: tab.isIncognito).zoom
        let _ = tick
        VStack(alignment: .leading, spacing: 8) {
            // Заголовок блока
            HStack(spacing: 8) {
                Image(systemName: "textformat").frame(width: 18)
                Text("Page Style").font(.system(size: 13, weight: .medium))
                Spacer()
                if s != PageTweaks.Site() {
                    Button("Reset") { change({ $0 = PageTweaks.Site() }, reload: true) }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            // Тема · шрифт · размер — одной строкой
            HStack(spacing: 8) {
                themeCircle(dark: false, s)
                themeCircle(dark: true, s)
                Spacer(minLength: 4)
                Picker("", selection: Binding(get: { s.font }, set: { v in change({ $0.font = v }, reload: v == "default") })) {
                    Text("Default").tag("default")
                    Text("Serif").tag("serif")
                    Text("Sans").tag("sans")
                    Text("Mono").tag("mono")
                }
                .labelsHidden().fixedSize()
                HStack(spacing: 2) {
                    Button { setZoom(zoom - 0.1) } label: { Text("A").font(.system(size: 12)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                        .help("Smaller — \(Int((zoom * 100).rounded()))%")
                    Button { setZoom(zoom + 0.1) } label: { Text("A").font(.system(size: 17)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                        .help("Larger — \(Int((zoom * 100).rounded()))%")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            // Переключатели — как Reader / Translate
            switchRow("Hide Sticky Headers", icon: "pin.slash", on: s.unstick) { v in change({ $0.unstick = v }, reload: !v) }
            HStack(spacing: 8) {
                Image(systemName: "eraser").frame(width: 18)
                Text("Erase Elements").font(.system(size: 13, weight: .medium))
                if !s.erased.isEmpty {
                    Text("\(s.erased.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).frame(height: 18)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .circular))
                }
                Spacer()
                if !s.erased.isEmpty {
                    Button("Restore") { change({ $0.erased = [] }, reload: true) }.controlSize(.small)
                }
                Button("Erase…") { if let wv = tab.webView { PageTweaks.shared.startErasing(wv) } }.controlSize(.small)
            }
        }
    }

    /// Кружок темы: светлая — сайт как есть, тёмная — мягкая тёмная (клик по выбранной — яркость фона и текста)
    private func themeCircle(dark: Bool, _ s: PageTweaks.Site) -> some View {
        let on = s.dark == dark
        let bg = dark ? Color(white: darkBg + 0.02) : .white, fg = dark ? Color(white: darkFg) : .black
        // Клик — применить тему; двойной клик по тёмной — яркость фона и текста
        return Circle().fill(bg)
            .overlay(Text("A").font(.system(size: 11, weight: .bold)).foregroundStyle(fg))
            .overlay(Circle().strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: on ? 2.5 : 1))
            .frame(width: 24, height: 24)
            .contentShape(Circle())
            .gesture(TapGesture(count: 2).onEnded {
                if !s.dark || !dark { change({ $0.dark = dark }, reload: !dark) }
                if dark { darkEditor = true }
            }.exclusively(before: TapGesture().onEnded {
                if s.dark != dark { change({ $0.dark = dark }, reload: !dark) }
            }))
            .help(dark ? "Dark page — double-click to adjust" : "Original")
        .popover(isPresented: Binding(get: { dark && darkEditor }, set: { darkEditor = $0 }), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Background").font(.system(size: 12)).frame(width: 80, alignment: .leading)
                    Slider(value: Binding(get: { darkBg }, set: { darkBg = $0; if let wv = tab.webView { PageTweaks.shared.apply(wv) } }), in: 0...0.4)
                }
                HStack {
                    Text("Text").font(.system(size: 12)).frame(width: 80, alignment: .leading)
                    Slider(value: Binding(get: { darkFg }, set: { darkFg = $0; if let wv = tab.webView { PageTweaks.shared.apply(wv) } }), in: 0.5...1)
                }
                Text("Images and videos stay as they are.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 300)
            .windowScheme()
        }
    }

    private func switchRow(_ title: String, icon: String, on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: set)) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func setZoom(_ z: Double) {
        let v = max(0.3, min(3, (z * 10).rounded() / 10))
        SiteSettings.shared.update(tab.url, incognito: tab.isIncognito) { $0.zoom = v }
        tab.webView?.pageZoom = v
        tick += 1
    }

    private func change(_ f: (inout PageTweaks.Site) -> Void, reload: Bool = false) {
        PageTweaks.shared.update(tab.url, incognito: tab.isIncognito, f)
        tick += 1
        if reload { tab.reload() } else if let wv = tab.webView { PageTweaks.shared.apply(wv) }
    }
}
