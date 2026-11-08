import AppKit
import Network
import WebKit

// MARK: - Инкогнито: отдельная сеть и ноль следов

/// Инкогнито ходит в сеть только через прокси (Happ и т. п.: локальный SOCKS5 / HTTP-порт), остальной Sapfire и
/// система — напрямую. Прокси выключен — страницы инкогнито не грузятся вовсе (мимо туннеля ничего не уходит).
/// WebRTC в инкогнито выключен (он ходит мимо прокси и выдал бы настоящий адрес). Ничего из инкогнито не пишется
/// на диск; закрыл — стёрто и из памяти.
enum Incognito {
    static var proxyOn: Bool { UserDefaults.standard.bool(forKey: Prefs.incognitoProxy) }
    static var host: String {
        let h = UserDefaults.standard.string(forKey: Prefs.incognitoProxyHost) ?? ""
        return h.isEmpty ? "127.0.0.1" : h
    }
    static var port: Int {
        let p = UserDefaults.standard.integer(forKey: Prefs.incognitoProxyPort)
        return p > 0 ? p : 10808
    }
    static var http: Bool { UserDefaults.standard.string(forKey: Prefs.incognitoProxyType) == "http" }

    /// Прокси для инкогнито (если включено)
    static var proxy: ProxyConfiguration? { proxyOn ? endpoint : nil }

    /// Прокси VPN-программы (общий адрес для инкогнито и профилей с туннелем)
    static var endpoint: ProxyConfiguration? {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: p)
        var c = http ? ProxyConfiguration(httpCONNECTProxy: ep) : ProxyConfiguration(socksv5Proxy: ep)
        c.allowFailover = false          // прокси недоступен — не идти напрямую
        return c
    }

    /// Хранилище инкогнито — через прокси
    static func apply(to store: WKWebsiteDataStore) {
        store.proxyConfigurations = proxy.map { [$0] } ?? []
    }

    /// Свои запросы Sapfire для инкогнито (значки сайтов, проверка адреса): через тот же прокси, без кэша и куки.
    /// Прокси выключен — nil (тогда ничего не запрашиваем, чтобы не выдать сайты напрямую)
    static func session() -> URLSession? {
        guard proxyOn else { return nil }
        if let s = privateSession, sessionKey == endpointKey { return s }
        privateSession = makeSession(proxy); sessionKey = endpointKey
        return privateSession
    }

    /// Для профилей с туннелем — одна общая сессия (своя у инкогнито: стирается при его закрытии)
    static func proxySession(_ p: ProxyConfiguration?) -> URLSession? {
        guard p != nil else { return nil }
        if let s = tunnelSession, tunnelKey == endpointKey { return s }
        tunnelSession = makeSession(p); tunnelKey = endpointKey
        return tunnelSession
    }

    private static var privateSession: URLSession?, sessionKey = ""
    private static var tunnelSession: URLSession?, tunnelKey = ""
    private static var endpointKey: String { "\(http ? "http" : "socks")://\(host):\(port)" }

    private static func makeSession(_ p: ProxyConfiguration?) -> URLSession? {
        guard let p else { return nil }
        let c = URLSessionConfiguration.ephemeral
        c.proxyConfigurations = [p]
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }

    /// Прокси слушает? (Happ запущен)
    static func reachable(_ done: @escaping (Bool) -> Void) {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { done(false); return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        var finished = false
        func end(_ ok: Bool) {
            guard !finished else { return }
            finished = true
            c.cancel()
            DispatchQueue.main.async { done(ok) }
        }
        c.stateUpdateHandler = { s in
            switch s {
            case .ready: end(true)
            case .failed, .waiting: end(false)
            default: break
            }
        }
        c.start(queue: .global(qos: .userInitiated))
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { end(false) }
    }

    /// Какой адрес видят сайты: через прокси и напрямую
    static func checkIP(viaProxy: Bool, _ done: @escaping (String?) -> Void) {
        guard let u = URL(string: "https://api.ipify.org") else { done(nil); return }
        let s: URLSession? = viaProxy ? proxySession(endpoint) : URLSession(configuration: .ephemeral)
        guard let s else { done(nil); return }
        s.dataTask(with: u) { d, _, _ in
            let ip = d.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { done(ip?.isEmpty == false ? ip : nil) }
        }.resume()
    }

    /// Открыли инкогнито: прокси на месте? Сказать, через какой адрес пойдёт, или предупредить
    static func opened(_ m: BrowserModel) {
        guard proxyOn else { return }
        reachable { ok in
            if ok {
                checkIP(viaProxy: true) { ip in
                    m.showToast(ip.map { "Incognito through the proxy — sites see \($0)" } ?? "Incognito through the proxy")
                }
            } else {
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "The proxy for incognito is off"
                a.informativeText = "Nothing answers at \(host):\(port). Start your VPN app with its local proxy on. Until then incognito pages won’t load — nothing goes around the tunnel."
                a.addButton(withTitle: "OK")
                if FileManager.default.fileExists(atPath: "/Applications/Happ.app") { a.addButton(withTitle: "Open Happ") }
                if a.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Happ.app"))
                }
            }
        }
    }

    /// Настройки прокси поменялись — открытому инкогнито сразу
    static func settingsChanged() {
        guard let old = BrowserModel.incognitoStore else { return }
        // Страниц ещё не было — прокси можно просто назначить
        guard BrowserModel.usedStores.contains(ObjectIdentifier(old)) else { apply(to: old); return }
        // У работавшего хранилища движок прокси уже не меняет (так бы инкогнито и шло напрямую) —
        // новое хранилище, открытые страницы инкогнито заново, уже по новой дороге. Входы инкогнито сбрасываются.
        BrowserModel.incognitoStore = BrowserModel.newIncognitoStore()
        for m in BrowserModel.windows {
            for sp in m.spaces where sp.isIncognito {
                for t in sp.tabs where t.webView != nil {
                    let visible = BrowserModel.visibleAnywhere(t)
                    t.sleep()
                    if visible { t.ensureWebView() }
                }
            }
        }
        BrowserModel.current.showToast(proxyOn ? "Incognito restarted through the VPN proxy" : "Incognito restarted — direct connection")
    }

    /// Закрыли инкогнито — стереть всё, что осталось в памяти
    static func erase() {
        PageSwipe.shared.forgetAll()
        FaviconStore.shared.forgetPrivate()
        SiteSettings.shared.forgetTemp()
        PageTweaks.shared.forgetTemp()
        DownloadStore.shared.forgetPrivate()
        BrowserUndo.shared.clear()
        Geolocation.shared.forgetSession()
        LocalBridge.shared.forgetSession()
        WebEngine.allowedHTTP = []
        privateSession?.invalidateAndCancel(); privateSession = nil
    }

    /// Без WebRTC: он ходит мимо прокси и выдал бы настоящий адрес (для профилей с туннелем — по настройке)
    static let noWebRTC = WKUserScript(source: """
    (function(){
      ['RTCPeerConnection','webkitRTCPeerConnection','RTCDataChannel','RTCSessionDescription','RTCIceCandidate','RTCRtpSender','RTCRtpReceiver']
        .forEach(function(k){ try { Object.defineProperty(window, k, {value: undefined, writable: false, configurable: false}); } catch(e){} });
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    /// Страница инкогнито: без WebRTC и без предзагрузки DNS
    static let script = WKUserScript(source: """
    (function(){
      ['RTCPeerConnection','webkitRTCPeerConnection','RTCDataChannel','RTCSessionDescription','RTCIceCandidate','RTCRtpSender','RTCRtpReceiver']
        .forEach(function(k){ try { Object.defineProperty(window, k, {value: undefined, writable: false, configurable: false}); } catch(e){} });
      try { var m = document.createElement('meta'); m.httpEquiv = 'x-dns-prefetch-control'; m.content = 'off';
            (document.head || document.documentElement).appendChild(m); } catch(e){}
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    /// Только предзагрузка DNS выключена — для профилей через туннель, где WebRTC оставили (по настройке)
    static let noPrefetch = WKUserScript(source: """
    (function(){
      try { var m = document.createElement('meta'); m.httpEquiv = 'x-dns-prefetch-control'; m.content = 'off';
            (document.head || document.documentElement).appendChild(m); } catch(e){}
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    /// Настройки движка для инкогнито — свои (без предзагрузки DNS и без WebRTC в самом движке —
    /// скрипт выше рамка about:blank может и не получить), остальное как у обычных страниц
    static let preferences = makePreferences(webRTC: false)
    /// Для профилей через туннель: без предзагрузки DNS (иначе адреса ссылок спрашивались бы мимо туннеля),
    /// WebRTC — по настройке
    static let tunnelPreferences = makePreferences(webRTC: !Tunnel.blockWebRTC)

    private static func makePreferences(webRTC: Bool) -> WKPreferences {
        let p = WKPreferences()
        p.isElementFullscreenEnabled = true
        WebEngine.enablePictureInPicture(p)
        WebEngine.slowHiddenTimers(p)
        p.isFraudulentWebsiteWarningEnabled = WebEngine.preferences.isFraudulentWebsiteWarningEnabled
        p.minimumFontSize = WebEngine.preferences.minimumFontSize
        p.tabFocusesLinks = WebEngine.preferences.tabFocusesLinks
        setFlag(p, "_setDNSPrefetchingEnabled:", false)
        if !webRTC { setFlag(p, "_setPeerConnectionEnabled:", false) }
        // WebTransport (HTTP/3 по UDP) через прокси не ходит: с `allowFailover = false` система его просто отвергает
        // (проверено 2 ноября 2026 и с HTTP CONNECT, и с SOCKS5 — ни одного пакета мимо). Выключаем и в движке,
        // чтобы не зависеть от этого поведения в будущих версиях
        setFeature(p, "WebTransportEnabled", false)
        return p
    }

    /// Настройка движка из списка `_features` (там, где нет своего сеттера), если она есть в этой версии WebKit
    private static func setFeature(_ p: WKPreferences, _ key: String, _ value: Bool) {
        guard let all = WKPreferences.perform(NSSelectorFromString("_features"))?.takeUnretainedValue() as? [AnyObject],
              let f = all.first(where: { ($0.value(forKey: "key") as? String) == key }) else { return }
        let sel = NSSelectorFromString("_setEnabled:forFeature:")
        guard let m = class_getInstanceMethod(type(of: p), sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(method_getImplementation(m), to: F.self)(p, sel, value, f)
    }

    /// Скрытая настройка движка (булева), если она есть в этой версии WebKit
    private static func setFlag(_ p: WKPreferences, _ name: String, _ value: Bool) {
        let sel = NSSelectorFromString(name)
        guard let m = class_getInstanceMethod(type(of: p), sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(m), to: F.self)(p, sel, value)
    }
}

// MARK: - Туннель для профилей

/// Профиль можно пустить через прокси VPN-программы (Happ): его пространства ходят через туннель, остальные —
/// напрямую. Прокси выключен — страницы такого профиля не грузятся (мимо туннеля ничего не уходит).
enum Tunnel {
    private static let key = "tunnelProfiles"
    static var profiles: Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }
    static func isOn(_ profile: UUID) -> Bool { profile == Profile.vpnID || profiles.contains(profile) }
    static var blockWebRTC: Bool { UserDefaults.standard.object(forKey: Prefs.tunnelBlockWebRTC) as? Bool ?? true }

    /// Хранилище профиля идёт через прокси или напрямую
    static func apply(_ store: WKWebsiteDataStore) {
        guard store.isPersistent else { return }            // инкогнито — отдельно (Incognito.apply)
        let id = BrowserModel.profileID(of: store)
        store.proxyConfigurations = id.flatMap { isOn($0) ? Incognito.endpoint.map { [$0] } : nil } ?? []
    }

    /// Хранилища всех профилей — при запуске и когда поменяли адрес прокси
    static func applyAll() { BrowserModel.allStores.forEach(apply) }

    /// Профили, которым включили туннель, когда их страницы уже ходили напрямую: до перезапуска Sapfire
    /// их страницы не грузятся (движок не меняет дорогу у работавшего хранилища — иначе шли бы мимо туннеля)
    static var needsRestart = Set<UUID>()

    /// Страница профиля не грузится, пока Sapfire не перезапущен: спросить прямо (тост легко не заметить —
    /// например, в маленьком окне со входом из другой программы). Не чаще раза в 20 секунд
    private static var lastAsk = Date.distantPast
    static func askRestart(_ url: URL?) {
        guard Date().timeIntervalSince(lastAsk) > 20 else { return }
        lastAsk = Date()
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = "Restart Sapfire to open this page through the VPN"
            a.informativeText = "\(url?.host ?? "This page") is in a profile you just switched to the VPN. Until Sapfire restarts, its pages don’t load, so nothing goes around the tunnel. Your tabs come back after the restart."
            a.addButton(withTitle: "Restart Now")
            a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn { AppRelaunch.now() }
        }
    }

    static func set(_ profile: UUID, _ on: Bool) {
        var p = profiles
        if on { p.insert(profile) } else { p.remove(profile) }
        UserDefaults.standard.set(p.map(\.uuidString), forKey: key)
        let m = BrowserModel.current
        let store = profile == Profile.primaryID ? WKWebsiteDataStore.default() : BrowserModel.store(for: profile)
        let used = BrowserModel.usedStores.contains(ObjectIdentifier(store))
        applyAll()
        if used { if on { needsRestart.insert(profile) } else { needsRestart.remove(profile) } }
        // Открытые страницы профиля (и его одноразовые вкладки, и «Open As» им в других пространствах) — заново, по новой дороге
        for w in BrowserModel.windows {
            for sp in w.spaces where !sp.isIncognito {
                for t in sp.tabs where t.webView != nil && (t.effectiveProfileID ?? sp.profileID) == profile {
                    let visible = BrowserModel.visibleAnywhere(t)
                    t.sleep()
                    t.dropTempStore()
                    if visible && !needsRestart.contains(profile) { t.ensureWebView() }
                }
            }
        }
        let name = m.profiles.first { $0.id == profile }?.name ?? "Profile"
        if used {
            let a = NSAlert()
            a.messageText = on ? "Restart Sapfire to send “\(name)” through the VPN" : "“\(name)” goes directly after Sapfire restarts"
            a.informativeText = on
                ? "Its pages have already connected directly, and the web engine can’t switch them over on the fly. Until Sapfire restarts, pages of this profile won’t load — nothing goes around the tunnel."
                : "Until then its pages keep going through the VPN proxy."
            a.addButton(withTitle: "Restart Now")
            a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn { AppRelaunch.now() }
            return
        }
        m.showToast(on ? "“\(name)” goes through the VPN proxy" : "“\(name)” goes directly")
        if on { check(m) }
    }

    /// Пространство с туннелем на экране, а прокси молчит — сказать (не чаще раза в полминуты)
    private static var lastCheck = Date.distantPast
    static func check(_ m: BrowserModel, force: Bool = true) {
        guard force || Date().timeIntervalSince(lastCheck) > 30 else { return }
        lastCheck = Date()
        Incognito.reachable { ok in
            if !ok { m.showToast("The VPN proxy is off — pages of this profile won’t load. Start your VPN app") }
        }
    }

    /// Открыто пространство с туннелем (для своих запросов: подсказки поиска, значки сайтов)
    static var currentOn: Bool {
        let sp = BrowserModel.current.currentSpace
        return !sp.isIncognito && isOn(sp.profileID)
    }

    /// Сессия для своих запросов из открытого пространства: через туннель, если он у профиля включён
    static var currentSession: URLSession? {
        if BrowserModel.current.currentSpace.isIncognito { return Incognito.session() }
        return currentOn ? Incognito.proxySession(Incognito.endpoint) : .shared
    }
}

/// Перезапуск Sapfire (вкладки сохраняются при выходе)
enum AppRelaunch {
    static func now() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while pgrep -x Sapfire >/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
