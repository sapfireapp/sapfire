import AppKit
import CryptoKit
import SwiftUI
import WebKit

// MARK: - Расширения (модуль Extensions)

/// Расширения Safari, Chrome и Firefox на движке Safari (WKWebExtension, macOS 15.4+).
/// Откуда: из программ с расширениями Safari (App Store), со страницы Chrome Web Store / Firefox Add-ons
/// («⋯» → Add to Sapfire), из папки или файла (.zip, .crx, .xpi). Кнопки — в полосе над страницей,
/// всё остальное — Settings → Extensions и меню Extensions.

/// Установленное расширение (extensions.json)
struct ExtensionEntry: Codable, Identifiable, Equatable {
    var id: String
    var kind: String            // folder (своя копия: из магазина, файла, папки) / safari (из программы)
    var path: String
    var enabled = true
    var source: String? = nil   // chrome / firefox / file
    /// Разрешения, выданные позже (по просьбе расширения), — выдаём снова при запуске
    var granted: [String] = []
    var grantedPatterns: [String] = []
    /// Что человек одобрил в окне установки. При запуске выдаём только это, а не то, что расширение просит сейчас:
    /// обновлённое расширение с новыми правами выключается и спрашивает заново (как в Chrome)
    var approved: [String]? = nil
    var approvedPatterns: [String]? = nil
    /// Доступ к сайтам: nil — все запрошенные, "click" — только сайты, где на кнопку расширения нажали (они в grantedPatterns)
    var siteAccess: String? = nil
    /// Чем подтверждён архив: "store" — подпись Chrome Web Store, "developer" — подпись разработчика,
    /// "amo" — контрольная сумма Firefox Add-ons; nil — ничем
    var verified: String? = nil
}

struct ExtFailure: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

/// То, что видно в интерфейсе (без WebKit-типов — работает на любой macOS)
@Observable
final class ExtensionsUI {
    static let shared = ExtensionsUI()

    struct Item: Identifiable, Equatable {
        let id: String
        var name: String
        var icon: NSImage?
        var badge: String
        var enabled: Bool
        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.name == b.name && a.badge == b.badge && a.enabled == b.enabled && a.icon === b.icon }
    }
    struct Installed: Identifiable {
        let id: String
        var name: String
        var version: String
        var summary: String
        var icon: NSImage?
        var enabled: Bool
        var hasOptions: Bool
        var error: String?
        var kind: String
        var origin = ""
        var verified = false
        var wantsSites = false
        var sitesTitle = ""
        var onClick = false
        var clickedSites = 0
    }
    struct Available: Identifiable {
        var id: String { path }
        let name: String
        let app: String
        let path: String
    }

    /// Кнопки расширений (полоса над страницей, меню Extensions)
    var items: [Item] = []
    /// Settings → Extensions
    var installed: [Installed] = []
    var available: [Available] = []
    var busy: String?
}

/// Хранилище: список установленных и их файлы (~/Library/Application Support/Sapfire/Extensions)
enum ExtensionStore {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sapfire/Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var file: URL { dir.deletingLastPathComponent().appendingPathComponent("extensions.json") }

    static var entries: [ExtensionEntry] = {
        guard let d = try? Data(contentsOf: file), let e = try? JSONDecoder().decode([ExtensionEntry].self, from: d) else { return [] }
        return e
    }()

    static func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: file, options: .atomic) }
    }

    static func upsert(_ e: ExtensionEntry) {
        if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i] = e } else { entries.append(e) }
        save()
    }

    static func remove(_ id: String) {
        guard let e = entries.first(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        save()
        // Своя копия — удаляем с диска; расширение из программы остаётся в программе
        if e.kind == "folder", e.path.hasPrefix(dir.path) {
            let top = dir.appendingPathComponent(id)
            try? FileManager.default.removeItem(at: top)
        }
    }

    // MARK: Распаковка

    /// ID дополнения Firefox из manifest.json (browser_specific_settings.gecko.id или applications.gecko.id)
    static func geckoID(in folder: URL) -> String? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        for k in ["browser_specific_settings", "applications"] {
            if let g = (j[k] as? [String: Any])?["gecko"] as? [String: Any], let id = g["id"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    /// Есть ли у дополнения на Firefox Add-ons файл с такой суммой (среди последних 50 версий)
    static func amoHasFile(_ id: String, sha256: String, _ done: @escaping (Bool) -> Void) {
        guard let api = URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(id)/versions/?page_size=50") else { done(false); return }
        URLSession.shared.dataTask(with: api) { d, _, _ in
            guard let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let results = j["results"] as? [[String: Any]] else { done(false); return }
            let hashes = results.compactMap { ($0["file"] as? [String: Any])?["hash"] as? String }.map { $0.lowercased() }
            done(hashes.contains("sha256:" + sha256.lowercased()))
        }.resume()
    }

    /// Распаковать архив в папку расширения; вернуть папку с manifest.json и чем архив подтверждён.
    /// .crx — только CRX3 с сошедшейся подписью (CRX.swift). storeID — ID, который просили у Chrome Web Store:
    /// тогда файл обязан быть подписан и этим ID, и магазином
    static func unpack(_ data: Data, id: String, storeID: String? = nil) throws -> (folder: URL, verified: String?) {
        var zip = data, verified: String? = nil
        if CRX.isCRX(data) {
            let v = try CRX.verify(data)
            if let storeID, v.id != storeID || !v.fromStore {
                throw ExtFailure("The downloaded file isn’t the extension you asked for: it’s signed for a different ID or not by the Chrome Web Store.")
            }
            zip = v.zip
            verified = v.fromStore ? "store" : "developer"
        } else if storeID != nil {
            throw ExtFailure("The Chrome Web Store didn’t send an extension file.")
        } else if data.prefix(2) != Data("PK".utf8) {
            throw ExtFailure("This doesn’t look like an extension (not a .crx, .zip or .xpi file).")
        }
        guard let folder = extract(zip, id: id) else { throw ExtFailure("This doesn’t look like an extension (no manifest.json).") }
        return (folder, verified)
    }

    private static func extract(_ zip: Data, id: String) -> URL? {
        let dest = dir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        guard (try? zip.write(to: tmp)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", tmp.path, dest.path]
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        return manifestFolder(in: dest)
    }

    /// Скопировать папку расширения к себе
    static func copyFolder(_ src: URL, id: String) -> URL? {
        let dest = dir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.copyItem(at: src, to: dest)) != nil else { return nil }
        return manifestFolder(in: dest)
    }

    static func manifestFolder(in root: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path) { return root }
        let subs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return subs.first { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
    }

    // MARK: Расширения Safari в установленных программах

    /// Программы с расширениями Safari (из App Store и не только): их .appex внутри
    static func findSafariExtensions() -> [ExtensionsUI.Available] {
        let fm = FileManager.default
        var apps: [URL] = []
        for base in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let items = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: base), includingPropertiesForKeys: nil)) ?? []
            for u in items {
                if u.pathExtension == "app" { apps.append(u) }
                else if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    apps += ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
                }
            }
        }
        var out: [ExtensionsUI.Available] = []
        for app in apps {
            let plugins = app.appendingPathComponent("Contents/PlugIns")
            for ex in (try? fm.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? [] where ex.pathExtension == "appex" {
                guard let info = NSDictionary(contentsOf: ex.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                      let ns = info["NSExtension"] as? [String: Any],
                      ns["NSExtensionPointIdentifier"] as? String == "com.apple.Safari.web-extension" else { continue }
                let appName = app.deletingPathExtension().lastPathComponent
                let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? appName
                out.append(.init(name: name, app: appName, path: ex.path))
            }
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Страницы магазинов

    /// Страница расширения в Chrome Web Store или Firefox Add-ons: откуда и какой id
    static func storeItem(_ u: URL?) -> (store: String, id: String)? {
        guard let u, let h = u.host?.lowercased() else { return nil }
        if h == "chromewebstore.google.com" || (h == "chrome.google.com" && u.path.hasPrefix("/webstore")) {
            let id = u.pathComponents.last { $0.count == 32 && $0.allSatisfy { ("a"..."p").contains($0) } }
            return id.map { ("chrome", $0) }
        }
        if h == "addons.mozilla.org", let i = u.pathComponents.firstIndex(of: "addon"), i + 1 < u.pathComponents.count {
            return ("firefox", u.pathComponents[i + 1])
        }
        return nil
    }
}

// MARK: - Вход для остального Sapfire (безопасно на любой macOS)

enum Ext {
    static var supported: Bool { if #available(macOS 15.4, *) { true } else { false } }
    static var active: Bool { supported && Module.extensions.isOn }

    /// Стоит полноценный блокировщик-расширение (uBlock Origin / Lite, AdGuard) — свой скрипт на YouTube ему не мешает
    static var hasAdBlocker: Bool {
        guard active else { return false }
        let ids = ["ddkjiahejlhfcafbddmgiahcphecmpfh", "cjpalhdlnbpafiamejdnhcphjbkeiagm", "bgnkhhnnamicmpeenaelnjfhikgbkllg"]
        return ExtensionStore.entries.contains { e in
            e.enabled && (ids.contains { e.id.contains($0) } || ["ublock", "adguard"].contains { e.path.lowercased().contains($0) })
        }
    }

    /// Запуск: поднять движок и загрузить включённые расширения
    static func start() {
        guard active else { return }
        if #available(macOS 15.4, *) { ExtensionHost.start() }
        refreshAvailable()
    }

    static func moduleChanged(_ on: Bool) {
        guard supported else { return }
        if #available(macOS 15.4, *) {
            if on { ExtensionHost.start() } else { ExtensionHost.stop() }
        }
    }

    /// Новые страницы — с движком расширений
    static func configure(_ c: WKWebViewConfiguration) {
        guard active else { return }
        if #available(macOS 15.4, *), let h = ExtensionHost.shared { c.webExtensionController = h.controller }
    }

    static func opened(_ t: Tab) { if #available(macOS 15.4, *) { ExtensionHost.shared?.opened(t) } }
    static func closed(_ t: Tab) { if #available(macOS 15.4, *) { ExtensionHost.shared?.closed(t) } }
    static func activated(_ t: Tab, previous: Tab?) { if #available(macOS 15.4, *) { ExtensionHost.shared?.activated(t, previous: previous) } }
    static func changed(_ t: Tab, title: Bool = false, url: Bool = false, loading: Bool = false) {
        if #available(macOS 15.4, *) { ExtensionHost.shared?.changed(t, title: title, url: url, loading: loading) }
    }

    /// Пункты расширений в меню по правому клику на странице
    static func menuItems(for wv: WKWebView) -> [NSMenuItem] {
        if #available(macOS 15.4, *) { return ExtensionHost.shared?.menuItems(for: wv) ?? [] }
        return []
    }

    /// Сочетания клавиш расширений (из их manifest)
    static func handleKey(_ e: NSEvent) -> Bool {
        if #available(macOS 15.4, *) { return ExtensionHost.shared?.handleKey(e) ?? false }
        return false
    }

    /// Кнопка расширения нажата (`anchor` — у чего показать его окошко)
    static func perform(_ id: String, anchor: NSView?) {
        if #available(macOS 15.4, *) { ExtensionHost.shared?.perform(id, anchor: anchor) }
    }

    static func setEnabled(_ id: String, _ on: Bool) {
        guard var e = ExtensionStore.entries.first(where: { $0.id == id }) else { return }
        e.enabled = on
        ExtensionStore.upsert(e)
        if #available(macOS 15.4, *) {
            if on { ExtensionHost.shared?.loadEntry(e) } else { ExtensionHost.shared?.unload(id) }
        }
    }

    /// Доступ к сайтам: все запрошенные или только где нажали (разрешённые по клику сайты при смене забываются)
    static func setSiteAccess(_ id: String, click: Bool) {
        guard var e = ExtensionStore.entries.first(where: { $0.id == id }) else { return }
        e.siteAccess = click ? "click" : nil
        e.grantedPatterns = []
        ExtensionStore.upsert(e)
        if #available(macOS 15.4, *) { ExtensionHost.shared?.applySiteAccess(e) }
    }

    static func uninstall(_ id: String) {
        let name = ExtensionsUI.shared.installed.first { $0.id == id }?.name ?? "this extension"
        let a = NSAlert()
        a.messageText = "Remove “\(name)”?"
        a.informativeText = "Its settings and data will be removed too."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if #available(macOS 15.4, *) { ExtensionHost.shared?.unload(id, removeData: true) }
        ExtensionStore.remove(id)
        ExtensionsUI.shared.installed.removeAll { $0.id == id }
        refreshAvailable()
    }

    static func openOptions(_ id: String) {
        if #available(macOS 15.4, *) { ExtensionHost.shared?.openOptions(id) }
    }

    // MARK: Установка

    /// Из файла или папки: .zip, .crx, .xpi, .appex или папка с manifest.json
    static func addFromFile() {
        guard active else { needModule(); return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = false
        p.prompt = "Add"
        p.message = "Choose an extension: a folder with manifest.json, or a .zip, .crx, .xpi file"
        guard p.runModal() == .OK, let u = p.url else { return }
        if u.pathExtension == "appex" { addSafari(path: u.path); return }
        let id = "file-" + UUID().uuidString.prefix(8).lowercased()
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
        if isDir.boolValue {
            guard let folder = ExtensionStore.manifestFolder(in: u).flatMap({ ExtensionStore.copyFolder($0, id: id) }) else {
                fail("This doesn’t look like an extension (no manifest.json).", id: id); return
            }
            install(ExtensionEntry(id: id, kind: "folder", path: folder.path, source: "file"))
            return
        }
        do {
            guard let data = try? Data(contentsOf: u) else { throw ExtFailure("Couldn’t read the file.") }
            let r = try ExtensionStore.unpack(data, id: id)
            // .xpi с подписью Mozilla внутри: сверить файл с Firefox Add-ons по контрольной сумме — как при установке
            // из магазина (саму подпись не разбираем: сумма из их API по HTTPS привязывает файл к магазину)
            if r.verified == nil, FileManager.default.fileExists(atPath: r.folder.appendingPathComponent("META-INF/mozilla.rsa").path),
               let amoID = ExtensionStore.geckoID(in: r.folder) {
                ExtensionsUI.shared.busy = "Checking with Firefox Add-ons…"
                let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                ExtensionStore.amoHasFile(amoID, sha256: hex) { listed in
                    DispatchQueue.main.async {
                        ExtensionsUI.shared.busy = nil
                        install(ExtensionEntry(id: id, kind: "folder", path: r.folder.path, source: "file", verified: listed ? "amo" : nil))
                    }
                }
                return
            }
            install(ExtensionEntry(id: id, kind: "folder", path: r.folder.path, source: "file", verified: r.verified))
        } catch {
            fail(error.localizedDescription, id: id)
        }
    }

    static func addSafari(path: String) {
        guard active else { needModule(); return }
        let id = Bundle(path: path)?.bundleIdentifier ?? path
        install(ExtensionEntry(id: id, kind: "safari", path: path))
    }

    /// Со страницы магазина (Chrome Web Store, Firefox Add-ons) — скачать и поставить
    static func addFromStore(_ url: URL?) {
        guard active else { needModule(); return }
        guard let item = ExtensionStore.storeItem(url) else { return }
        let ui = ExtensionsUI.shared
        ui.busy = "Downloading…"
        BrowserModel.current.showToast("Downloading the extension…")
        let id = item.store + "-" + item.id
        /// Chrome: подпись CRX3 этим ID и магазином. Firefox: SHA-256 из ответа addons.mozilla.org
        /// (подпись Mozilla внутри .xpi не проверяем — сумма из их API по HTTPS привязывает файл к магазину)
        func got(_ data: Data?, sha256: String? = nil) {
            DispatchQueue.main.async {
                ui.busy = nil
                do {
                    guard let data else { throw ExtFailure("Couldn’t download the extension.") }
                    var verified: String?
                    if item.store == "firefox" {
                        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        guard let sha256, hex == sha256 else { throw ExtFailure("The downloaded file doesn’t match the checksum from Firefox Add-ons.") }
                        verified = "amo"
                    }
                    let r = try ExtensionStore.unpack(data, id: id, storeID: item.store == "chrome" ? item.id : nil)
                    install(ExtensionEntry(id: id, kind: "folder", path: r.folder.path, source: item.store, verified: r.verified ?? verified))
                } catch {
                    fail(error.localizedDescription, id: id)
                }
            }
        }
        if item.store == "chrome" {
            let v = "138.0.0.0"
            let s = "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=\(v)&acceptformat=crx3&x=id%3D\(item.id)%26installsource%3Dondemand%26uc"
            guard let u = URL(string: s) else { return }
            URLSession.shared.dataTask(with: u) { d, _, _ in got(d) }.resume()
        } else {
            guard let api = URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(item.id)/") else { return }
            URLSession.shared.dataTask(with: api) { d, _, _ in
                guard let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let cv = j["current_version"] as? [String: Any], let f = cv["file"] as? [String: Any],
                      let s = f["url"] as? String, let u = URL(string: s),
                      let h = f["hash"] as? String, h.hasPrefix("sha256:") else { got(nil); return }
                URLSession.shared.dataTask(with: u) { d, _, _ in got(d, sha256: String(h.dropFirst(7)).lowercased()) }.resume()
            }.resume()
        }
    }

    private static func install(_ e: ExtensionEntry) {
        if #available(macOS 15.4, *) {
            if ExtensionHost.shared == nil { ExtensionHost.start() }
            ExtensionHost.shared?.install(e)
        }
    }

    static func fail(_ message: String, id: String? = nil) {
        if let id { try? FileManager.default.removeItem(at: ExtensionStore.dir.appendingPathComponent(id)) }
        let a = NSAlert()
        a.messageText = "Couldn’t add the extension"
        a.informativeText = message
        a.runModal()
    }

    private static func needModule() {
        if !supported {
            fail("Extensions need macOS 15.4 or later.")
        } else {
            let a = NSAlert()
            a.messageText = "The Extensions module is off"
            a.informativeText = "Turn it on in Settings → Modules."
            a.addButton(withTitle: "Turn On")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn {
                UserDefaults.standard.set(true, forKey: Module.extensions.key)
                moduleChanged(true)
            }
        }
    }

    /// Расширения Safari в программах, ещё не добавленные
    static func refreshAvailable() {
        DispatchQueue.global(qos: .utility).async {
            let found = ExtensionStore.findSafariExtensions()
            DispatchQueue.main.async {
                let have = Set(ExtensionStore.entries.map(\.path))
                ExtensionsUI.shared.available = found.filter { !have.contains($0.path) }
            }
        }
    }
}

// MARK: - Движок (macOS 15.4+)

@available(macOS 15.4, *)
final class ExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    static var shared: ExtensionHost?

    let controller: WKWebExtensionController
    private var contexts: [String: WKWebExtensionContext] = [:]
    private var tabs: [UUID: ExtTab] = [:]
    private var windows: [UUID: ExtWindow] = [:]
    /// У какой кнопки показывать окошко расширения
    private weak var anchor: NSView?

    static func start() {
        guard shared == nil else { return }
        let h = ExtensionHost()
        shared = h
        for e in ExtensionStore.entries where e.enabled { h.loadEntry(e) }
        h.refreshUI()
    }

    static func stop() {
        guard let h = shared else { return }
        for id in Array(h.contexts.keys) { h.unload(id) }
        shared = nil
        ExtensionsUI.shared.items = []
    }

    override init() {
        controller = WKWebExtensionController(configuration: .default())
        super.init()
        controller.delegate = self
    }

    // MARK: Вкладки и окна для расширений

    func adapter(_ t: Tab) -> ExtTab {
        if let a = tabs[t.id], a.tab === t { return a }
        let a = ExtTab(t, host: self)
        tabs[t.id] = a
        return a
    }

    func window(_ m: BrowserModel) -> ExtWindow {
        if let w = windows[m.id], w.model === m { return w }
        let w = ExtWindow(m, host: self)
        windows[m.id] = w
        return w
    }

    /// Окна: активное первым
    private var openWindows: [ExtWindow] {
        let cur = BrowserModel.current
        let all = BrowserModel.windows.filter { $0.window != nil }
        return ([cur] + all.filter { $0 !== cur }).filter { $0.window != nil }.map(window)
    }

    private var busy: Bool { !contexts.isEmpty }

    func opened(_ t: Tab) { if busy { controller.didOpenTab(adapter(t)) } }
    func closed(_ t: Tab) {
        if busy, let a = tabs[t.id] { controller.didCloseTab(a, windowIsClosing: false) }
        tabs[t.id] = nil
    }
    func activated(_ t: Tab, previous: Tab?) {
        guard busy else { return }
        controller.didActivateTab(adapter(t), previousActiveTab: previous.map(adapter))
        refreshUI()
    }
    func changed(_ t: Tab, title: Bool, url: Bool, loading: Bool) {
        guard busy else { return }
        var p: WKWebExtension.TabChangedProperties = []
        if title { p.insert(.title) }
        if url { p.insert(.URL) }
        if loading { p.insert(.loading) }
        controller.didChangeTabProperties(p, for: adapter(t))
        if url, t === BrowserModel.current.activeTab { refreshUI() }
    }

    // MARK: Загрузка

    private func makeExtension(_ e: ExtensionEntry) async throws -> WKWebExtension {
        if e.kind == "safari" {
            guard let b = Bundle(path: e.path) else { throw CocoaError(.fileNoSuchFile) }
            return try await WKWebExtension(appExtensionBundle: b)
        }
        return try await WKWebExtension(resourceBaseURL: URL(fileURLWithPath: e.path, isDirectory: true))
    }

    func loadEntry(_ e: ExtensionEntry) {
        Task { @MainActor in
            do {
                let x = try await makeExtension(e)
                guard let e = approve(x, e) else { refreshUI(); return }
                try load(x, e)
            } catch {
                setError(e.id, error.localizedDescription)
            }
            refreshUI()
        }
    }

    private func load(_ x: WKWebExtension, _ e: ExtensionEntry) throws {
        if contexts[e.id] != nil { return }
        let ctx = WKWebExtensionContext(for: x)
        ctx.uniqueIdentifier = e.id
        ctx.isInspectable = true
        ctx.inspectionName = x.displayName
        // Только одобренное в окне установки (approve() уже сверил с тем, что расширение просит сейчас) и выданное позже
        for s in (e.approved ?? []) + e.granted { ctx.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: s)) }
        let sites = (e.siteAccess == "click" ? [] : e.approvedPatterns ?? []) + e.grantedPatterns
        for s in sites { if let m = try? WKWebExtension.MatchPattern(string: s) { ctx.setPermissionStatus(.grantedExplicitly, for: m) } }
        try controller.load(ctx)
        contexts[e.id] = ctx
    }

    /// Сверить, что расширение просит сейчас, с одобренным. Старые записи (до 2 ноября 2026) — одобренным считается
    /// запрошенное сейчас. Просит новое (обновилось, файлы подменили) — спросить; отказ — выключить, как Chrome.
    /// nil — не загружать
    private func approve(_ x: WKWebExtension, _ entry: ExtensionEntry) -> ExtensionEntry? {
        var e = entry
        let perms = Set(x.requestedPermissions.map(\.rawValue)), patterns = Set(x.allRequestedMatchPatterns.map(\.string))
        if e.approved == nil || e.approvedPatterns == nil {
            e.approved = perms.sorted(); e.approvedPatterns = patterns.sorted()
            ExtensionStore.upsert(e)
            return e
        }
        let newPerms = perms.subtracting(e.approved ?? []), newPatterns = patterns.subtracting(e.approvedPatterns ?? [])
        if newPerms.isEmpty && newPatterns.isEmpty { return e }
        let lines = Self.abilities(perms: newPerms, patterns: x.allRequestedMatchPatterns.filter { newPatterns.contains($0.string) })
        let a = NSAlert()
        a.messageText = "“\(x.displayName ?? "Extension")” has changed and asks for more access"
        a.informativeText = "It now also wants to:\n" + (lines.isEmpty ? "• " + newPerms.sorted().joined(separator: ", ") : lines.joined(separator: "\n"))
            + "\n\nIf you don’t allow it, the extension stays off until you turn it on again."
        if let icon = x.icon(for: CGSize(width: 64, height: 64)) { a.icon = icon }
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Turn Off")
        if a.runModal() == .alertFirstButtonReturn {
            e.approved = perms.sorted(); e.approvedPatterns = patterns.sorted()
            ExtensionStore.upsert(e)
            return e
        }
        e.enabled = false
        ExtensionStore.upsert(e)
        return nil
    }

    /// Смена доступа к сайтам — без перезагрузки расширения
    func applySiteAccess(_ e: ExtensionEntry) {
        guard let ctx = contexts[e.id] else { refreshUI(); return }
        ctx.grantedPermissionMatchPatterns = [:]
        if e.siteAccess != "click" {
            for s in e.approvedPatterns ?? [] { if let m = try? WKWebExtension.MatchPattern(string: s) { ctx.setPermissionStatus(.grantedExplicitly, for: m) } }
        }
        refreshUI()
    }

    func unload(_ id: String, removeData: Bool = false) {
        guard let ctx = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(ctx)
        if removeData {
            controller.fetchDataRecord(ofTypes: WKWebExtensionController.allExtensionDataTypes, for: ctx) { r in
                if let r { self.controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: [r]) {} }
            }
        }
        refreshUI()
    }

    /// Новое расширение: показать, что оно сможет, — и поставить
    func install(_ entry: ExtensionEntry) {
        ExtensionsUI.shared.busy = "Adding…"
        Task { @MainActor in
            defer { ExtensionsUI.shared.busy = nil }
            var e = entry
            let x: WKWebExtension
            do { x = try await makeExtension(e) } catch {
                Ext.fail(error.localizedDescription, id: e.kind == "folder" ? e.id : nil); return
            }
            let name = x.displayName ?? "Extension"
            let a = NSAlert()
            a.messageText = "Add “\(name)” to Sapfire?"
            a.informativeText = Self.describe(x, e)
            if let icon = x.icon(for: CGSize(width: 64, height: 64)) { a.icon = icon }
            a.addButton(withTitle: "Add")
            a.addButton(withTitle: "Cancel")
            // Доступ к сайтам — сразу при установке: все запрошенные или только где нажмёшь на кнопку расширения
            let patterns = x.allRequestedMatchPatterns
            var access: NSPopUpButton?
            if !patterns.isEmpty {
                let p = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 25), pullsDown: false)
                p.addItems(withTitles: [Self.sitesTitle(patterns.map(\.string)), "Only where I click it"])
                a.accessoryView = p
                access = p
            }
            guard a.runModal() == .alertFirstButtonReturn else {
                if e.kind == "folder" { try? FileManager.default.removeItem(at: ExtensionStore.dir.appendingPathComponent(e.id)) }
                return
            }
            e.approved = x.requestedPermissions.map(\.rawValue).sorted()
            e.approvedPatterns = patterns.map(\.string).sorted()
            e.siteAccess = access?.indexOfSelectedItem == 1 ? "click" : nil
            unload(e.id)
            ExtensionStore.upsert(e)
            do { try load(x, e); setError(e.id, nil) } catch { setError(e.id, error.localizedDescription) }
            refreshUI()
            Ext.refreshAvailable()
            BrowserModel.current.showToast("“\(name)” added — open tabs get it after reloading")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Tips.show(.toolbarButtons) }
        }
    }

    /// Что расширение сможет — человеческими словами, и откуда оно
    static func describe(_ x: WKWebExtension, _ e: ExtensionEntry) -> String {
        var lines = abilities(perms: Set(x.requestedPermissions.map(\.rawValue)), patterns: Array(x.allRequestedMatchPatterns))
        if lines.isEmpty { lines.append("• No special permissions") }
        let version = x.displayVersion.map { "Version \($0). " } ?? ""
        return version + (x.displayDescription ?? "") + "\n\n" + origin(e) + "\n\nIt will be able to:\n" + lines.joined(separator: "\n")
    }

    /// Откуда расширение и чем это подтверждено
    static func origin(_ e: ExtensionEntry) -> String {
        if e.kind == "safari" { return "A Safari extension from an app on this Mac." }
        switch e.verified {
        case "store": return "From the Chrome Web Store — signature checked."
        case "amo": return "From Firefox Add-ons — checksum checked."
        case "developer": return "Signed by its developer, but not from the Chrome Web Store."
        default: return "Not verified: Sapfire can’t check who made it or whether it was changed. Add it only if you trust where it came from."
        }
    }

    /// Права по-человечески — то, что стоит знать; безобидные (storage, alarms, contextMenus…) не перечисляем
    static func abilities(perms p: Set<String>, patterns: [WKWebExtension.MatchPattern]) -> [String] {
        var lines: [String] = []
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            lines.append("• Read and change everything on all websites, including passwords you type")
        } else if !patterns.isEmpty {
            let hosts = Array(Set(patterns.compactMap(\.host))).sorted()
            lines.append("• Read and change everything on \(hosts.prefix(4).joined(separator: ", "))\(hosts.count > 4 ? " and \(hosts.count - 4) more" : "")")
        }
        let map: [(keys: [String], text: String)] = [
            (["scripting"], "Run its code on those websites"),
            (["webRequest", "webRequestBlocking"], "See and change your network traffic"),
            (["tabs", "webNavigation"], "See your open tabs and where you browse"),
            (["history", "topSites"], "Read your browsing history"),
            (["bookmarks"], "Read and change your bookmarks"),
            (["cookies"], "Read and change cookies, including sign-ins"),
            (["declarativeNetRequest", "declarativeNetRequestWithHostAccess"], "Block or change content on pages"),
            (["declarativeNetRequestFeedback"], "See which requests it blocks"),
            (["downloads"], "Manage your downloads"),
            (["management"], "Manage your other extensions"),
            (["proxy"], "Send your traffic through a proxy"),
            (["privacy"], "Change privacy settings"),
            (["debugger"], "Control pages through the debugger"),
            (["clipboardRead"], "Read your clipboard"),
            (["clipboardWrite"], "Write to the clipboard"),
            (["geolocation"], "Know your location"),
            (["nativeMessaging"], "Talk to its app on this Mac"),
        ]
        for m in map where m.keys.contains(where: p.contains) { lines.append("• " + m.text) }
        return lines
    }

    /// Первый пункт выбора доступа к сайтам — то, что расширение просит
    static func sitesTitle(_ patterns: [String]) -> String {
        let ms = patterns.compactMap { try? WKWebExtension.MatchPattern(string: $0) }
        if ms.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) { return "On all websites" }
        let hosts = Array(Set(ms.compactMap(\.host))).sorted()
        return "On " + hosts.prefix(2).joined(separator: ", ") + (hosts.count > 2 ? " and \(hosts.count - 2) more" : "")
    }

    private func setError(_ id: String, _ message: String?) {
        errors[id] = message
    }
    private var errors: [String: String] = [:]

    // MARK: Интерфейс

    func refreshUI() {
        let active = BrowserModel.current.activeTab.map(adapter)
        var items: [ExtensionsUI.Item] = []
        var installed: [ExtensionsUI.Installed] = []
        for e in ExtensionStore.entries {
            let ctx = contexts[e.id]
            let x = ctx?.webExtension
            let name = x?.displayName ?? (e.path as NSString).lastPathComponent
            installed.append(.init(id: e.id, name: name, version: x?.displayVersion ?? "",
                                   summary: x?.displayDescription ?? "", icon: x?.icon(for: CGSize(width: 32, height: 32)),
                                   enabled: e.enabled, hasOptions: x?.hasOptionsPage ?? false,
                                   error: errors[e.id], kind: e.kind, origin: Self.origin(e),
                                   verified: e.kind == "safari" || e.verified != nil,
                                   wantsSites: !(e.approvedPatterns ?? []).isEmpty, sitesTitle: Self.sitesTitle(e.approvedPatterns ?? []), onClick: e.siteAccess == "click",
                                   clickedSites: e.siteAccess == "click" ? e.grantedPatterns.count : 0))
            guard e.enabled, let ctx, let x else { continue }
            let act = ctx.action(for: active)
            items.append(.init(id: e.id, name: act?.label.isEmpty == false ? act!.label : name,
                               icon: act?.icon(for: CGSize(width: 16, height: 16)) ?? x.actionIcon(for: CGSize(width: 16, height: 16)) ?? x.icon(for: CGSize(width: 16, height: 16)),
                               badge: act?.badgeText ?? "", enabled: act?.isEnabled ?? true))
        }
        let ui = ExtensionsUI.shared
        if ui.items != items { ui.items = items }
        ui.installed = installed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func perform(_ id: String, anchor: NSView?) {
        guard let ctx = contexts[id] else { return }
        self.anchor = anchor
        let tab = BrowserModel.current.activeTab
        if let tab { allowOnClick(ctx, tab) }
        ctx.performAction(for: tab.map(adapter))
    }

    /// Режим «только где нажал»: нажатие на кнопку расширения — согласие на этот сайт (запоминаем).
    /// Скрипты расширения встают в страницу только при загрузке — перезагружаем, если они для этого сайта есть
    private func allowOnClick(_ ctx: WKWebExtensionContext, _ tab: Tab) {
        guard let e = ExtensionStore.entries.first(where: { $0.id == ctx.uniqueIdentifier }), e.siteAccess == "click",
              let u = tab.webView?.url ?? tab.url, let host = u.host, ["http", "https"].contains(u.scheme ?? ""),
              !ctx.hasAccess(to: u),
              ctx.webExtension.allRequestedMatchPatterns.contains(where: { $0.matches(u) }),
              let m = try? WKWebExtension.MatchPattern(string: "*://\(host)/*") else { return }
        ctx.setPermissionStatus(.grantedExplicitly, for: m)
        remember(ctx) { $0.grantedPatterns.append(m.string) }
        if ctx.hasInjectedContent(for: u) { tab.reload() }
        BrowserModel.current.showToast("“\(ctx.webExtension.displayName ?? "Extension")” now works on \(host)")
    }

    func menuItems(for wv: WKWebView) -> [NSMenuItem] {
        guard let t = BrowserModel.shared.tab(for: wv) else { return [] }
        let a = adapter(t)
        return contexts.values.flatMap { $0.menuItems(for: a) }
    }

    func handleKey(_ e: NSEvent) -> Bool {
        for ctx in contexts.values where ctx.performCommand(for: e) { return true }
        return false
    }

    func openOptions(_ id: String) {
        guard let ctx = contexts[id], let u = ctx.optionsPageURL else { return }
        openExtensionPage(u, ctx)
    }

    /// Страница самого расширения (настройки и т. п.) — вкладкой, на его настройках движка
    @discardableResult
    private func openExtensionPage(_ u: URL, _ ctx: WKWebExtensionContext, select: Bool = true) -> Tab {
        let m = BrowserModel.current
        let t = m.newTab(url: u, select: select, configuration: ctx.webViewConfiguration)
        t.webView?.load(URLRequest(url: u))
        return t
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        openWindows
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        BrowserModel.current.window != nil ? window(BrowserModel.current) : nil
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let m = (configuration.window as? ExtWindow)?.model ?? BrowserModel.current
        let t: Tab
        if let u = configuration.url, u.scheme == extensionContext.baseURL.scheme {
            t = openExtensionPage(u, extensionContext, select: configuration.shouldBeActive)
        } else {
            t = m.newTab(url: configuration.url, select: configuration.shouldBeActive)
        }
        if configuration.shouldBePinned { m.togglePin(t) }
        if configuration.shouldBeMuted { t.muted = true }
        completionHandler(adapter(t), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        // Окно для страниц расширения (всплывающие) — маленькое окно; обычное — новое окно Sapfire
        if configuration.windowType == .popup, let u = configuration.tabURLs.first {
            LittleWindow.open(u)
            completionHandler(nil, nil)
            return
        }
        let m = BrowserModel.openWindow()
        for u in configuration.tabURLs { m.newTab(url: u) }
        completionHandler(window(m), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let u = extensionContext.optionsPageURL { openExtensionPage(u, extensionContext) }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let names = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        let ok = ask(extensionContext, "wants more permissions: \(names).")
        if ok { remember(extensionContext) { $0.granted += permissions.map(\.rawValue) } }
        completionHandler(ok ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let hosts = Set(urls.compactMap(\.host)).sorted().prefix(4).joined(separator: ", ")
        let ok = ask(extensionContext, "wants to read and change data on \(hosts).")
        if ok { remember(extensionContext) { $0.grantedPatterns += urls.compactMap { $0.host.map { "*://\($0)/*" } } } }
        completionHandler(ok ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let all = matchPatterns.contains { $0.matchesAllHosts || $0.matchesAllURLs }
        let what = all ? "all websites" : matchPatterns.compactMap(\.host).sorted().prefix(4).joined(separator: ", ")
        let ok = ask(extensionContext, "wants to read and change data on \(what).")
        if ok { remember(extensionContext) { $0.grantedPatterns += matchPatterns.map(\.string) } }
        completionHandler(ok ? matchPatterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        refreshUI()
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let pop = action.popupPopover else { completionHandler(nil); return }
        pop.behavior = .transient
        if let a = anchor, a.window != nil {
            pop.show(relativeTo: a.bounds, of: a, preferredEdge: .minY)
        } else if let v = BrowserModel.current.mainWindow?.contentView {
            // Без кнопки (клавишами, из меню) — у правого верхнего угла страницы
            let r = NSRect(x: v.bounds.maxX - 60, y: v.isFlipped ? 40 : v.bounds.maxY - 40, width: 1, height: 1)
            pop.show(relativeTo: r, of: v, preferredEdge: .minY)
        }
        completionHandler(nil)
    }

    private func ask(_ ctx: WKWebExtensionContext, _ what: String) -> Bool {
        let a = NSAlert()
        a.messageText = "“\(ctx.webExtension.displayName ?? "Extension")” \(what)"
        a.informativeText = "Allow it?"
        if let icon = ctx.webExtension.icon(for: CGSize(width: 64, height: 64)) { a.icon = icon }
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Don’t Allow")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func remember(_ ctx: WKWebExtensionContext, _ change: (inout ExtensionEntry) -> Void) {
        guard var e = ExtensionStore.entries.first(where: { $0.id == ctx.uniqueIdentifier }) else { return }
        change(&e)
        ExtensionStore.upsert(e)
    }
}

/// Вкладка Sapfire глазами расширения
@available(macOS 15.4, *)
final class ExtTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    private weak var host: ExtensionHost?
    init(_ t: Tab, host: ExtensionHost) { tab = t; self.host = host }

    private var model: BrowserModel { tab?.browser ?? BrowserModel.current }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let t = tab, let sp = model.space(of: t) else { return host.map { $0.window(model) } }
        let m = BrowserModel.window(showing: sp) ?? model
        return host?.window(m)
    }
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let t = tab else { return 0 }
        return model.currentSpace.ordered.firstIndex { $0 === t } ?? 0
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.webView }
    func title(for context: WKWebExtensionContext) -> String? { tab?.displayTitle }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.webView?.url ?? tab?.url }
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.isPinned ?? false }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tab.map { model.isVisible($0) } ?? false }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.isLoading ?? false) }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { tab?.audible ?? false }
    func isMuted(for context: WKWebExtensionContext) -> Bool { tab?.muted ?? false }
    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.muted = muted; completionHandler(nil)
    }
    func size(for context: WKWebExtensionContext) -> CGSize { tab?.webView?.bounds.size ?? .zero }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(tab?.webView?.pageZoom ?? 1) }
    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.webView?.pageZoom = CGFloat(zoomFactor); completionHandler(nil)
    }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.load(url); completionHandler(nil)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { tab?.webView?.reloadFromOrigin() } else { tab?.reload() }
        completionHandler(nil)
    }
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.webView?.goBack(); completionHandler(nil)
    }
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.webView?.goForward(); completionHandler(nil)
    }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let t = tab { model.select(t) }
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let t = tab { model.close(t) }
        completionHandler(nil)
    }
    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let t = tab, t.isPinned != pinned { model.togglePin(t) }
        completionHandler(nil)
    }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}

/// Окно Sapfire глазами расширения (в окне — вкладки его пространства)
@available(macOS 15.4, *)
final class ExtWindow: NSObject, WKWebExtensionWindow {
    weak var model: BrowserModel?
    private weak var host: ExtensionHost?
    init(_ m: BrowserModel, host: ExtensionHost) { model = m; self.host = host }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let m = model, let h = host else { return [] }
        return m.currentSpace.ordered.map(h.adapter)
    }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let t = model?.activeTab else { return nil }
        return host?.adapter(t)
    }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let w = model?.window else { return .normal }
        if w.isMiniaturized { return .minimized }
        if w.styleMask.contains(.fullScreen) { return .fullscreen }
        return w.isZoomed ? .maximized : .normal
    }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { model?.currentSpace.isIncognito ?? false }
    func frame(for context: WKWebExtensionContext) -> CGRect { model?.window?.frame ?? .zero }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { model?.window?.screen?.frame ?? .zero }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        model?.window?.makeKeyAndOrderFront(nil); completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        model?.window?.performClose(nil); completionHandler(nil)
    }
}

// MARK: - Кнопки расширений

/// Кнопки расширений в полосе над страницей: значок, счётчик; клик — окошко расширения
struct ExtensionButtons: View {
    @State private var ui = ExtensionsUI.shared
    var body: some View {
        ForEach(ui.items) { ExtensionButton(item: $0) }
    }
}

private struct ExtensionButton: View {
    let item: ExtensionsUI.Item
    @State private var hover = false
    @State private var anchor: NSView?
    var body: some View {
        Button { Ext.perform(item.id, anchor: anchor) } label: {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 13))
                }
            }
            .frame(width: 28, height: 28)
            .background(Color.primary.opacity(hover ? 0.1 : 0), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                if !item.badge.isEmpty {
                    Text(item.badge)
                        .font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 3).frame(minWidth: 12, minHeight: 12)
                        .background(Color.red, in: Capsule())
                        .offset(x: 2, y: 1)
                }
            }
            .background(AnchorReader { anchor = $0 })
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(item.enabled ? 1 : 0.4)
        .onHover { hover = $0 }
        .help(item.name)
    }
}

/// Даёт NSView под видом SwiftUI — к нему привязывается окошко расширения
struct AnchorReader: NSViewRepresentable {
    let got: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { got(v) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// Панель скрыта (адрес в сайдбаре) — все расширения одной кнопкой с меню
struct ExtensionsMenuButton: View {
    @State private var ui = ExtensionsUI.shared
    @State private var anchor: NSView?
    var body: some View {
        if !ui.items.isEmpty {
            Button {
                let menu = NSMenu()
                for it in ui.items {
                    let mi = ClosureMenuItem(it.name + (it.badge.isEmpty ? "" : " (\(it.badge))")) { Ext.perform(it.id, anchor: anchor) }
                    mi.image = it.icon.map { i in let c = i.copy() as! NSImage; c.size = NSSize(width: 16, height: 16); return c }
                    menu.addItem(mi)
                }
                if let a = anchor { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: a.bounds.height + 4), in: a) }
            } label: {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 12))
                    .frame(width: 24, height: 24)
                    .background(AnchorReader { anchor = $0 })
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Extensions")
        }
    }
}

// MARK: - Settings → Extensions

struct ExtensionsPage: View {
    @State private var ui = ExtensionsUI.shared
    @State private var tick = 0

    var body: some View {
        let _ = tick
        VStack(alignment: .leading, spacing: 14) {
            if !Ext.supported {
                Text("Extensions need macOS 15.4 or later.").foregroundStyle(.secondary)
            } else if !Module.extensions.isOn {
                HStack {
                    Text("The Extensions module is off.").foregroundStyle(.secondary)
                    Button("Turn On") {
                        UserDefaults.standard.set(true, forKey: Module.extensions.key)
                        Ext.moduleChanged(true); tick += 1
                    }
                }
            } else {
                content
            }
        }
        .onAppear { Ext.refreshAvailable() }
    }

    @ViewBuilder private var content: some View {
        HStack(spacing: 8) {
            Button("Add from File or Folder…") { Ext.addFromFile() }
            if let b = ui.busy { ProgressView().controlSize(.small); Text(b).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        Text("Or open an extension’s page in the Chrome Web Store or Firefox Add-ons and choose ⋯ → Add to Sapfire. Tabs that are already open get a new extension after reloading.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Text("INSTALLED").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6)
        if ui.installed.isEmpty {
            Text("No extensions yet.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        ForEach(ui.installed) { e in
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let i = e.icon { Image(nsImage: i).resizable().interpolation(.high) }
                    else { Image(systemName: "puzzlepiece.extension").font(.system(size: 18)).foregroundStyle(.secondary) }
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(e.name).font(.system(size: 13, weight: .medium))
                        if !e.version.isEmpty { Text(e.version).font(.system(size: 11)).foregroundStyle(.tertiary) }
                        if e.kind == "safari" { Text("Safari").font(.system(size: 10)).padding(.horizontal, 5).background(Color.primary.opacity(0.08), in: Capsule()) }
                    }
                    if !e.summary.isEmpty {
                        Text(e.summary).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(e.origin).font(.system(size: 11))
                        .foregroundStyle(e.verified ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
                        .fixedSize(horizontal: false, vertical: true)
                    if let err = e.error {
                        Text(err).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        if e.wantsSites {
                            Picker("", selection: Binding(get: { e.onClick }, set: { Ext.setSiteAccess(e.id, click: $0) })) {
                                Text(e.sitesTitle).tag(false)
                                Text(e.clickedSites > 0 ? "Only where I clicked it (\(e.clickedSites))" : "Only where I click it").tag(true)
                            }
                            .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
                        }
                        if e.hasOptions { Button("Settings…") { Ext.openOptions(e.id) }.controlSize(.small) }
                        Button("Remove…") { Ext.uninstall(e.id) }.controlSize(.small)
                    }
                    .padding(.top, 2)
                }
                .capsAtTop(13)
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(get: { e.enabled }, set: { Ext.setEnabled(e.id, $0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .scaleEffect(0.85)
                    .frame(height: 28)      // по центру значка расширения
            }
        }

        if !ui.available.isEmpty {
            Text("SAFARI EXTENSIONS IN YOUR APPS").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 10)
            ForEach(ui.available) { a in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.name).font(.system(size: 13))
                        Text("from \(a.app)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add") { Ext.addSafari(path: a.path) }.controlSize(.small)
                }
            }
            Text("Some Safari extensions only work inside Safari; if one doesn’t load, Sapfire says why.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Меню Extensions: расширения (как их кнопки), добавить, управлять
struct ExtensionsMenuItems: View {
    @State private var ui = ExtensionsUI.shared
    var body: some View {
        ForEach(ui.items) { it in
            Button(it.name + (it.badge.isEmpty ? "" : " (\(it.badge))")) { Ext.perform(it.id, anchor: nil) }
        }
        if !ui.items.isEmpty { Divider() }
        Button("Add Extension from File…") { Ext.addFromFile() }
        Button("Add This Extension to Sapfire") { Ext.addFromStore(BrowserModel.current.activeTab?.url) }
            .disabled(ExtensionStore.storeItem(BrowserModel.current.activeTab?.url) == nil)
        Button("Manage Extensions…") { SettingsWindow.show(page: .extensions) }
        Button("Modules…") { SettingsWindow.show(page: .modules) }
    }
}
