import AppKit
import Network
import WebKit

// MARK: - Сброс сетевых подключений движка

/// Движок держит подключения к сайтам открытыми (HTTP/2, HTTP/3). Когда сеть меняется — переподключился VPN,
/// сменился Wi-Fi, Mac проснулся, — часть из них умирает молча, а движок продолжает слать в них запросы:
/// страница (например, YouTube) висит на заготовке, и помогает только перезапуск. Здесь — тот же сброс без перезапуска:
/// сетевой процесс движка перезапускается (сам, по первому запросу), висевшие страницы перезагружаются.
enum NetworkReset {
    private static var monitor: NWPathMonitor?
    private static var lastPath: String?
    private static var work: DispatchWorkItem?

    static func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { p in
            // Подпись сети: доступна ли и через какие интерфейсы (туннель VPN — тоже интерфейс)
            let sig = "\(p.status)|" + p.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            DispatchQueue.main.async { changed(sig) }
        }
        m.start(queue: .global(qos: .utility))
        monitor = m
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            schedule()
        }
    }

    private static func changed(_ sig: String) {
        defer { lastPath = sig }
        guard let last = lastPath, last != sig, sig.hasPrefix("satisfied") else { return }
        schedule()
    }

    /// Сеть успокоилась — сбросить (подряд идущие изменения сливаются в один сброс)
    private static func schedule() {
        work?.cancel()
        let w = DispatchWorkItem { now(manual: false) }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }

    /// Сбросить сейчас. Сам по себе — не во время загрузки файлов (она бы оборвалась); из меню — всегда
    static func now(manual: Bool) {
        if !manual, !DownloadStore.shared.active.isEmpty { return }
        // Видимые страницы, которые чего-то ждали из сети, — перезагрузить после сброса
        let pending = NSSelectorFromString("_networkRequestsInProgress")
        let tabs = BrowserModel.shared.allTabs.filter { t in
            guard let wv = t.webView, BrowserModel.visibleAnywhere(t) else { return false }
            if manual || wv.isLoading { return true }
            return wv.responds(to: pending) && (wv.value(forKey: "_networkRequestsInProgress") as? Bool ?? false)
        }
        let sel = NSSelectorFromString("_terminateNetworkProcess")
        for s in BrowserModel.allStores where s.responds(to: sel) { s.perform(sel) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            for t in tabs { t.reload() }
        }
        if manual { BrowserModel.current.showToast("Network connections reset") }
    }
}

// MARK: - Застрявшая загрузка страницы

/// Основная страница начала грузиться, а первый ответ за 15 с так и не пришёл — повторить запрос один раз.
/// Так было 3 ноября 2026 с поиском Google через туннель Happ: запрос ушёл в живое подключение (HTTP/3), по нему же
/// потом шли другие ответы, а ответа на страницу не было — вкладка оставалась пустой, «обновить» не помогало.
/// Только GET (форму повторно не отправляем) и только раз на адрес, пока страница не откроется.
enum StallWatch {
    static let delay: TimeInterval = 15
    private struct Entry { var url: URL; var get: Bool; var token = 0; var retried = false }
    private static var pages: [ObjectIdentifier: Entry] = [:]

    /// Переход основной рамки разрешён — запомнить, GET ли это
    static func allowed(_ wv: WKWebView, _ request: URLRequest) {
        guard let u = request.url else { return }
        let id = ObjectIdentifier(wv)
        let same = pages[id]?.url == u
        pages[id] = Entry(url: u, get: (request.httpMethod ?? "GET") == "GET", token: pages[id]?.token ?? 0, retried: same && pages[id]?.retried == true)
    }

    static func started(_ wv: WKWebView) {
        let id = ObjectIdentifier(wv)
        guard var e = pages[id], let scheme = e.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        e.token += 1
        pages[id] = e
        let token = e.token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak wv] in
            guard let wv, let e = pages[id], e.token == token, e.get, !e.retried, wv.isLoading,
                  wv.backForwardList.currentItem?.url != e.url,
                  wv.estimatedProgress <= 0.15 else { return }   // 0.1 — запрос ушёл, ответа ещё нет
            pages[id]?.retried = true
            wv.stopLoading()
            wv.load(URLRequest(url: e.url))
            let m = BrowserModel.owner(of: wv)
            if m.activeTab?.webView === wv { Tips.show(.stalled, m) }
        }
    }

    /// Страница открылась (или загрузка кончилась ошибкой) — следующему застреванию снова можно помочь
    static func settled(_ wv: WKWebView) {
        let id = ObjectIdentifier(wv)
        pages[id]?.token += 1
        pages[id]?.retried = false
    }

    static func forget(_ wv: WKWebView) { pages[ObjectIdentifier(wv)] = nil }
}
