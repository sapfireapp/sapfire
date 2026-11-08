import AppKit
import CoreLocation
import WebKit

// MARK: - Геолокация для сайтов

/// Движок Safari в чужих программах местоположение сайтам не отдаёт — отвечаем сами: страница спрашивает
/// navigator.geolocation → Sapfire спрашивает тебя (Allow / Don’t Allow, можно запомнить для сайта) →
/// местоположение берём у macOS (Службы геолокации) и отдаём странице. Разрешение для сайта — в центре сайта.
final class Geolocation: NSObject, WKScriptMessageHandler, CLLocationManagerDelegate {
    static let shared = Geolocation()

    private let manager = CLLocationManager()
    private struct Request {
        weak var wv: WKWebView?
        let frame: WKFrameInfo
        let id: Int
        let watch: Bool
    }
    /// Ждут первого местоположения (разовые запросы)
    private var waiting: [Request] = []
    /// Следят за перемещением (watchPosition)
    private var watchers: [Request] = []
    /// Ждут, пока macOS спросит разрешение у Sapfire
    private var afterAuth: [(Bool) -> Void] = []
    private var last: CLLocation?
    /// Решения «на этот раз» (без галки «запомнить») — до выхода из Sapfire
    private var sessionAllowed = Set<String>(), sessionDenied = Set<String>()
    /// Уже открытый вопрос по сайту — новые запросы того же сайта ждут его ответа
    private var asking: [String: [(Bool) -> Void]] = [:]
    private var warnedSystem = false

    /// Закрыли инкогнито — решения «на этот раз» забываем
    func forgetSession() { sessionAllowed = []; sessionDenied = [] }

    override init() {
        super.init()
        manager.delegate = self
    }

    func install(in c: WKUserContentController) {
        c.addUserScript(WKUserScript(source: Self.js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        c.add(self, name: "sfGeo")
    }

    // MARK: Запросы страницы

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let wv = message.webView, let body = message.body as? [String: Any] else { return }
        let frame = message.frameInfo
        if let clear = body["clear"] as? Int {
            watchers.removeAll { $0.id == clear && $0.wv === wv }
            stopIfIdle()
            return
        }
        guard let id = body["id"] as? Int else { return }
        let origin = frame.securityOrigin
        let url = URL(string: "\(origin.protocol)://\(origin.host)")
        // Как в движке: только защищённым страницам. Чужая рамка (карта другого сайта внутри страницы)
        // местоположение не получает — иначе любой встроенный виджет спрашивал бы от своего имени
        let foreign = !frame.isMainFrame && BrowserModel.baseDomain(origin.host) != BrowserModel.baseDomain(wv.url?.host)
        guard origin.protocol == "https", !foreign else {
            if body["perm"] as? Bool == true { reply(wv, frame, id, ["perm": "denied"]) }
            else { reply(wv, frame, id, ["error": 1, "message": foreign ? "Geolocation is not allowed in this frame" : "Only secure origins can request geolocation"]) }
            return
        }
        // Решения «на этот раз» — у инкогнито свои
        let site = (BrowserModel.isIncognito(wv) ? "incognito:" : "") + (SiteSettings.site(url) ?? origin.host)

        // navigator.permissions.query({name: "geolocation"})
        if body["perm"] as? Bool == true {
            let pref = SiteSettings.shared.prefs(url, incognito: BrowserModel.isIncognito(wv)).location
            let state = sessionDenied.contains(site) || pref == "deny" || systemDenied ? "denied"
                : (sessionAllowed.contains(site) || pref == "allow") && systemAllowed ? "granted" : "prompt"
            reply(wv, frame, id, ["perm": state])
            return
        }

        let req = Request(wv: wv, frame: frame, id: id, watch: body["watch"] as? Bool ?? false)
        let high = body["high"] as? Bool ?? false
        decide(site: site, url: url, in: wv) { [weak self] ok in
            guard let self else { return }
            guard ok else { self.fail(req, 1, "User denied Geolocation"); return }
            self.start(req, high: high)
        }
    }

    /// Можно ли сайту: по настройке сайта, по решению в этом сеансе или спросить
    private func decide(site: String, url: URL?, in wv: WKWebView, _ done: @escaping (Bool) -> Void) {
        switch SiteSettings.shared.prefs(url, incognito: BrowserModel.isIncognito(wv)).location {
        case "allow": done(true); return
        case "deny": done(false); return
        default: break
        }
        if sessionAllowed.contains(site) { done(true); return }
        if sessionDenied.contains(site) { done(false); return }
        if asking[site] != nil { asking[site]!.append(done); return }
        asking[site] = [done]

        let incognito = BrowserModel.isIncognito(wv)
        let a = NSAlert()
        a.messageText = "“\(SiteSettings.site(url) ?? site)” would like to use your current location"
        a.informativeText = "The website will know where you are — for maps, delivery or places nearby."
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Don’t Allow")
        if !incognito {
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Remember for this website"
        }
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self else { return }
            let ok = r == .alertFirstButtonReturn
            if a.suppressionButton?.state == .on {
                SiteSettings.shared.update(url, incognito: incognito) { $0.location = ok ? "allow" : "deny" }
            } else if ok {
                self.sessionAllowed.insert(site)
            } else {
                self.sessionDenied.insert(site)
            }
            let list = self.asking.removeValue(forKey: site) ?? []
            list.forEach { $0(ok) }
        }
        if let w = wv.window, w.attachedSheet == nil { a.beginSheetModal(for: w, completionHandler: finish) } else { finish(a.runModal()) }
    }

    // MARK: Местоположение от macOS

    private var status: CLAuthorizationStatus { manager.authorizationStatus }
    private var systemAllowed: Bool { status == .authorizedAlways || status == .authorized }
    private var systemDenied: Bool { status == .denied || status == .restricted }

    private func start(_ req: Request, high: Bool) {
        if status == .notDetermined {
            afterAuth.append { [weak self] ok in
                guard let self else { return }
                if ok { self.start(req, high: high) } else { self.fail(req, 1, "Location Services are off for Sapfire") }
            }
            manager.requestWhenInUseAuthorization()
            return
        }
        guard systemAllowed else {
            fail(req, 1, "Location Services are off for Sapfire")
            if !warnedSystem {
                warnedSystem = true
                BrowserModel.current.showToast("Turn on Location Services for Sapfire in System Settings → Privacy & Security")
            }
            return
        }
        if high { manager.desiredAccuracy = kCLLocationAccuracyBest }
        else if manager.desiredAccuracy == kCLLocationAccuracyBest && watchers.isEmpty { manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }
        // Свежее местоположение уже есть — отвечаем сразу
        if let l = last, Date().timeIntervalSince(l.timestamp) < 60 {
            send(l, to: req)
            if !req.watch { return }
        }
        if req.watch { watchers.append(req) } else { waiting.append(req) }
        manager.startUpdatingLocation()
        // Разовый запрос не ждёт вечно
        if !req.watch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.waiting.contains(where: { $0.id == req.id && $0.wv === req.wv }) else { return }
                self.waiting.removeAll { $0.id == req.id && $0.wv === req.wv }
                self.fail(req, 3, "Timeout expired")
                self.stopIfIdle()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard status != .notDetermined else { return }
        let list = afterAuth
        afterAuth = []
        list.forEach { $0(systemAllowed) }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        last = l
        let once = waiting
        waiting = []
        once.forEach { send(l, to: $0) }
        watchers.removeAll { $0.wv == nil }
        watchers.forEach { send(l, to: $0) }
        stopIfIdle()
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .locationUnknown { return }       // ещё ищет — подождём
        let all = waiting + watchers
        waiting = []
        all.forEach { fail($0, 2, "Position unavailable") }
        watchers = []
        stopIfIdle()
    }

    private func stopIfIdle() {
        if waiting.isEmpty && watchers.isEmpty { manager.stopUpdatingLocation() }
    }

    // MARK: Ответ странице

    private func send(_ l: CLLocation, to r: Request) {
        var d: [String: Any] = ["lat": l.coordinate.latitude, "lon": l.coordinate.longitude,
                                "acc": l.horizontalAccuracy, "ts": l.timestamp.timeIntervalSince1970 * 1000]
        if l.verticalAccuracy >= 0 { d["alt"] = l.altitude; d["altAcc"] = l.verticalAccuracy }
        if l.speed >= 0 { d["speed"] = l.speed }
        if l.course >= 0 { d["heading"] = l.course }
        guard let wv = r.wv else { return }
        reply(wv, r.frame, r.id, d) { [weak self] alive in
            // Страницу уже сменили — слежение больше не нужно
            if !alive, r.watch { self?.watchers.removeAll { $0.id == r.id && $0.wv === wv }; self?.stopIfIdle() }
        }
    }

    private func fail(_ r: Request, _ code: Int, _ message: String) {
        guard let wv = r.wv else { return }
        reply(wv, r.frame, r.id, ["error": code, "message": message])
    }

    private func reply(_ wv: WKWebView, _ frame: WKFrameInfo, _ id: Int, _ d: [String: Any], alive: ((Bool) -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: d), let json = String(data: data, encoding: .utf8) else { return }
        wv.evaluateJavaScript("!!(window.__sfGeo && window.__sfGeo(\(id), \(json)))", in: frame, in: .page) { r in
            if case .success(let v) = r { alive?((v as? Bool) ?? false) } else { alive?(false) }
        }
    }

    // MARK: Страница: navigator.geolocation и permissions.query

    private static let js = """
    (function(){
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sfGeo;
      if (!h) return;
      var cbs = {}, n = 0;
      function err(code, message){ return {code: code, message: message || '', PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3}; }
      function ask(ok, fail, o, watch){
        var id = ++n; cbs[id] = {ok: ok, fail: fail, watch: watch};
        h.postMessage({id: id, high: !!(o && o.enableHighAccuracy), watch: !!watch});
        return id;
      }
      Object.defineProperty(window, '__sfGeo', {value: function(id, r){
        var c = cbs[id]; if (!c) return false;
        if (c.perm) { delete cbs[id]; c.perm({state: r.perm, name: 'geolocation', onchange: null,
                        addEventListener: function(){}, removeEventListener: function(){}}); return true; }
        if (r.error) { delete cbs[id]; if (c.fail) try { c.fail(err(r.error, r.message)); } catch(e){} return true; }
        if (!c.watch) delete cbs[id];
        var coords = {latitude: r.lat, longitude: r.lon, accuracy: r.acc,
                      altitude: r.alt === undefined ? null : r.alt, altitudeAccuracy: r.altAcc === undefined ? null : r.altAcc,
                      heading: r.heading === undefined ? null : r.heading, speed: r.speed === undefined ? null : r.speed};
        coords.toJSON = function(){ return {latitude: coords.latitude, longitude: coords.longitude, accuracy: coords.accuracy,
                        altitude: coords.altitude, altitudeAccuracy: coords.altitudeAccuracy, heading: coords.heading, speed: coords.speed}; };
        var pos = {coords: coords, timestamp: r.ts, toJSON: function(){ return {coords: coords.toJSON(), timestamp: r.ts}; }};
        try { c.ok(pos); } catch(e){}
        return true;
      }});
      var geo = {
        getCurrentPosition: function(ok, fail, o){ ask(ok, fail, o, false); },
        watchPosition: function(ok, fail, o){ return ask(ok, fail, o, true); },
        clearWatch: function(id){ if (cbs[id]) { delete cbs[id]; h.postMessage({clear: id}); } }
      };
      try { Object.defineProperty(navigator, 'geolocation', {get: function(){ return geo; }, configurable: true}); } catch(e){}
      var P = navigator.permissions;
      if (P && P.query) {
        var q = P.query.bind(P);
        P.query = function(d){
          if (d && d.name === 'geolocation') return new Promise(function(res){ var id = ++n; cbs[id] = {perm: res}; h.postMessage({id: id, perm: true}); });
          return q(d);
        };
      }
    })();
    """
}
