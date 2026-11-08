import AppKit
import SwiftUI
import WebKit

// MARK: - Настройки для сайта (центр сайта: клик по замку в адресной строке)

/// Что можно настроить для отдельного сайта. Хранится только то, что отличается от обычного.
struct SitePrefs: Codable, Equatable {
    var blocker = true            // блокировать рекламу и трекеры
    var javaScript = true
    var zoom: Double = 1
    var userAgent = "auto"        // auto / desktop / mobile
    var popups = "allow"          // allow / block
    var camera = "ask"            // ask / allow / deny
    var microphone = "ask"
    var downloads = "allow"       // allow / deny
    var reader = false            // всегда открывать в режиме чтения
    var translate = false         // всегда переводить
    var autoplay = "allow"        // allow / nosound (без звука — только по клику) / deny
    var cookies = true            // принимать куки
    var webFonts = true           // загружать веб-шрифты
    var externalApps = "ask"      // ask / allow / deny — ссылки, открывающие другие программы
    var screenShare = "ask"       // ask / deny
    var location = "ask"          // ask / allow / deny — местоположение
    var paused = false            // все свои настройки сайта временно выключены (не удалены)
    var fingerprint = true        // защита от отпечатка (шум в холсте, звуке…) там, где она включена; YouTube с ней через VPN просит войти

    init() {}
    // Старые сохранённые настройки — без новых полей
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = SitePrefs()
        func v<T: Decodable>(_ k: CodingKeys, _ x: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? x }
        blocker = v(.blocker, def.blocker); javaScript = v(.javaScript, def.javaScript); zoom = v(.zoom, def.zoom)
        userAgent = v(.userAgent, def.userAgent); popups = v(.popups, def.popups); camera = v(.camera, def.camera)
        microphone = v(.microphone, def.microphone); downloads = v(.downloads, def.downloads); reader = v(.reader, def.reader)
        translate = v(.translate, def.translate); autoplay = v(.autoplay, def.autoplay); cookies = v(.cookies, def.cookies)
        webFonts = v(.webFonts, def.webFonts); externalApps = v(.externalApps, def.externalApps)
        screenShare = v(.screenShare, def.screenShare); paused = v(.paused, def.paused)
        location = v(.location, def.location)
        fingerprint = v(.fingerprint, def.fingerprint)
    }
}

@Observable
final class SiteSettings {
    static let shared = SiteSettings()
    private(set) var all: [String: SitePrefs] = [:]
    private static let key = "sitePrefs"

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let v = try? JSONDecoder().decode([String: SitePrefs].self, from: d) { all = v }
    }

    /// Ключ сайта: хост без «www.»
    static func site(_ url: URL?) -> String? {
        guard var h = url?.host?.lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// Действующие настройки: на паузе — как у любого сайта (сохранённые не трогаем).
    /// incognito — для страницы инкогнито: её правки живут отдельно (в памяти) и обычным вкладкам не видны
    func prefs(_ url: URL?, incognito: Bool = false) -> SitePrefs {
        let p = raw(url, incognito: incognito)
        // Режим совместимости: всё как у любого сайта, но без блокировки рекламы и трекеров (так и обещает его описание) —
        // иначе на YouTube оставался скрипт против рекламы, и сайт показывал «блокировщики нарушают условия»
        if p.paused { var d = SitePrefs(); d.paused = true; d.blocker = false; d.fingerprint = false; return d }
        return p
    }

    /// Сохранённые настройки (для окошка — видно и на паузе)
    func raw(_ url: URL?, incognito: Bool = false) -> SitePrefs {
        guard let s = Self.site(url) else { return SitePrefs() }
        return (incognito ? temp[s] : nil) ?? all[s] ?? SitePrefs()
    }

    /// Правки, сделанные в инкогнито, — только в памяти (на диск не пишутся, стираются при закрытии)
    private var temp: [String: SitePrefs] = [:]
    func forgetTemp() { temp = [:]; changed() }

    func isPaused(_ url: URL?, incognito: Bool = false) -> Bool { raw(url, incognito: incognito).paused }

    /// incognito — чья это правка; nil — по текущему пространству
    func update(_ url: URL?, incognito: Bool? = nil, _ change: (inout SitePrefs) -> Void) {
        guard let s = Self.site(url) else { return }
        if incognito ?? BrowserModel.current.currentSpace.isIncognito {
            var p = temp[s] ?? all[s] ?? SitePrefs()
            change(&p)
            temp[s] = p
            changed()
            return
        }
        var p = all[s] ?? SitePrefs()
        change(&p)
        if p == SitePrefs() { all.removeValue(forKey: s) } else { all[s] = p }
        save()
        changed()
    }

    /// Правка из окна настроек: всегда в сохранённые (не в память инкогнито)
    func updateSaved(_ s: String, _ change: (inout SitePrefs) -> Void) {
        var p = all[s] ?? SitePrefs()
        change(&p)
        if p == SitePrefs() { all.removeValue(forKey: s) } else { all[s] = p }
        save()
        changed()
    }

    /// Сброс: удалить все свои настройки сайта (и стёртое, и вид страницы) насовсем
    func reset(_ url: URL?) {
        guard let s = Self.site(url) else { return }
        all.removeValue(forKey: s)
        temp.removeValue(forKey: s)
        PageTweaks.shared.reset(s)
        save()
        changed()
    }

    /// Правила движка и скрипты страниц — под новые настройки
    private func changed() {
        SiteRules.shared.rebuild()
        ContentBlocker.shared.compileExceptions()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(all) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
}

// MARK: - Центр сайта

struct SiteCenter: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab
    @State private var page = 1      // страница открывается первой: её настройки нужнее списка трекеров
    @State private var list = 0
    @State private var compatInfo = false
    @State private var settings = SiteSettings.shared

    var body: some View {
        let url = tab.url
        let site = SiteSettings.site(url) ?? ""
        let p = settings.raw(url, incognito: tab.isIncognito)
        let paused = p.paused
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Favicon(url: url).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(site).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(url?.scheme == "https" ? "Secure connection" : "Not secure")
                        .font(.system(size: 11))
                        .foregroundStyle(url?.scheme == "https" ? Color.secondary : Color.orange)
                }
                Spacer()
                Image(systemName: p.blocker && ContentBlocker.shared.enabled ? "checkmark.shield.fill" : "shield.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(p.blocker && ContentBlocker.shared.enabled ? Color.green : Color.secondary)
            }
            // Пауза — временно выключить все свои настройки сайта (не удаляя); сброс — удалить насовсем
            HStack(spacing: 8) {
                Text("Compatibility Mode").font(.system(size: 13, weight: .medium))
                Button { compatInfo.toggle() } label: {
                    Image(systemName: "questionmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $compatInfo, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Compatibility Mode shows the site as is, to fix a site that broke. While it’s on, for this site:")
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("– Ad and tracker blocking is off")
                            Text("– Page style and erased elements are off")
                            Text("– Web fonts, cookies and auto-play are allowed")
                            Text("– Reader and translation don’t start by themselves")
                            Text("– The usual Safari user agent is used")
                        }
                        Text("Your settings stay saved and come back when you turn it off. The reset button deletes them for good.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                    .padding(14)
                    .frame(width: 280)
                    .windowScheme()
                }
                Spacer()
                // Сбросить — удалить все настройки сайта насовсем
                Button {
                    let a = NSAlert()
                    a.messageText = "Reset all settings for \(site)?"
                    a.informativeText = "Page style, erased elements, permissions and everything else for this site will be deleted."
                    a.addButton(withTitle: "Reset")
                    a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { settings.reset(url); tab.reload() }
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reset all settings for this site")
                .disabled(settings.all[site] == nil && PageTweaks.shared.raw(url, incognito: tab.isIncognito) == PageTweaks.Site())
                Toggle("", isOn: Binding(get: { paused }, set: { on in set({ $0.paused = on }, reload: true) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .settingsBlock()

            Picker("", selection: $page) {
                Text("Page").tag(1)
                Text("Privacy").tag(0)
                Text("Permissions").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch page {
                case 0: privacy(p)
                case 1: pageTab(p)
                default: permissions(p)
                }
            }
            .disabled(paused)
            .opacity(paused ? 0.45 : 1)
        }
        .padding(16)
        .frame(width: 330)
        // Фон по теме (тёмная — тёмный): стекло поповера светлеет над белой страницей, а текст остаётся светлым
        .presentationBackground(.regularMaterial)
        // Пока открыт — выехавшая панель не прячется
        .onAppear { model.popovers += 1 }
        .onDisappear { model.popovers = max(0, model.popovers - 1) }
    }

    private func set(_ f: @escaping (inout SitePrefs) -> Void, reload: Bool = false) {
        settings.update(tab.url, incognito: tab.isIncognito, f)
        if reload { tab.reload() } else { reapply() }
    }

    private func reapply() {
        guard let wv = tab.webView else { return }
        wv.pageZoom = settings.prefs(tab.url, incognito: tab.isIncognito).zoom
    }

    @ViewBuilder private func privacy(_ p: SitePrefs) -> some View {
        Toggle("Block ads and trackers on this site", isOn: Binding(get: { p.blocker }, set: { v in set({ $0.blocker = v }, reload: true) }))
            .disabled(!ContentBlocker.shared.enabled)
        if !ContentBlocker.shared.enabled {
            Text("Blocking is off for all sites — Settings → Privacy.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if PrivacyGuard.fingerprintScope.covers(tab.dataStore) {
            Toggle("Fingerprint protection", isOn: Binding(get: { p.fingerprint }, set: { v in set({ $0.fingerprint = v }, reload: true) }))
                .help("Off — the site sees this Mac as it is. Helps when a site keeps asking whether you’re a robot.")
        }
        let blocked = tab.blocked
        let site = SiteSettings.site(tab.url) ?? ""
        let prefs = BlockerPrefs.shared
        // Трекеры — кто следит: уникальные сайты (последние две части адреса), как в отчёте Orion
        let trackers = Array(Set(blocked.compactMap { b -> String? in
            guard let h = b.url.host?.lowercased() else { return nil }
            return h.split(separator: ".").suffix(2).joined(separator: ".")
        })).sorted()
        Picker("", selection: $list) {
            Text("Blocked Requests: \(blocked.count)").tag(0)
            Text("Trackers: \(trackers.count)").tag(1)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if blocked.isEmpty {
            Text("Nothing blocked on this page.").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if list == 0 {
                        // Адрес и каким списком заблокирован; правый клик — разрешить на этом сайте
                        ForEach(Array(blocked.suffix(60).enumerated()), id: \.offset) { _, b in
                            let host = b.url.host ?? ""
                            HStack(spacing: 6) {
                                Text(host + b.url.path).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(BlockerPrefs.listName(b.list)).font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                            .contextMenu { allowMenu(host, site: site) }
                        }
                    } else {
                        ForEach(trackers, id: \.self) { t in
                            Text(t).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .contentShape(Rectangle())
                                .contextMenu { allowMenu(t, site: site) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            Text("Right-click a request to allow it on this site.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        // Разрешённое на этом сайте — можно вернуть блокировку
        let allowed = prefs.allows.filter { $0.site == site.lowercased() }
        if !allowed.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Allowed on this site").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(allowed) { a in
                    HStack {
                        Text(a.host).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Block Again") { prefs.removeAllow(a); reloadSoon() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                    }
                }
            }
            .settingsBlock()
        }
    }

    /// Меню строки: разрешить адрес (или весь его сайт) на этом сайте
    @ViewBuilder private func allowMenu(_ host: String, site: String) -> some View {
        let base = host.split(separator: ".").suffix(2).joined(separator: ".")
        Button("Allow \(host) on This Site") { BlockerPrefs.shared.allow(host, on: site); reloadSoon() }
        if base != host {
            Button("Allow All of \(base) on This Site") { BlockerPrefs.shared.allow(base, on: site); reloadSoon() }
        }
        Divider()
        Button("Copy Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(host, forType: .string)
        }
    }

    /// Разрешение вступает в силу после пересборки списков (пара секунд) — тогда и перезагрузить
    private func reloadSoon() {
        let t = tab
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { t.reload() }
    }

    @ViewBuilder private func pageTab(_ p: SitePrefs) -> some View {
        // Блоки — с подложкой, как папки в панели
        PageTweakControls(tab: tab).settingsBlock()
        ModeToggle(title: "Translate", icon: "character.bubble", shortcut: "⌥⌘T", query: "window.__sfTr && window.__sfTr.isOn()",
                   always: Binding(get: { p.translate }, set: { v in set({ $0.translate = v }) })) {
            PageTranslator.shared.toggle(tab)
        }
        .settingsBlock()
        ReaderControls().settingsBlock()
        Toggle("JavaScript", isOn: Binding(get: { p.javaScript }, set: { v in set({ $0.javaScript = v }, reload: true) }))
        row("Show as") {
            Picker("", selection: Binding(get: { p.userAgent }, set: { v in set({ $0.userAgent = v }, reload: true) })) {
                Text("Automatic").tag("auto")
                Text("Mobile").tag("mobile")
            }
            .labelsHidden().fixedSize()
        }
        row("Pop-up windows") {
            Picker("", selection: Binding(get: { p.popups }, set: { v in set({ $0.popups = v }) })) {
                Text("Allow").tag("allow")
                Text("Block").tag("block")
            }
            .labelsHidden().fixedSize()
        }
        row("Auto-play") {
            Picker("", selection: Binding(get: { p.autoplay }, set: { v in set({ $0.autoplay = v }, reload: true) })) {
                Text("Allow").tag("allow")
                Text("Stop Media with Sound").tag("nosound")
                Text("Stop All Media").tag("deny")
            }
            .labelsHidden().fixedSize()
        }
        Toggle("Load web fonts", isOn: Binding(get: { p.webFonts }, set: { v in set({ $0.webFonts = v }, reload: true) }))
    }

    @ViewBuilder private func permissions(_ p: SitePrefs) -> some View {
        row("Camera") { askPicker(p.camera) { v in set({ $0.camera = v }) } }
        row("Microphone") { askPicker(p.microphone) { v in set({ $0.microphone = v }) } }
        row("Location") { askPicker(p.location) { v in set({ $0.location = v }) } }
        row("Screen sharing") {
            Picker("", selection: Binding(get: { p.screenShare }, set: { v in set({ $0.screenShare = v }, reload: true) })) {
                Text("Ask").tag("ask")
                Text("Deny").tag("deny")
            }
            .labelsHidden().fixedSize()
        }
        row("Cookies") {
            Picker("", selection: Binding(get: { p.cookies }, set: { v in set({ $0.cookies = v }, reload: true) })) {
                Text("Allow").tag(true)
                Text("Block").tag(false)
            }
            .labelsHidden().fixedSize()
        }
        row("External apps") { askPicker(p.externalApps) { v in set({ $0.externalApps = v }) } }
        row("Downloads") {
            Picker("", selection: Binding(get: { p.downloads }, set: { v in set({ $0.downloads = v }) })) {
                Text("Allow").tag("allow")
                Text("Deny").tag("deny")
            }
            .labelsHidden().fixedSize()
        }
    }

    private func askPicker(_ value: String, _ set: @escaping (String) -> Void) -> some View {
        Picker("", selection: Binding(get: { value }, set: set)) {
            Text("Ask").tag("ask")
            Text("Allow").tag("allow")
            Text("Deny").tag("deny")
        }
        .labelsHidden().fixedSize()
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack { Text(label).font(.system(size: 13)); Spacer(); c() }
    }
}


extension View {
    /// Блок настроек на подложке — как папка в боковой панели
    func settingsBlock() -> some View {
        self.padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sidebarShade(Metrics.blockShade), in: RoundedRectangle(cornerRadius: 12, style: .circular))
    }
}
