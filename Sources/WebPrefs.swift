import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Поисковик (Settings → Search)

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, bing, duckduckgo, ecosia, yahoo, yandex, startpage, brave, kagi
    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: "Google"
        case .bing: "Bing"
        case .duckduckgo: "DuckDuckGo"
        case .ecosia: "Ecosia"
        case .yahoo: "Yahoo"
        case .yandex: "Yandex"
        case .startpage: "Startpage"
        case .brave: "Brave Search"
        case .kagi: "Kagi"
        }
    }

    /// %s — запрос
    var template: String {
        switch self {
        case .google: "https://www.google.com/search?q=%s"
        case .bing: "https://www.bing.com/search?q=%s"
        case .duckduckgo: "https://duckduckgo.com/?q=%s"
        case .ecosia: "https://www.ecosia.org/search?q=%s"
        case .yahoo: "https://search.yahoo.com/search?p=%s"
        case .yandex: "https://yandex.ru/search/?text=%s"
        case .startpage: "https://www.startpage.com/do/search?q=%s"
        case .brave: "https://search.brave.com/search?q=%s"
        case .kagi: "https://kagi.com/search?q=%s"
        }
    }

    /// Подсказки (ответ в формате OpenSearch: [запрос, [подсказки]]); %s — запрос, %l — язык. nil — у поисковика их нет
    var suggest: String? {
        switch self {
        case .google: "https://suggestqueries.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8&hl=%l&q=%s"
        case .bing: "https://api.bing.com/osjson.aspx?query=%s"
        case .duckduckgo: "https://duckduckgo.com/ac/?type=list&q=%s"
        case .ecosia: "https://ac.ecosia.org/autocomplete?type=list&q=%s"
        case .yahoo: "https://search.yahoo.com/sugg/ff?output=fxjson&appid=ffd&command=%s"
        case .yandex: "https://suggest.yandex.ru/suggest-ff.cgi?uil=%l&part=%s"
        case .brave: "https://search.brave.com/api/suggest?q=%s"
        case .startpage, .kagi: nil
        }
    }

    static var main: SearchEngine {
        UserDefaults.standard.string(forKey: Prefs.searchEngine).flatMap(SearchEngine.init) ?? .google
    }
    /// Поисковик для инкогнито («Same as above» — тот же)
    static var privateEngine: SearchEngine {
        UserDefaults.standard.string(forKey: Prefs.privateSearchEngine).flatMap(SearchEngine.init) ?? main
    }
    static func current(incognito: Bool) -> SearchEngine { incognito ? privateEngine : main }
}

// MARK: - Движок страниц: общие настройки всех страниц

enum WebEngine {
    /// Одни настройки на все страницы: поменял в Settings — сразу действует везде
    static let preferences: WKPreferences = {
        let p = WKPreferences()
        p.isElementFullscreenEnabled = true
        enablePictureInPicture(p)
        slowHiddenTimers(p)
        apply(p)
        return p
    }()

    /// Таймеры невидимых страниц замедляются всё сильнее, пока вкладка в фоне (как в Safari; в WKWebView по умолчанию
    /// выключено — фоновые вкладки тикали раз в секунду и ели процессор). Скрытая настройка движка
    static func slowHiddenTimers(_ p: WKPreferences) {
        guard !Perf.off("throttle"), p.responds(to: NSSelectorFromString("_setHiddenPageDOMTimerThrottlingAutoIncreases:")) else { return }
        p.setValue(true, forKey: "hiddenPageDOMTimerThrottlingAutoIncreases")
    }

    /// «Картинка в картинке»: в WKWebView выключена по умолчанию (скрытая настройка), включаем как в Safari
    static func enablePictureInPicture(_ p: WKPreferences) {
        guard p.responds(to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")) else { return }
        p.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
    }

    static func applyPreferences() { apply(preferences) }

    private static func apply(_ p: WKPreferences) {
        let d = UserDefaults.standard
        p.isFraudulentWebsiteWarningEnabled = d.object(forKey: Prefs.fraudWarning) as? Bool ?? true
        p.tabFocusesLinks = d.bool(forKey: Prefs.tabHighlights)
        p.minimumFontSize = CGFloat(d.integer(forKey: Prefs.minFontSize))
    }

    /// Sapfire — браузер по умолчанию (открывает https-ссылки)
    static var isDefaultBrowser: Bool {
        guard let u = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: u) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static var javaScript: Bool { UserDefaults.standard.object(forKey: Prefs.javaScript) as? Bool ?? true }
    static var newTabActive: Bool { UserDefaults.standard.bool(forKey: Prefs.newTabActive) }
    static var fullAddress: Bool { UserDefaults.standard.bool(forKey: Prefs.fullAddress) }

    // MARK: Куки

    static func applyCookies(to s: WKWebsiteDataStore) {
        s.httpCookieStore.setCookiePolicy(UserDefaults.standard.bool(forKey: Prefs.blockAllCookies) ? .disallow : .allow) {}
    }
    static func applyCookiesEverywhere() { BrowserModel.allStores.forEach(applyCookies) }

    // MARK: Предупреждение о незащищённом соединении (http://)

    static var httpWarning: Bool { UserDefaults.standard.bool(forKey: Prefs.httpWarning) }
    /// Сайты, куда в этом сеансе всё равно решили пойти
    static var allowedHTTP = Set<String>()

    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || !h.contains(".") { return true }
        if [".local", ".localhost", ".test", ".internal", ".lan", ".home.arpa"].contains(where: h.hasSuffix) { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    /// true — переход остановлен, спросили
    static func shouldWarn(_ url: URL?) -> Bool {
        guard httpWarning, let url, url.scheme?.lowercased() == "http", let host = url.host else { return false }
        return !isLocal(host) && !allowedHTTP.contains(host.lowercased())
    }

    static func warnHTTP(_ url: URL, in wv: WKWebView) {
        let host = url.host ?? url.absoluteString
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "“\(host)” isn’t secure"
        a.informativeText = "This website doesn’t use a secure connection. Anything you enter on it — like passwords or card numbers — can be seen by others on the network."
        a.addButton(withTitle: "Go Back")
        a.addButton(withTitle: "Try HTTPS")
        a.addButton(withTitle: "Visit Website")
        let done: (NSApplication.ModalResponse) -> Void = { r in
            switch r {
            case .alertSecondButtonReturn:
                var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
                c?.scheme = "https"
                if c?.port == 80 { c?.port = nil }
                if let u = c?.url { wv.load(URLRequest(url: u)) }
            case .alertThirdButtonReturn:
                allowedHTTP.insert(host.lowercased())
                wv.load(URLRequest(url: url))
            default: break
            }
        }
        if let w = wv.window { a.beginSheetModal(for: w, completionHandler: done) } else { done(a.runModal()) }
    }

    // MARK: Свой файл стилей (Settings → Advanced)

    private static var css: String = readStyleSheet()

    private static func readStyleSheet() -> String {
        guard let path = UserDefaults.standard.string(forKey: Prefs.styleSheet), !path.isEmpty else { return "" }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private static func styleScript(_ css: String) -> String {
        let json = (try? JSONEncoder().encode(css)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return """
        (function(css){var id='sapfire-user-css';function put(){var s=document.getElementById(id);
          if(!css){if(s)s.remove();return;}
          if(!s){s=document.createElement('style');s.id=id;(document.head||document.documentElement).appendChild(s);}
          s.textContent=css;}
          put();if(!document.head)document.addEventListener('DOMContentLoaded',put);})(\(json));
        """
    }

    static func installStyleSheet(in c: WKUserContentController) {
        guard !css.isEmpty else { return }
        c.addUserScript(WKUserScript(source: styleScript(css), injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    /// Файл выбрали, сменили или убрали — на открытых страницах сразу, на новых — при загрузке
    static func reloadStyleSheet() {
        css = readStyleSheet()
        let src = styleScript(css)
        var seen = Set<ObjectIdentifier>()
        for t in BrowserModel.shared.allTabs {
            guard let wv = t.webView else { continue }
            let c = wv.configuration.userContentController
            // Скрипт дописываем (старые убрать нельзя) — более поздний перекрывает прежний
            if seen.insert(ObjectIdentifier(c)).inserted {
                c.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            wv.evaluateJavaScript(src)
        }
    }

    // MARK: Загрузки

    /// Куда сохранять: nil — спросить
    static var downloadFolder: URL? {
        let d = UserDefaults.standard
        switch d.string(forKey: Prefs.downloadLocation) ?? "downloads" {
        case "ask": return nil
        case "custom":
            if let p = d.string(forKey: Prefs.downloadFolder), FileManager.default.fileExists(atPath: p) {
                return URL(fileURLWithPath: p, isDirectory: true)
            }
            fallthrough
        default: return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
    }

    /// «Безопасные» файлы: картинки, видео, звук, PDF и текст — их можно открыть сразу после загрузки
    static func isSafe(_ file: URL) -> Bool {
        guard let t = UTType(filenameExtension: file.pathExtension) else { return false }
        return [UTType.image, .movie, .audio, .pdf, .plainText].contains { t.conforms(to: $0) }
    }

    static var openSafeFiles: Bool { UserDefaults.standard.bool(forKey: Prefs.openSafeFiles) }
    /// Когда убирать строки из списка загрузок: quit / success / day / manual
    static var downloadListRemoval: String { UserDefaults.standard.string(forKey: Prefs.downloadRemoval) ?? "quit" }

    // MARK: История

    /// Сколько хранить историю (секунд); 0 — пока не очистишь сам
    static var historyKeep: Double {
        UserDefaults.standard.object(forKey: Prefs.historyKeep) as? Double ?? 365 * 86400
    }
}

// MARK: - Данные сайтов (Settings → Privacy → Manage Website Data…)

final class WebsiteDataWindow {
    private static var window: NSWindow?

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Website Data"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 380, height: 300)
        w.contentView = NSHostingView(rootView: WebsiteDataView { w.close() })
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in window = nil }
    }
}

private struct WebsiteDataView: View {
    let close: () -> Void

    struct Site: Identifiable {
        var name: String
        var types: Set<String> = []
        var records: [(WKWebsiteDataStore, WKWebsiteDataRecord)] = []
        var id: String { name }
    }

    @State private var sites: [Site] = []
    @State private var loading = true
    @State private var query = ""
    @State private var selection = Set<String>()

    /// Все хранилища: основной профиль и остальные
    private var stores: [WKWebsiteDataStore] { BrowserModel.allStores.filter(\.isPersistent) }

    var body: some View {
        let q = query.lowercased()
        let shown = sites.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        VStack(alignment: .leading, spacing: 10) {
            Text("These websites have stored data that can be used to track your browsing. Removing the data may reduce tracking, but may also sign you out of websites or change their behavior.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            List(shown, selection: $selection) { s in
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).font(.system(size: 13))
                    Text(Self.describe(s.types)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .tag(s.id)
            }
            .overlay { if loading { ProgressView() } else if shown.isEmpty { Text("No website data").foregroundStyle(.secondary) } }
            HStack {
                Button("Remove") { remove(sites.filter { selection.contains($0.id) }) }
                    .disabled(selection.isEmpty)
                Button(q.isEmpty ? "Remove All" : "Remove Shown") { confirmRemove(shown) }
                    .disabled(shown.isEmpty)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 300)
        .onAppear(perform: load)
    }

    private func load() {
        loading = true
        let all = WKWebsiteDataStore.allWebsiteDataTypes()
        let group = DispatchGroup()
        var found: [String: Site] = [:]
        for s in stores {
            group.enter()
            s.fetchDataRecords(ofTypes: all) { recs in
                for r in recs {
                    var site = found[r.displayName] ?? Site(name: r.displayName)
                    site.types.formUnion(r.dataTypes)
                    site.records.append((s, r))
                    found[r.displayName] = site
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            sites = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loading = false
        }
    }

    private func confirmRemove(_ list: [Site]) {
        let a = NSAlert()
        a.messageText = list.count == sites.count ? "Remove all data stored by websites?" : "Remove data of \(list.count) websites?"
        a.informativeText = "You may be signed out of these websites. This can’t be undone."
        a.addButton(withTitle: "Remove Now")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { remove(list) }
    }

    private func remove(_ list: [Site]) {
        let all = WKWebsiteDataStore.allWebsiteDataTypes()
        let byStore = Dictionary(grouping: list.flatMap(\.records)) { ObjectIdentifier($0.0) }
        let group = DispatchGroup()
        for (_, pairs) in byStore {
            guard let store = pairs.first?.0 else { continue }
            group.enter()
            store.removeData(ofTypes: all, for: pairs.map(\.1)) { group.leave() }
        }
        group.notify(queue: .main) { selection = []; load() }
    }

    static func describe(_ types: Set<String>) -> String {
        var out: [String] = []
        if types.contains(WKWebsiteDataTypeCookies) { out.append("Cookies") }
        if types.contains(WKWebsiteDataTypeLocalStorage) || types.contains(WKWebsiteDataTypeSessionStorage) { out.append("Local storage") }
        if types.contains(WKWebsiteDataTypeIndexedDBDatabases) || types.contains(WKWebsiteDataTypeWebSQLDatabases) { out.append("Databases") }
        if types.contains(WKWebsiteDataTypeServiceWorkerRegistrations) { out.append("Service workers") }
        if types.contains(WKWebsiteDataTypeDiskCache) || types.contains(WKWebsiteDataTypeMemoryCache)
            || types.contains(WKWebsiteDataTypeFetchCache) || types.contains(WKWebsiteDataTypeOfflineWebApplicationCache) { out.append("Cache") }
        return out.isEmpty ? "Other data" : out.joined(separator: ", ")
    }
}
