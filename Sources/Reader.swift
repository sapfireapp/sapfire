import AppKit
import SwiftUI
import WebKit

// MARK: - Режим чтения (⌥⌘R)

/// Статья страницы — чистым текстом поверх неё: без рекламы, меню и всплывашек.
/// Собирается прямо на странице (без сети и без сторонних библиотек), страница под ним не меняется —
/// выключил, и всё как было. Вид (размер, шрифт, тема) общий для всех сайтов.
enum Reader {
    static let sizeKey = "readerSize", themeKey = "readerTheme", fontKey = "readerFont"

    static var size: Int { let v = UserDefaults.standard.integer(forKey: sizeKey); return v == 0 ? 19 : v }
    static var font: String { UserDefaults.standard.string(forKey: fontKey) ?? "serif" }   // serif / sans

    /// Пресет: цвета страницы. Четыре штуки, каждый можно перекрасить.
    struct HSV: Codable, Equatable { var h: Double; var s: Double; var v: Double
        var color: Color { Color(hue: h, saturation: s, brightness: v) }
        var hex: String {
            let c = NSColor(hue: h, saturation: s, brightness: v, alpha: 1).usingColorSpace(.sRGB) ?? .white
            return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
    }
    struct Preset: Codable, Equatable { var bg: HSV; var text: HSV; var link: HSV; var muted: HSV }
    static let presetIDs = ["light", "sepia", "gray", "dark"]
    static let defaults: [String: Preset] = [
        "light": Preset(bg: HSV(h: 0, s: 0, v: 1), text: HSV(h: 0.66, s: 0.06, v: 0.12), link: HSV(h: 0.59, s: 0.95, v: 0.82), muted: HSV(h: 0.66, s: 0.03, v: 0.45)),
        "sepia": Preset(bg: HSV(h: 0.11, s: 0.09, v: 0.97), text: HSV(h: 0.1, s: 0.38, v: 0.29), link: HSV(h: 0.07, s: 0.7, v: 0.6), muted: HSV(h: 0.1, s: 0.3, v: 0.54)),
        "gray": Preset(bg: HSV(h: 0.6, s: 0.03, v: 0.32), text: HSV(h: 0.1, s: 0.05, v: 0.88), link: HSV(h: 0.58, s: 0.4, v: 0.95), muted: HSV(h: 0.6, s: 0.04, v: 0.65)),
        "dark": Preset(bg: HSV(h: 0.66, s: 0.05, v: 0.12), text: HSV(h: 0.1, s: 0.05, v: 0.84), link: HSV(h: 0.59, s: 0.45, v: 0.98), muted: HSV(h: 0.66, s: 0.04, v: 0.58)),
    ]
    static var theme: String {
        let t = UserDefaults.standard.string(forKey: themeKey) ?? "light"
        return presetIDs.contains(t) ? t : "light"
    }
    static func preset(_ id: String) -> Preset {
        if let d = UserDefaults.standard.data(forKey: "readerPreset." + id), let p = try? JSONDecoder().decode(Preset.self, from: d) { return p }
        return defaults[id] ?? defaults["light"]!
    }
    static func save(_ p: Preset, _ id: String) {
        if p == defaults[id] { UserDefaults.standard.removeObject(forKey: "readerPreset." + id) }
        else if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: "readerPreset." + id) }
    }

    /// Включить / выключить на вкладке
    static func toggle(_ tab: Tab?) {
        guard let wv = tab?.webView else { return }
        wv.evaluateJavaScript(script + "window.__sfReader.toggle(\(options));") { r, _ in
            if (r as? String) == "none" { BrowserModel.shared.showToast("No article found on this page") }
        }
    }

    static func show(_ wv: WKWebView) {
        wv.evaluateJavaScript(script + "window.__sfReader.show(\(options));")
    }

    /// Поменялся вид — перерисовать, если режим чтения открыт
    static func restyle(_ tab: Tab?) {
        tab?.webView?.evaluateJavaScript(script + "window.__sfReader.restyle(\(options));")
    }

    private static var options: String {
        let p = preset(theme)
        return "{size: \(size), font: '\(font)', bg: '\(p.bg.hex)', fg: '\(p.text.hex)', link: '\(p.link.hex)', mute: '\(p.muted.hex)'}"
    }

    private static let script = """
    if (!window.__sfReader) window.__sfReader = (function(){
      var HOST = null;
      function score(el){
        var ps = el.querySelectorAll('p'), n = 0, t = 0;
        for (var i = 0; i < ps.length; i++) { var l = ps[i].innerText.trim().length; if (l > 60) { n++; t += l; } }
        var bad = /comment|footer|sidebar|nav|menu|related|share|promo|ad-|advert/i.test((el.className || '') + ' ' + (el.id || ''));
        return (t + n * 60) * (bad ? 0.2 : 1);
      }
      function pick(){
        var c = Array.prototype.slice.call(document.querySelectorAll('article, main, [role=main], .post, .article, .entry-content, .content, #content, section, div'));
        var best = null, bs = 0;
        for (var i = 0; i < c.length && i < 4000; i++) { var s = score(c[i]); if (s > bs) { bs = s; best = c[i]; } }
        // Предпочитаем самый узкий блок, где почти весь текст статьи
        if (best) { var ch = best.children; for (var j = 0; j < ch.length; j++) { if (score(ch[j]) > bs * 0.85) { best = ch[j]; bs = score(best); j = -1; ch = best.children; } } }
        return bs > 600 ? best : null;
      }
      function clean(root){
        var kill = root.querySelectorAll('script,style,noscript,iframe,form,button,input,select,textarea,nav,aside,footer,header,svg,canvas,[aria-hidden=true],.ad,.ads,.advert,.share,.social,.related,.comments');
        for (var i = 0; i < kill.length; i++) kill[i].remove();
        var all = root.querySelectorAll('*');
        for (var k = 0; k < all.length; k++) {
          var e = all[k];
          ['style','class','id','width','height','align','bgcolor','onclick'].forEach(function(a){ e.removeAttribute(a); });
          if (e.tagName === 'IMG') { var s = e.getAttribute('data-src') || e.getAttribute('data-lazy-src'); if (s) e.src = s; e.removeAttribute('srcset'); e.loading = 'lazy'; }
        }
        return root;
      }
      function css(o){
        var bg = o.bg, fg = o.fg, mute = o.mute, link = o.link;
        var font = o.font === 'sans' ? '-apple-system, "SF Pro Text", Helvetica, sans-serif' : '"New York", "Iowan Old Style", Georgia, serif';
        return ':host{all:initial}' +
          '.sf-wrap{position:fixed;inset:0;z-index:2147483647;overflow-y:auto;background:' + bg + ';color:' + fg + ';font-family:' + font + ';-webkit-font-smoothing:antialiased}' +
          '.sf-art{max-width:680px;margin:0 auto;padding:56px 28px 120px;font-size:' + o.size + 'px;line-height:1.62}' +
          '.sf-site{font:600 12px -apple-system,sans-serif;letter-spacing:.06em;text-transform:uppercase;color:' + mute + ';margin-bottom:10px}' +
          'h1.sf-title{font-size:1.9em;line-height:1.18;margin:0 0 28px;font-weight:700}' +
          '.sf-art img,.sf-art video,.sf-art figure{max-width:100%;height:auto;border-radius:10px;margin:18px 0}' +
          '.sf-art a{color:' + link + ';text-decoration:none}' +
          '.sf-art h2,.sf-art h3{line-height:1.25;margin:1.6em 0 .6em}' +
          '.sf-art pre,.sf-art code{font-family:ui-monospace,Menlo,monospace;font-size:.85em;background:rgba(127,127,127,.12);border-radius:6px}' +
          '.sf-art pre{padding:12px;overflow:auto}' +
          '.sf-art blockquote{margin:1.2em 0;padding-left:1em;border-left:3px solid ' + mute + ';color:' + mute + '}' +
          '.sf-art figcaption{font-size:.8em;color:' + mute + '}' +
          '.sf-art table{border-collapse:collapse;font-size:.9em}.sf-art td,.sf-art th{border:1px solid rgba(127,127,127,.3);padding:4px 8px}';
      }
      function build(o){
        var src = pick(); if (!src) return false;
        var art = clean(src.cloneNode(true));
        HOST = document.createElement('sapfire-reader');
        var root = HOST.attachShadow({mode: 'open'});
        var st = document.createElement('style'); st.textContent = css(o); root.appendChild(st);
        var wrap = document.createElement('div'); wrap.className = 'sf-wrap';
        var a = document.createElement('div'); a.className = 'sf-art';
        var site = document.createElement('div'); site.className = 'sf-site'; site.textContent = location.hostname.replace(/^www\\./, '');
        var h = document.createElement('h1'); h.className = 'sf-title';
        var og = document.querySelector('meta[property="og:title"]');
        h.textContent = (document.querySelector('h1') || {}).innerText || (og && og.content) || document.title;
        var dup = art.querySelector('h1'); if (dup && dup.innerText.trim() === h.textContent.trim()) dup.remove();
        a.appendChild(site); a.appendChild(h); a.appendChild(art); wrap.appendChild(a); root.appendChild(wrap);
        document.documentElement.appendChild(HOST);
        document.documentElement.style.setProperty('overflow', 'hidden', 'important');
        return true;
      }
      function hide(){
        if (HOST) { HOST.remove(); HOST = null; document.documentElement.style.removeProperty('overflow'); }
      }
      return {
        show: function(o){ if (HOST) return 'on'; return build(o) ? 'on' : 'none'; },
        toggle: function(o){ if (HOST) { hide(); return 'off'; } return build(o) ? 'on' : 'none'; },
        restyle: function(o){ if (!HOST) return 'off'; var st = HOST.shadowRoot.querySelector('style'); st.textContent = css(o); return 'on'; },
        isOn: function(){ return !!HOST; }
      };
    })();
    """
}

/// Вид режима чтения — в центре сайта (Page): четыре пресета цветов, размер, шрифт
struct ReaderControls: View {
    @Environment(BrowserModel.self) private var model
    @AppStorage(Reader.sizeKey) private var size = 19
    @AppStorage(Reader.themeKey) private var theme = "light"
    @AppStorage(Reader.fontKey) private var font = "serif"
    @State private var editing: String?      // пресет, чьи цвета открыты
    @State private var tick = 0              // пресет перекрасили — перерисовать кружки
    @State private var readerOn = 0          // чтение включили кружком — обновить переключатель

    var body: some View {
        let _ = tick
        VStack(alignment: .leading, spacing: 8) {
            // Режим — переключателем (включён / выключен на этой странице)
            ModeToggle(title: "Reader", icon: "doc.plaintext", shortcut: "⌥⌘R", query: "window.__sfReader && window.__sfReader.isOn()",
                       always: Binding(get: { SiteSettings.shared.raw(model.activeTab?.url, incognito: model.activeTab?.isIncognito ?? false).reader },
                                       set: { v in SiteSettings.shared.update(model.activeTab?.url, incognito: model.activeTab?.isIncognito ?? false) { $0.reader = v } })) {
                model.toggleReader()
            }
            .id(readerOn)
            // Пресеты, шрифт и размер текста — одной строкой
            HStack(spacing: 8) {
                // Пресеты: клик — выбрать и открыть его цвета
                ForEach(Reader.presetIDs, id: \.self) { id in
                    let p = Reader.preset(id)
                    // Клик — открыть чтение в этом пресете; двойной клик — настроить его цвета
                    Circle().fill(p.bg.color)
                        .overlay(Text("A").font(.system(size: 11, weight: .bold)).foregroundStyle(p.text.color))
                        .overlay(Circle().strokeBorder(theme == id ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: theme == id ? 2.5 : 1))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                        .gesture(TapGesture(count: 2).onEnded {
                            theme = id
                            Reader.restyle(model.activeTab)
                            editing = id
                        }.exclusively(before: TapGesture().onEnded {
                            theme = id
                            if let wv = model.activeTab?.webView { Reader.show(wv); Reader.restyle(model.activeTab) }
                            readerOn += 1
                        }))
                        .help("\(id.capitalized) — double-click to edit colors")
                    .popover(isPresented: Binding(get: { editing == id }, set: { if !$0 { editing = nil; tick += 1 } }), arrowEdge: .bottom) {
                        ReaderPresetEditor(id: id) { editing = nil; tick += 1 }.windowScheme()
                            .environment(model)
                    }
                }
                Spacer(minLength: 4)
                Picker("", selection: Binding(get: { font }, set: { font = $0; Reader.restyle(model.activeTab) })) {
                    Text("Serif").tag("serif")
                    Text("Sans").tag("sans")
                }
                .labelsHidden().fixedSize()
                HStack(spacing: 2) {
                    Button { size = max(14, size - 1); Reader.restyle(model.activeTab) } label: {
                        Text("A").font(.system(size: 12)).frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .help("Smaller text")
                    Button { size = min(30, size + 1); Reader.restyle(model.activeTab) } label: {
                        Text("A").font(.system(size: 17)).frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .help("Larger text")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Цвета пресета: фон, текст, ссылки, второстепенный текст. Правки видны сразу и сохраняются
/// (и галочкой, и просто закрытием окна). «Reset» — вернуть пресет как был.
struct ReaderPresetEditor: View {
    @Environment(BrowserModel.self) private var model
    let id: String
    let done: () -> Void
    @State private var p: Reader.Preset
    @State private var part = "bg"

    init(id: String, done: @escaping () -> Void) {
        self.id = id
        self.done = done
        _p = State(initialValue: Reader.preset(id))
    }

    private static let parts: [(String, String)] = [("bg", "Background"), ("text", "Text"), ("link", "Links"), ("muted", "Secondary")]

    private func get(_ k: String) -> Reader.HSV {
        switch k { case "text": p.text; case "link": p.link; case "muted": p.muted; default: p.bg }
    }
    private func set(_ k: String, _ v: Reader.HSV) {
        switch k { case "text": p.text = v; case "link": p.link = v; case "muted": p.muted = v; default: p.bg = v }
        Reader.save(p, id)
        Reader.restyle(model.activeTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Что красим — с образцом цвета
            HStack(spacing: 6) {
                ForEach(Self.parts, id: \.0) { k, title in
                    Button { part = k } label: {
                        HStack(spacing: 5) {
                            Circle().fill(get(k).color)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                                .frame(width: 12, height: 12)
                            Text(title).font(.system(size: 12, weight: part == k ? .semibold : .regular))
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(part == k ? Color.primary.opacity(0.1) : .clear, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            let v = get(part)
            HSVColorBlock(hue: Binding(get: { v.h }, set: { set(part, .init(h: $0, s: v.s, v: v.v)) }),
                          sat: Binding(get: { v.s }, set: { set(part, .init(h: v.h, s: $0, v: v.v)) }),
                          bri: Binding(get: { v.v }, set: { set(part, .init(h: v.h, s: v.s, v: $0)) }),
                          allowNone: false)
                .id(part)            // своя выбранная ячейка палитры у каждой части
            HStack {
                Button("Reset") {
                    p = Reader.defaults[id] ?? p
                    Reader.save(p, id)
                    Reader.restyle(model.activeTab)
                }
                Spacer()
                Button { done() } label: { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).frame(width: 36, height: 22) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}


/// Режим страницы (чтение, перевод) — строка с переключателем; состояние берётся со страницы
struct ModeToggle: View {
    @Environment(BrowserModel.self) private var model
    let title: String
    let icon: String
    let shortcut: String
    let query: String
    /// «Always» — включать самому на этом сайте (галочка перед переключателем)
    var always: Binding<Bool>? = nil
    let toggle: () -> Void
    @State private var on = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18)
            Text(title).font(.system(size: 13, weight: .medium))
            // Сочетание клавиш — серой плашкой
            Text(shortcut).font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 5).frame(height: 18)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .circular))
            Spacer()
            if let always {
                Toggle("Always", isOn: always)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .help("Turn on by itself on this site")
            }
            Toggle("", isOn: Binding(get: { on }, set: { _ in
                toggle()
                // Страница переключится не мгновенно — перечитываем состояние
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { refresh() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { refresh() }
            }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        model.activeTab?.webView?.evaluateJavaScript(query) { r, _ in on = (r as? Bool) == true }
    }
}
