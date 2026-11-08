import AppKit
import SwiftUI
import WebKit
import Observation

// MARK: - Tab

@Observable
final class Tab: Identifiable {
    let id: UUID
    var title: String
    /// Своё название (Rename… или Tidy Tab Titles); nil — название страницы
    var customTitle: String?
    var url: URL?
    var isPinned: Bool
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var asleep = true
    /// Папка в боковой панели (nil — вкладка лежит в общем списке)
    var folderID: UUID?
    /// Маленький снимок страницы для ⌃Tab и обзора вкладок
    var preview: NSImage?
    /// Цвет фона страницы (для фона окна, «мостика» и выреза). Пока страница грузится —
    /// берётся запомненный цвет сайта, чтобы не было вспышки стандартного белого.
    var pageColor: NSColor?
    @ObservationIgnored private var liveColor: NSColor?
    /// Сон без потерь: состояние страницы на момент засыпания (назад/вперёд, прокрутка, текст в полях — interactionState
    /// движка) и её адрес; при пробуждении — восстанавливается, если вкладка всё ещё на том же адресе. Только в памяти
    @ObservationIgnored private var sleepState: (url: URL, data: Any)?
    /// Фон страницы из стилей (html/body) — PageColorProbe; для подсчёта по пикселям, когда в окне одни картинки
    @ObservationIgnored var cssBase: NSColor?
    @ObservationIgnored private var colorReady = false

    /// Крайний левый столбик пикселей страницы — его растягивают до левого края окна (фон, «мостик»)
    var edgeStrip: EdgeStrip?

    /// Подсчитанный цвет отличается от того, что страница сообщила последним
    func liveColorDiffers(_ c: NSColor) -> Bool { liveColor.map { !$0.isClose(to: c) } ?? true }

    /// Страница сообщила свой цвет фона (PageColorProbe)
    func pageReportedColor(_ c: NSColor) {
        liveColor = c
        // Пока грузится — ранний (часто белый) цвет не показываем
        if colorReady && !isIncognito { PageColorStore.save(c, for: url) }
        refreshColor()
    }

    /// Выбрать цвет: настоящий (страница догрузилась) или запомненный для сайта
    private func refreshColor() {
        if colorReady, let c = liveColor {
            if pageColor != c { pageColor = c }
        } else if let cached = PageColorStore.color(for: url) {
            if pageColor != cached { pageColor = cached }
        }
    }
    /// Что заблокировано на открытой странице (центр сайта → Privacy)
    /// Что заблокировано на странице и каким списком
    struct BlockedLoad { var url: URL; var list: String }
    var blocked: [BlockedLoad] = []
    /// Играет звук/видео (обновляется, пока открыт обзор вкладок)
    var playing = false
    /// Прямо сейчас слышен звук (движок сообщает сам)
    var audible = false
    /// Адрес закреплённого сайта — куда он возвращается (ушёл вглубь — можно вернуться)
    var pinnedURL: URL?
    /// Закреплённый сайт ушёл со своего адреса
    var awayFromPin: Bool {
        guard isPinned, let home = pinnedURL, let u = url else { return false }
        return Self.norm(home) != Self.norm(u)
    }
    static func norm(_ u: URL) -> String {
        var h = (u.host ?? "").lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        var s = h + u.path
        while s.hasSuffix("/") { s.removeLast() }
        return s + (u.query.map { "?" + $0 } ?? "")
    }
    /// Вернуться на адрес закрепления
    func backToPin() { if let home = pinnedURL { load(home) } }
    /// Спящую закреплённую — снова на адрес закрепления (и название с него, иначе строка показывала бы последнюю страницу)
    func resetToPin() {
        guard isPinned, webView == nil, let home = pinnedURL, url.map({ Self.norm($0) != Self.norm(home) }) ?? true else { return }
        url = home
        sleepState = nil
        title = HistoryStore.shared.title(for: home) ?? ""
    }
    /// Закреплённые помнят последнюю страницу после сна и перезапуска (Settings → Tabs)
    static var pinnedRemember: Bool { UserDefaults.standard.bool(forKey: Prefs.pinnedRemember) }

    /// Звук вкладки выключен
    var muted = false {
        didSet { if let wv = webView { AudioWatch.setMuted(wv, muted) } }
    }
    @ObservationIgnored private var audioWatch: AudioWatch?
    /// Страница переведена (значок в адресе; клик — оригинал)
    var translated = false

    /// «Open As»: вкладка со входами другого профиля (nil — как у пространства)
    var profileOverride: UUID?
    /// Одноразовый контейнер: чистые куки только в памяти; закрыл вкладку — стёрто (между запусками не сохраняется)
    var temporary = false
    @ObservationIgnored private var tempStore: WKWebsiteDataStore?

    /// Чьи входы и куки у вкладки: одноразовые, профиля «Open As» или своего пространства
    var dataStore: WKWebsiteDataStore {
        let space = browser?.space(of: self)
        if space?.isIncognito == true { return space!.dataStore }
        if temporary {
            if let s = tempStore { return s }
            let s = WKWebsiteDataStore.nonPersistent()
            WebEngine.applyCookies(to: s)
            // Пространство через туннель — и одноразовая вкладка тоже
            if let sp = space, Tunnel.isOn(sp.profileID), let p = Incognito.endpoint { s.proxyConfigurations = [p] }
            tempStore = s
            return s
        }
        // Профиль «Open As» могли удалить — тогда как у пространства
        if let id = profileOverride, id == Profile.primaryID || id == Profile.vpnID || (browser?.profiles.contains { $0.id == id } ?? false) {
            return id == Profile.primaryID ? .default() : BrowserModel.store(for: id)
        }
        return space?.dataStore ?? .default()
    }
    /// Профиль, чьими входами открыта вкладка (для метки и туннеля)
    var effectiveProfileID: UUID? { temporary ? nil : profileOverride ?? browser?.space(of: self)?.profileID }
    /// Одноразовое хранилище — забыть (вкладку закрыли)
    func dropTempStore() { tempStore = nil }

    /// Автообновление: раз в столько секунд (nil — выключено); сохранять ли масштаб и место на странице
    var autoReload: Int?
    var reloadKeepView = true

    @ObservationIgnored var lastActive = Date() { didSet { activeMark = ActiveClock.shared.now } }
    /// То же по «часам присутствия» (ActiveClock): для архива, если время считается, пока ты за Mac
    @ObservationIgnored var activeMark = ActiveClock.shared.now
    /// Когда вкладку открыли (у старых сохранений — неизвестно)
    @ObservationIgnored var opened: Date? = Date()
    /// С какой вкладки открыта (ссылкой) — новые встают под ней. У веточки — её сохранённый «родитель».
    @ObservationIgnored var openerID: UUID?
    /// Веточка: временная вкладка, открытая ссылкой из сохранённой вкладки в папке. Висит под ней
    /// с отступом и уходит в авто-архив; перетащишь или закрепишь — станет сохранённой.
    var isBranch = false
    /// Сохранённая вкладка над разделителем (закладка-строка): в архив не уходит
    var isSaved = false
    /// В каком окне показана страница (общий закреплённый может быть выбран в двух окнах — страница одна)
    var hostID: UUID?
    /// Веточки под этой вкладкой раскрыты
    var branchesExpanded = true
    /// Веточки под этой вкладкой не уходят в авто-архив
    var keepBranches = false
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    /// Окно, где сейчас работают (вкладки общие для всех окон; присваивание ничего не меняет)
    var browser: BrowserModel? {
        get { BrowserModel.current }
        set {}
    }

    init(id: UUID = UUID(), url: URL?, title: String = "", isPinned: Bool = false) {
        self.id = id
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.pageColor = PageColorStore.color(for: url)
    }

    var displayTitle: String {
        if let c = customTitle, !c.isEmpty { return c }
        if !title.isEmpty { return title }
        if let host = url?.host { return host }
        return "New Tab"
    }

    /// Создаёт WKWebView при первом показе (или после «сна»).
    /// Вкладка живёт в инкогнито-пространстве
    var isIncognito: Bool { browser?.space(of: self)?.isIncognito ?? false }

    @discardableResult
    func ensureWebView(configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let wv = webView { return wv }
        let config = configuration ?? BrowserModel.makeConfiguration(store: dataStore)
        let wv = SapfireWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = false   // свой жест: PageSwipe (чуть сдвинуть и проявить)
        // Не заливать белым ещё не отрисованные участки (при расширении страницы) — под ними подложка цвета сайта
        if !Perf.off("opaque"), wv.responds(to: NSSelectorFromString("_setDrawsBackground:")) || wv.responds(to: NSSelectorFromString("setDrawsBackground:")) { wv.setValue(false, forKey: "drawsBackground") }
        wv.allowsMagnification = true
        if #available(macOS 13.3, *), !Perf.off("inspect") { wv.isInspectable = true }
        wv.navigationDelegate = browser?.delegate
        wv.uiDelegate = browser?.delegate
        webView = wv
        observe(wv)
        if configuration == nil, let url {
            // Сон без потерь: та же страница — из сохранённого состояния (назад/вперёд, прокрутка, поля), не заново
            if #available(macOS 12.0, *), let s = sleepState, Self.norm(s.url) == Self.norm(url) {
                wv.interactionState = s.data
                if wv.url == nil { wv.load(URLRequest(url: url)) }
            } else {
                wv.load(URLRequest(url: url))
            }
        }
        sleepState = nil
        lastActive = Date()
        if asleep { DispatchQueue.main.async { self.asleep = false } }
        // Новая страница — в рамку на экране (если её не забрала сама рамка)
        DispatchQueue.main.async { [weak self] in if let self, self.webView === wv, wv.superview == nil { WebViewHost.Container.refresh(self) } }
        return wv
    }

    /// Взять уже готовую страницу (из маленького окна)
    func attach(_ wv: WKWebView) {
        wv.navigationDelegate = browser?.delegate
        wv.uiDelegate = browser?.delegate
        webView = wv
        observe(wv)
        isLoading = wv.isLoading
        canGoBack = wv.canGoBack
        canGoForward = wv.canGoForward
        lastActive = Date()
        asleep = false
    }

    func load(_ newURL: URL) {
        url = newURL
        if let wv = webView {
            wv.load(URLRequest(url: newURL))
        } else {
            ensureWebView()
        }
    }

    func reload() {
        guard let wv = webView else { ensureWebView(); return }
        // Страница ещё не открылась (первый ответ не пришёл) — движку нечего обновлять, reload() молча ничего не делает,
        // а если открыта прежняя — обновил бы её, а не ту, что грузится. Грузим заново адрес, который открывали
        let committed = wv.backForwardList.currentItem?.url
        if let u = wv.url ?? url, committed == nil || (wv.isLoading && committed != u) {
            wv.stopLoading()
            wv.load(URLRequest(url: u))
        } else {
            wv.reload()
        }
    }

    /// Отдать страницу (в отдельное окно): вкладка её больше не держит, сама страница продолжает жить
    func detachWebView() {
        observers = []
        audioWatch = nil
        audible = false
        webView = nil
        asleep = true
        isLoading = false
    }

    /// Выгружает страницу из памяти, оставляя адрес и заголовок.
    func sleep() {
        guard let wv = webView else { return }
        observers = []
        audioWatch = nil
        audible = false
        EditingFocus.shared.forget(wv)
        LastLink.shared.forget(wv)
        MediaFrames.shared.forget(wv)
        StallWatch.forget(wv)
        // Звук — сразу: страница уходит из памяти не мгновенно (её держит растворение при переключении, движок),
        // и видео ещё играло бы несколько секунд после закрытия вкладки
        wv.pauseAllMediaPlayback()
        wv.closeAllMediaPresentations()
        AudioWatch.setMuted(wv, true)
        wv.stopLoading()
        if #available(macOS 12.0, *), let u = wv.url, let s = wv.interactionState { sleepState = (u, s) }
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        wv.removeFromSuperview()
        webView = nil
        asleep = true
        isLoading = false
    }

    private func observe(_ wv: WKWebView) {
        audioWatch = AudioWatch(wv) { [weak self] on in if self?.audible != on { self?.audible = on } }
        if muted { AudioWatch.setMuted(wv, true) }
        observers = [
            wv.observe(\.title, options: [.new]) { [weak self] w, _ in
                DispatchQueue.main.async {
                    guard let t = w.title, !t.isEmpty, let self else { return }
                    self.title = t
                    if !self.isIncognito { HistoryStore.shared.retitle(w.url, t) }
                    Ext.changed(self, title: true)
                }
            },
            wv.observe(\.url, options: [.new]) { [weak self] w, _ in
                DispatchQueue.main.async {
                    guard let self, let u = w.url else { return }
                    let newHost = u.host != self.url?.host
                    self.url = u
                    if self.isIncognito, let h = u.host { FaviconStore.shared.markPrivate(h) }
                    // Вкладка «Open As» / «Through VPN» в обычном пространстве — по её входам, не по пространству
                    else if let h = u.host, let sp = self.browser?.space(of: self), Tunnel.isOn(self.effectiveProfileID ?? sp.profileID) { FaviconStore.shared.markTunneled(h) }
                    Ext.changed(self, url: true)
                    if newHost { self.colorReady = false; self.refreshColor() }   // другой сайт — сразу его запомненный цвет
                }
            },
            wv.observe(\.isLoading, options: [.new]) { [weak self] w, _ in
                DispatchQueue.main.async {
                    self?.isLoading = w.isLoading
                    if let t = self { Ext.changed(t, loading: true) }
                    if let t = self {
                        if w.isLoading { t.colorReady = false }
                        else {
                            // Страница догрузилась — её цвет настоящий: показываем и запоминаем для сайта
                            t.colorReady = true
                            PageColorProbe.request(w)   // свежий цвет придёт сообщением со страницы
                            if !t.isIncognito { HistoryStore.shared.visit(w.url, title: w.title ?? t.title) }
                        }
                    }
                    // Страница догрузилась и на экране — обновим её превью
                    if !w.isLoading, let t = self, BrowserModel.visibleAnywhere(t) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { t.capturePreview() }
                    }
                }
            },
            wv.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
                DispatchQueue.main.async { self?.progress = w.estimatedProgress }
            },
            wv.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in
                DispatchQueue.main.async { self?.canGoBack = w.canGoBack }
            },
            wv.observe(\.canGoForward, options: [.new]) { [weak self] w, _ in
                DispatchQueue.main.async { self?.canGoForward = w.canGoForward }
            },
        ]
    }
}

// MARK: - Цвет фона страницы

/// Движок не сообщает цвет сайта, когда у страницы прозрачная подложка (а она нужна, чтобы по краям
/// не проступал белый), — поэтому цвет читает маленький скрипт и присылает при каждом изменении.
final class PageColorProbe: NSObject, WKScriptMessageHandler {
    static let shared = PageColorProbe()

    static let script = WKUserScript(source: """
    (function(){
      if (window.__sfColor) return;
      function bg(e){ if (!e) return null; var v = getComputedStyle(e).backgroundColor;
        return (!v || v === 'transparent' || /,\\s*0\\)$/.test(v)) ? null : v; }
      var last = null, t = null;
      // Цвет того, что видно у левого края страницы (там к ней примыкает панель): элемент в точке
      // и его предки до первого непрозрачного фона; по нескольким высотам — берём самый частый
      function at(y){ var e = document.elementFromPoint(1, y), v = null;
        while (e && !(v = bg(e))) e = e.parentElement; return v; }
      function edge(){ var h = window.innerHeight || 0; if (!h) return null;
        var n = {}, best = null;
        [8, h * 0.25, h * 0.5, h * 0.75, h - 8].forEach(function(y){ var v = at(y); if (v) { n[v] = (n[v] || 0) + 1; if (!best || n[v] > n[best]) best = v; } });
        return best; }
      function send(){ t = null;
        // Страница сейчас не принимает мышь (поверх выехала панель) — точки не находятся, не пересчитываем
        var m = document.getElementById('sf-mute'); if (m && m.textContent) return;
        var v = edge() || bg(document.documentElement) || bg(document.body) || '';
        // Шлём и тот же цвет: у края могла смениться картинка — Sapfire пересчитает по пикселям
        last = v;
        try { window.webkit.messageHandlers.sfColor.postMessage({edge: v, base: bg(document.documentElement) || bg(document.body) || ''}); } catch(e){} }
      // В фоне цвет никому не нужен — пересчёт при показе вкладки
      function soon(){ if (document.hidden) { t = 'later'; return; } if (!t) t = setTimeout(send, 60); }
      document.addEventListener('visibilitychange', function(){ if (!document.hidden && t === 'later') { t = null; soon(); } });
      window.__sfColor = function(){ last = null; t = null; send(); };
      var mo = new MutationObserver(soon), opts = {attributes: true, attributeFilter: ['class', 'style', 'data-theme', 'data-color-mode']};
      mo.observe(document.documentElement, opts);
      if (document.body) mo.observe(document.body, opts);
      else document.addEventListener('DOMContentLoaded', function(){ if (document.body) mo.observe(document.body, opts); soon(); });
      try { matchMedia('(prefers-color-scheme: dark)').addEventListener('change', soon); } catch(e){}
      document.addEventListener('transitionend', soon, true);
      // Прокрутили — у края могла оказаться другая часть страницы (редко и не чаще раза в 60 мс)
      window.addEventListener('scroll', soon, {passive: true});
      window.addEventListener('resize', soon);
      window.addEventListener('load', soon);
      send();
    })();
    """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)

    func install(in c: WKUserContentController) {
        c.addUserScript(Self.script)
        c.add(self, name: "sfColor")
    }

    static func request(_ wv: WKWebView) {
        wv.evaluateJavaScript("window.__sfColor && window.__sfColor();")
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let wv = message.webView, let tab = BrowserModel.shared.tab(for: wv) else { return }
        // Цвет из стилей — быстрая первая догадка (фон не задан — страница рисуется на белом).
        // Когда уже есть подсчёт по пикселям, он точнее: стили не видят фон-картинку или градиент
        let dict = message.body as? [String: Any]
        let edge = dict?["edge"] as? String ?? (message.body as? String ?? "")
        // Фон самой страницы (html/body) из стилей — опора, когда в окне одни картинки (лента, галерея)
        tab.cssBase = (dict?["base"] as? String).flatMap(Self.parse)
        if !PagePixels.measured(wv) {
            tab.pageReportedColor(Self.parse(edge) ?? .white)
        }
        PagePixels.schedule(wv, tab)
    }

    /// «rgb(r, g, b)» / «rgba(r, g, b, a)» / «color(srgb r g b)»
    static func parse(_ s: String) -> NSColor? {
        let nums = s.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        if s.hasPrefix("rgb"), nums.count >= 3 {
            if nums.count >= 4, nums[3] < 0.5 { return nil }
            return NSColor(srgbRed: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255, alpha: 1)
        }
        if s.hasPrefix("color(srgb"), nums.count >= 3 {
            return NSColor(srgbRed: nums[0], green: nums[1], blue: nums[2], alpha: 1)
        }
        return nil
    }
}

// MARK: - Цвет по пикселям

/// Какой цвет у левого края страницы (там к ней примыкает панель) на самом деле: снимок узкой полосы,
/// цвета округляются, побеждает тот, которого больше всего
enum PagePixels {
    private static var done = Set<ObjectIdentifier>()
    private static var work: [ObjectIdentifier: DispatchWorkItem] = [:]

    static func measured(_ wv: WKWebView) -> Bool { done.contains(ObjectIdentifier(wv)) }
    /// Новая страница — прежний подсчёт не годится
    static func reset(_ wv: WKWebView) { done.remove(ObjectIdentifier(wv)) }

    static func schedule(_ wv: WKWebView, _ tab: Tab) {
        let id = ObjectIdentifier(wv)
        work[id]?.cancel()
        let w = DispatchWorkItem { [weak wv, weak tab] in
            work[id] = nil
            guard let wv, let tab, wv.window != nil, !wv.isHidden else { return }
            measure(wv, base: tab.cssBase) { c, strip in
                if let strip { tab.edgeStrip = strip }
                guard let c else { return }
                done.insert(id)
                if tab.pageColor.map({ !$0.isClose(to: c) }) ?? true || tab.liveColorDiffers(c) { tab.pageReportedColor(c) }
            }
        }
        work[id] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    private static func measure(_ wv: WKWebView, base: NSColor?, _ done: @escaping (NSColor?, EdgeStrip?) -> Void) {
        let h = wv.bounds.height
        guard h > 20, let win = wv.window, let content = win.contentView else { done(nil, nil); return }
        // Где страница в окне (от верха окна)
        let f = wv.convert(wv.bounds, to: nil)
        let top = content.bounds.height - f.maxY
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = false
        // Вся ширина страницы, уменьшенная: крайний левый столбик — край, крайний правый — для сравнения
        // (полоса фона — шапка, подвал — идёт через всю ширину; картинка у левого края — нет)
        cfg.rect = CGRect(x: 0, y: 0, width: max(4, wv.bounds.width), height: h)
        cfg.snapshotWidth = NSNumber(value: Double(min(96, max(4, wv.bounds.width))))
        wv.takeSnapshot(with: cfg) { img, _ in
            guard let cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { done(nil, nil); return }
            let w = cg.width, hh = cg.height
            var px = [UInt8](repeating: 0, count: w * hh * 4)
            guard let ctx = CGContext(data: &px, width: w, height: hh, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { done(nil, nil); return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: hh))
            // Корзины по 32 оттенка на канал: сумма и число пикселей
            var count: [Int: Int] = [:], sum: [Int: (Int, Int, Int)] = [:]
            var total = 0
            // Цвет сайта — самый частый в левом столбике (как и раньше, когда снимали только его)
            for y in 0..<hh {
                let i = y * w * 4
                guard px[i + 3] > 200 else { continue }
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                let k = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                count[k, default: 0] += 1
                let s = sum[k] ?? (0, 0, 0)
                sum[k] = (s.0 + r, s.1 + g, s.2 + b)
                total += 1
            }
            // Страница ещё не нарисовалась (прозрачно) — не решаем
            guard total > hh / 3, let best = count.max(by: { $0.value < $1.value }), let s = sum[best.key] else { done(nil, nil); return }
            let n = CGFloat(best.value)
            var color = NSColor(srgbRed: CGFloat(s.0) / n / 255, green: CGFloat(s.1) / n / 255, blue: CGFloat(s.2) / n / 255, alpha: 1)
            // Крайний левый столбик (строки в памяти — сверху вниз); прозрачное — цветом большинства.
            // Край берём, только если это фон: тот же цвет, что у сайта вообще, или полоса через всю ширину
            // (шапка, подвал — у правого края тот же цвет). Иначе у края стоит картинка или блок — там цвет сайта,
            // а не цветная полоса в панели
            var bg = (r: UInt8(s.0 / best.value), g: UInt8(s.1 / best.value), b: UInt8(s.2 / best.value))
            func near(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8)) -> Bool {
                abs(Int(a.0) - Int(b.0)) + abs(Int(a.1) - Int(b.1)) + abs(Int(a.2) - Int(b.2)) < 48
            }
            // Фон страницы известен из стилей — самый частый цвет берём вместо него, только если он явно фон:
            // больше половины пикселей. Иначе это плитки ленты (стикеры на белом, картинки на голубом):
            // при прокрутке цвет прыгал бы в панели — берём фон страницы (html/body). Но лишь если этот фон
            // у края вообще виден: первый экран с градиентом поверх светлой страницы (цветов много, ни один
            // не в большинстве) — фон там градиент, а не бумага из стилей
            if let base = base?.usingColorSpace(.sRGB), n / CGFloat(total) < 0.5 {
                func u(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
                let b = (u(base.redComponent), u(base.greenComponent), u(base.blueComponent))
                var seen = 0
                for y in 0..<hh {
                    let i = y * w * 4
                    if px[i + 3] > 200, near(b, (px[i], px[i + 1], px[i + 2])) { seen += 1 }
                }
                if seen * 16 >= total { color = base; bg = b }
            }
            // Полоса через всю ширину (шапка, подвал): тот же цвет во всех столбиках, а не только у правого края —
            // две плитки ленты с одинаковыми подложками (между ними промежуток другого цвета) полосой не считаются
            func band(_ y: Int, _ left: (UInt8, UInt8, UInt8)) -> Bool {
                guard w > 8 else { return false }
                for x in stride(from: w / 8, through: w - 1, by: max(1, w / 8)) {
                    let j = y * w * 4 + x * 4
                    guard px[j + 3] > 200, near(left, (px[j], px[j + 1], px[j + 2])) else { return false }
                }
                return true
            }
            func pack(_ c: (UInt8, UInt8, UInt8)) -> UInt32 { UInt32(c.0) << 16 | UInt32(c.1) << 8 | UInt32(c.2) }
            func left(_ y: Int) -> (UInt8, UInt8, UInt8)? {
                let i = y * w * 4
                return px[i + 3] > 200 ? (px[i], px[i + 1], px[i + 2]) : nil
            }
            var raw = [UInt32](repeating: pack((bg.r, bg.g, bg.b)), count: hh)
            // Строка взята с края (не подставлен фон)
            var ok = [Bool](repeating: false, count: hh)
            var prev = (bg.r, bg.g, bg.b)
            for y in 0..<hh {
                guard let l = left(y) else { prev = (bg.r, bg.g, bg.b); continue }
                // …или плавно продолжает край строкой выше: градиент первого экрана (полосу рвёт текст и макет,
                // а край меняется постепенно); картинка у края начинается скачком — не проходит
                if near(l, (bg.r, bg.g, bg.b)) || band(y, l) || (y > 0 && ok[y - 1] && near(l, prev)) {
                    raw[y] = pack(l); ok[y] = true; prev = l
                } else { prev = (bg.r, bg.g, bg.b) }
            }
            // И снизу вверх: над первой целой полосой (шапка с кнопкой до правого края) — тот же градиент
            if hh > 1 {
                for y in stride(from: hh - 2, through: 0, by: -1) where !ok[y] && ok[y + 1] {
                    guard let l = left(y), let below = left(y + 1), near(l, below) else { continue }
                    raw[y] = pack(l); ok[y] = true
                }
            }
            // Тонкие линии (рамки, разделители в пару пикселей) растянутыми до края окна выглядят чёрточками —
            // в каждой строке берём самый частый цвет по соседству (крупные области и их границы остаются)
            let k = max(4, hh / 90)
            var rows = [UInt32](repeating: 0, count: hh)
            var near: [UInt32: Int] = [:]
            for y in 0..<min(hh, k) { near[raw[y] & 0xF8F8F8, default: 0] += 1 }
            for y in 0..<hh {
                let add = y + k, drop = y - k - 1
                if add < hh { near[raw[add] & 0xF8F8F8, default: 0] += 1 }
                if drop >= 0 { let key = raw[drop] & 0xF8F8F8; near[key]! -= 1; if near[key] == 0 { near[key] = nil } }
                let own = raw[y] & 0xF8F8F8
                let top = near.max { $0.value < $1.value }!
                // Своя строка не хуже самого частого — оставить как есть (граница не сдвигается)
                rows[y] = (near[own] ?? 0) >= top.value ? raw[y] : (raw[max(0, y - k)...min(hh - 1, y + k)].first { $0 & 0xF8F8F8 == top.key } ?? raw[y])
            }
            var col = [UInt8]()
            col.reserveCapacity(hh * 4)
            for v in rows { col += [UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255), 255] }
            var strip: EdgeStrip?
            if let prov = CGDataProvider(data: Data(col) as CFData),
               let line = CGImage(width: 1, height: hh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                strip = EdgeStrip(image: NSImage(cgImage: line, size: NSSize(width: 1, height: h)), top: top, height: h, rows: rows)
            }
            done(color, strip)
        }
    }
}

/// Крайний левый столбик страницы: картинка 1×высота и где страница в окне
struct EdgeStrip: Equatable {
    let image: NSImage
    let top: CGFloat
    let height: CGFloat
    let rows: [UInt32]

    /// Цвет края страницы на высоте `y` (от верха окна)
    func color(atY y: CGFloat) -> NSColor? {
        guard height > 0, !rows.isEmpty else { return nil }
        let i = Int((y - top) / height * CGFloat(rows.count))
        guard rows.indices.contains(i) else { return nil }
        let v = rows[i]
        return NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    static func == (a: EdgeStrip, b: EdgeStrip) -> Bool { a.rows == b.rows && a.top == b.top && a.height == b.height }
}

extension NSColor {
    /// Почти тот же цвет (разница незаметна) — не перекрашиваем
    func isClose(to o: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = o.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < 0.02
    }
}

// MARK: - Запомненные цвета сайтов

/// Связка «сайт → цвет фона»: хранится между запусками, чтобы фон окна сразу был верным.
enum PageColorStore {
    private static let key = "pageColors"
    private static var cache: [String: String] = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    private static var saveWork: DispatchWorkItem?

    static func color(for url: URL?) -> NSColor? {
        guard let h = url?.host, let v = cache[h] else { return nil }
        let p = v.split(separator: ",").compactMap { Double($0) }
        guard p.count == 3 else { return nil }
        return NSColor(srgbRed: p[0], green: p[1], blue: p[2], alpha: 1)
    }

    static func save(_ c: NSColor?, for url: URL?) {
        guard let h = url?.host, let c = c?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { return }
        let v = String(format: "%.3f,%.3f,%.3f", c.redComponent, c.greenComponent, c.blueComponent)
        guard cache[h] != v else { return }
        cache[h] = v
        // Пишем на диск не чаще раза в пару секунд
        saveWork?.cancel()
        let w = DispatchWorkItem { UserDefaults.standard.set(cache, forKey: key) }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }
}

// MARK: - Space

@Observable
final class Space: Identifiable {
    let id: UUID
    var name: String
    var icon: String
    var hue: Double
    /// Цвет панели (HSV): оттенок hue + насыщенность и яркость; по умолчанию — светлый пастельный
    var sat: Double = Space.defaultSat
    var bri: Double = Space.defaultBri
    static let defaultSat = 0.12
    static let defaultBri = 0.97
    /// Мягкий градиент панели (два размытых пятна поверх её цвета), nil — ровный цвет
    var glow: SpaceGlow?
    /// Прозрачность панели 0…1: сквозь неё виден размытый рабочий стол, как у меню
    var glass: Double = 0
    var tabs: [Tab] = []
    var folders: [Folder] = []
    /// Порядок верхнего уровня списка: папки и вкладки вне папок вперемешку (их id)
    var layout: [UUID] = []
    /// Закреплённые сайты берутся у другого пространства (общий набор), nil — свои
    var pinnedFrom: UUID?
    /// Сохранённое (над «Clear») свёрнуто: видна только открытая сейчас вкладка оттуда
    var savedCollapsed = false
    /// Временные (под «Temp») свёрнуты: видна только открытая сейчас вкладка оттуда
    var tempCollapsed = false
    var selectedTabID: UUID?
    /// Сплиты — постоянные группы вкладок (2–4), как в Arc: в панели — одной строкой, разделённой на части.
    /// Открыта вкладка из группы — на экране вся группа; открыл другую вкладку — группа остаётся в списке.
    var splitGroups: [[UUID]] = []
    static let maxPanes = 4
    /// Раскладка сплита: рядом, друг над другом или сеткой (у каждой вкладки группы — одна и та же запись)
    enum SplitArrange: String, Codable { case columns, rows, grid }
    var splitArrange: [UUID: SplitArrange] = [:]
    /// Доли панелей: рядом / друг над другом — по доле на панель; сетка — [доля левой колонки, доля верхнего ряда]
    var splitSizes: [UUID: [Double]] = [:]

    func arrange(of g: [UUID]) -> SplitArrange {
        let a = g.lazy.compactMap { self.splitArrange[$0] }.first ?? (g.count == 4 ? .grid : .columns)
        return a == .grid && g.count < 3 ? .columns : a
    }
    func setArrange(_ a: SplitArrange, for g: [UUID]) {
        for id in g { splitArrange[id] = a; splitSizes[id] = nil }
    }
    /// Доли панелей (если сохранённых нет или они для другого числа панелей — поровну)
    func sizes(of g: [UUID]) -> [Double] {
        let n = arrange(of: g) == .grid ? 2 : g.count
        if let s = g.lazy.compactMap({ self.splitSizes[$0] }).first(where: { $0.count == n }) { return s }
        return arrange(of: g) == .grid ? [0.5, 0.5] : Array(repeating: 1 / Double(n), count: n)
    }
    func setSizes(_ s: [Double], for g: [UUID]) { for id in g { splitSizes[id] = s } }

    /// Инкогнито: входы и куки только в памяти, пространство не сохраняется
    var isIncognito = false
    /// Чей это профиль: входы, куки и данные сайтов общие у пространств одного профиля
    var profileID: UUID = Profile.primaryID
    var profile: Profile {
        BrowserModel.shared.profiles.first { $0.id == profileID } ?? BrowserModel.shared.primaryProfile
    }

    /// Хранилище входов этого пространства — хранилище его профиля
    var dataStore: WKWebsiteDataStore {
        if isIncognito {
            if BrowserModel.incognitoStore == nil { BrowserModel.incognitoStore = BrowserModel.newIncognitoStore() }
            return BrowserModel.incognitoStore!
        }
        return profile.isPrimary ? .default() : BrowserModel.store(for: profileID)
    }

    init(id: UUID = UUID(), name: String, icon: String, hue: Double) {
        self.id = id
        self.name = name
        self.icon = icon
        self.hue = hue
    }

    /// Свои закреплённые (хранятся в этом пространстве)
    var ownPinned: [Tab] { tabs.filter { $0.isPinned } }
    /// Пространство, чьи закреплённые показываются здесь (само или то, у кого они общие)
    var pinOwner: Space {
        guard let id = pinnedFrom, let s = BrowserModel.shared.spaces.first(where: { $0.id == id }), s !== self else { return self }
        return s
    }
    /// Закреплённые, которые видны в этом пространстве
    var pinned: [Tab] { pinOwner.ownPinned }
    var unpinned: [Tab] { tabs.filter { !$0.isPinned } }
    func tabs(in f: Folder) -> [Tab] { tabs.filter { $0.folderID == f.id && !$0.isPinned } }

    /// Строка верхнего уровня списка: папка или вкладка вне папок
    enum Entry: Identifiable {
        case folder(Folder), tab(Tab)
        var id: UUID { switch self { case .folder(let f): f.id; case .tab(let t): t.id } }
        /// Под чертой «Temp»: временная вкладка или временная папка
        var isTemp: Bool { switch self { case .folder(let f): f.isTemp; case .tab(let t): !t.isSaved } }
    }

    /// Верхний уровень списка в порядке `layout`; новые вкладки и папки, которых там ещё нет, — сверху.
    var entries: [Entry] {
        // Веточки — не отдельные строки: они рисуются под своей вкладкой
        let loose = tabs.filter { !$0.isPinned && $0.folderID == nil && !$0.isBranch }
        var byID: [UUID: Entry] = [:]
        let top = folders.filter { $0.parentID == nil }
        for f in top { byID[f.id] = .folder(f) }
        for t in loose { byID[t.id] = .tab(t) }
        var out: [Entry] = [], seen = Set<UUID>()
        for id in layout { if let e = byID[id], !seen.contains(id) { out.append(e); seen.insert(id) } }
        let freshTabs = loose.filter { !seen.contains($0.id) }.map { Entry.tab($0) }
        let freshFolders = top.filter { !seen.contains($0.id) }.map { Entry.folder($0) }
        // Граница, как у Arc: сверху сохранённое (папки и сохранённые вкладки вперемешку), снизу временные — новые встают первыми
        func saved(_ e: Entry) -> Bool { switch e { case .tab(let t): t.isSaved; case .folder(let f): !f.isTemp } }
        let savedPart = out.filter(saved) + freshFolders + freshTabs.filter(saved)
        let tempPart = freshTabs.filter { !saved($0) } + out.filter { !saved($0) }
        return savedPart + tempPart
    }
    /// Сохранённая часть списка (над разделителем): папки и сохранённые вкладки
    var savedEntries: [Entry] { entries.filter { !$0.isTemp } }
    /// Временные вкладки и папки (под разделителем)
    var tempEntries: [Entry] { entries.filter(\.isTemp) }
    /// Папка вкладки (верхнего уровня) — временная
    func inTempFolder(_ t: Tab) -> Bool {
        guard let id = t.folderID, let f = folders.first(where: { $0.id == id }) else { return false }
        return topAncestor(of: f).isTemp
    }
    /// Вкладка временная: под «Temp» сама по себе или во временной папке
    func isTemp(_ t: Tab) -> Bool { !t.isPinned && (t.folderID == nil ? !t.isSaved : inTempFolder(t)) }
    /// Веточки под вкладкой — в порядке открытия
    func branches(of t: Tab) -> [Tab] { tabs.filter { $0.isBranch && $0.openerID == t.id } }
    /// Вкладки папки без веточек (веточки — под своими вкладками)
    func mainTabs(in f: Folder) -> [Tab] { tabs(in: f).filter { !$0.isBranch } }

    // Вложенные папки: у папки — папки внутри (сверху, над её вкладками), до трёх уровней
    static let maxFolderDepth = 2          // 0 — верхний уровень, 2 — третий
    func subfolders(of f: Folder) -> [Folder] { folders.filter { $0.parentID == f.id } }
    func parent(of f: Folder) -> Folder? { f.parentID.flatMap { id in folders.first { $0.id == id } } }
    /// Все папки внутри (на любой глубине)
    func descendants(of f: Folder) -> [Folder] { subfolders(of: f).flatMap { [$0] + descendants(of: $0) } }
    /// Уровень вложенности: 0 — папка верхнего уровня
    func depth(of f: Folder) -> Int { parent(of: f).map { depth(of: $0) + 1 } ?? 0 }
    /// Папка верхнего уровня, внутри которой лежит `f` (или сама `f`)
    func topAncestor(of f: Folder) -> Folder { parent(of: f).map { topAncestor(of: $0) } ?? f }
    /// Сколько уровней внутри папки (0 — вложенных папок нет)
    func height(of f: Folder) -> Int { subfolders(of: f).map { height(of: $0) + 1 }.max() ?? 0 }
    /// Все вкладки папки вместе с вложенными
    func allTabs(in f: Folder) -> [Tab] { subfolders(of: f).flatMap { allTabs(in: $0) } + tabs(in: f) }
    /// Папка `f` — это `a` или лежит внутри неё
    func isInside(_ f: Folder?, _ a: Folder) -> Bool {
        var cur = f
        while let c = cur { if c === a { return true }; cur = parent(of: c) }
        return false
    }
    /// Порядок вкладок внутри папки (как в панели): сначала вложенные папки, потом свои вкладки
    func deepTabs(_ f: Folder, kids: Bool = true) -> [Tab] {
        subfolders(of: f).flatMap { deepTabs($0, kids: kids) } + mainTabs(in: f).flatMap { [$0] + (kids ? branches(of: $0) : []) }
    }
    /// Вкладки вне папок (в порядке списка)
    var loose: [Tab] { entries.compactMap { if case .tab(let t) = $0 { t } else { nil } } }
    /// Порядок, в котором вкладки видны в списке
    var visual: [Tab] {
        func withKids(_ t: Tab) -> [Tab] { [t] + (t.branchesExpanded ? branches(of: t) : []) }
        return entries.flatMap { e -> [Tab] in
            switch e {
            // У свёрнутой папки видна только открытая сейчас вкладка
            case .folder(let f): visualTabs(f, withKids)
            case .tab(let t): withKids(t)
            }
        }
    }
    /// Видимые строки папки: раскрытая — вложенные папки и вкладки, свёрнутая — только открытая сейчас
    private func visualTabs(_ f: Folder, _ withKids: (Tab) -> [Tab]) -> [Tab] {
        f.expanded ? subfolders(of: f).flatMap { visualTabs($0, withKids) } + mainTabs(in: f).flatMap(withKids)
                   : allTabs(in: f).filter { BrowserModel.window(showing: self)?.isVisible($0) ?? false }
    }
    var ordered: [Tab] {
        pinned + entries.flatMap { e -> [Tab] in
            switch e { case .folder(let f): deepTabs(f); case .tab(let t): [t] + branches(of: t) }
        }
    }

    /// Приводит массив вкладок и порядок списка в согласие
    func normalize() {
        let ids = Set(folders.map(\.id))
        // Родитель папки пропал (удалили) или вложение замкнулось — папка встаёт на верхний уровень
        for f in folders where f.parentID != nil {
            var seen: Set<UUID> = [f.id], cur = f.parentID
            while let c = cur, ids.contains(c), !seen.contains(c) { seen.insert(c); cur = folders.first { $0.id == c }?.parentID }
            if let p = f.parentID, !ids.contains(p) || cur != nil { f.parentID = nil }
        }
        for t in tabs where t.folderID != nil && (!ids.contains(t.folderID!) || t.isPinned) { t.folderID = nil }
        // Веточка без родителя рядом (закрыли, перенесли) — становится обычной временной
        for t in tabs where t.isBranch {
            let parent = tabs.first { $0.id == t.openerID && !$0.isBranch && !$0.isPinned }
            if parent == nil || parent!.folderID != t.folderID || (parent!.folderID == nil && !parent!.isSaved) || t.isPinned {
                t.isBranch = false; t.folderID = nil; t.isSaved = false
            }
        }
        for t in tabs where t.isPinned || t.folderID != nil { t.isSaved = false }
        layout = entries.map(\.id)
        let placed = ownPinned + entries.flatMap { e -> [Tab] in
            switch e {
            case .folder(let f): deepTabs(f)
            case .tab(let t): [t] + branches(of: t)
            }
        }
        // Ничего не теряем: если вкладка почему-то не попала в список — в конец
        tabs = placed + tabs.filter { t in !placed.contains { $0 === t } }
    }
    /// Открытой может быть и вкладка из «Избранного» — оно общее для всех пространств
    var selectedTab: Tab? { find(selectedTabID) }
    /// Группа сплита, где лежит вкладка
    func group(of id: UUID?) -> [UUID]? { id.flatMap { i in splitGroups.first { $0.contains(i) } } }
    func groupTabs(_ g: [UUID]) -> [Tab] { g.compactMap { find($0) } }
    /// Все панели на экране по порядку (открыта вкладка из группы — вся группа)
    var paneTabs: [Tab] {
        if let g = group(of: selectedTabID) { return groupTabs(g) }
        return selectedTab.map { [$0] } ?? []
    }
    /// Остальные панели сплита на экране (кроме активной)
    var splitTabs: [Tab] { paneTabs.filter { $0.id != selectedTabID } }
    var splitTab: Tab? { splitTabs.first }
    func inPanes(_ id: UUID) -> Bool { paneTabs.contains { $0.id == id } }
    /// Вкладка уходит из сплита (закрыли, перенесли, убрали панель): группа из одной распадается.
    /// Была активной — активной становится соседняя панель. Вернёт true, если вкладка была в группе.
    @discardableResult
    func leavePanes(_ id: UUID) -> Bool {
        guard let gi = splitGroups.firstIndex(where: { $0.contains(id) }) else { return false }
        var g = splitGroups[gi]
        let k = g.firstIndex(of: id)!
        g.remove(at: k)
        if selectedTabID == id { selectedTabID = g[max(0, k - 1)] }
        if g.count < 2 { splitGroups.remove(at: gi) } else { splitGroups[gi] = g }
        return true
    }
    /// Сложить вкладки в одну группу сплита (из прежних групп они уходят)
    func makeGroup(_ ids: [UUID]) {
        let ids = Array(ids.reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }.prefix(Space.maxPanes))
        for id in ids { for gi in splitGroups.indices { splitGroups[gi].removeAll { $0 == id } } }
        splitGroups.removeAll { $0.count < 2 }
        if ids.count > 1 { splitGroups.append(ids) }
    }
    /// Вкладка — часть группы, но строкой не рисуется (группу рисует её первая вкладка из списка)
    func splitLead(of t: Tab) -> Tab? {
        guard let g = group(of: t.id) else { return nil }
        let members = groupTabs(g).filter { !$0.isPinned }
        return ordered.first { m in members.contains { $0 === m } }
    }
    func hiddenInSplit(_ t: Tab) -> Bool { !t.isPinned && splitLead(of: t).map { $0 !== t } ?? false }
    private func find(_ id: UUID?) -> Tab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
            ?? pinOwner.ownPinned.first { $0.id == id }            // общий закреплённый сайт
            ?? BrowserModel.shared.favorites.first { $0.id == id }
    }
    /// hue < 0 — бесцветное пространство
    var colorless: Bool { hue < 0 }
    /// Цвет самой панели — ровно тот, что выбран (без цвета — обычный фон окна)
    var panel: NSColor {
        colorless ? .windowBackgroundColor
                  : NSColor(hue: hue, saturation: sat, brightness: bri, alpha: 1)
    }
    /// Тёмная панель — текст и значки на ней светлые
    var darkPanel: Bool {
        guard !colorless, let c = panel.usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < 0.5
    }
    // Акценты — в тон панели, но всегда читаемые на ней
    private var accentSat: Double { max(sat, 0.5) }
    var tint: Color { colorless ? Color(white: 0.62) : Color(hue: hue, saturation: accentSat * 0.9, brightness: darkPanel ? 0.75 : 0.85) }
    /// Чистый цвет для значка пространства
    var iconColor: Color { colorless ? Color.secondary : Color(hue: hue, saturation: max(sat, 0.65), brightness: darkPanel ? 0.95 : 0.78) }
    /// Линия вставки при перетаскивании — в тон пространства, мягче системного синего
    var dropLine: Color { colorless ? Color(white: 0.5).opacity(0.8) : Color(hue: hue, saturation: accentSat, brightness: darkPanel ? 0.9 : 0.72).opacity(0.85) }
    /// Насыщенный вариант — для рамок выделения
    var tintStrong: Color { colorless ? Color(white: 0.42) : Color(hue: hue, saturation: max(sat, 0.6), brightness: darkPanel ? 0.85 : 0.62) }
}

// MARK: - Общие данные всех окон

@Observable
final class BrowserData {
    static let shared = BrowserData()
    var spaces: [Space] = []
    var profiles: [Profile] = [Profile(id: Profile.primaryID, name: "Primary")]
    var favorites: [Tab] = []
    /// Обычная ширина, к которой разворачивается узкая колонка
    var lastSidebarWidth: CGFloat = {
        let w = CGFloat(UserDefaults.standard.double(forKey: "sidebarWidthNormal"))
        return w >= 220 ? min(w, 420).rounded() : 262
    }() {
        didSet { UserDefaults.standard.set(Double(lastSidebarWidth), forKey: "sidebarWidthNormal") }
    }
    var sidebarWidth: CGFloat = {
        let w = CGFloat(UserDefaults.standard.double(forKey: "sidebarWidth"))
        if w <= 0 { return 262 }
        return w < 100 ? 56 : min(max(w, 220), 420).rounded()   // узкая колонка или обычная ширина
    }()
}

// MARK: - Browser

/// Куда ведёт командная строка. history / downloads — та же строка в режиме списка (⌘Y / ⌘⇧J).
enum CommandTarget { case newTab, current, split, history, downloads, archive }

enum Suggestion: Identifiable {
    case go(label: String, url: URL)
    case tab(Tab)
    case bang(Bang)
    /// Подсказка поисковика
    case search(String, URL)
    case history(HistoryStore.Entry)
    case download(DownloadStore.Item)
    case archived(ArchiveStore.Entry)
    /// Действие браузера (копировать ссылку, дублировать, сплит…)
    case action(CommandAction)

    var id: String {
        switch self {
        case .go(_, let url): return "go:" + url.absoluteString
        case .tab(let t): return "tab:" + t.id.uuidString
        case .bang(let b): return "bang:" + b.key
        case .search(let q, _): return "search:" + q
        case .history(let e): return "history:" + e.id
        case .download(let d): return "download:" + d.id.uuidString
        case .archived(let e): return "archived:" + e.id.uuidString
        case .action(let a): return "action:" + a.title
        }
    }
}

/// Уведомление справа сверху
struct Notice: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var icon: String?
    var action: String?
    var run: (() -> Void)?
    var hovered = false
    static let maxShown = 3
    static let life: TimeInterval = 3
    static let lifeWithAction: TimeInterval = 5
    static func == (a: Notice, b: Notice) -> Bool { a.id == b.id && a.hovered == b.hovered && a.text == b.text }
}

/// Профиль — человек или роль (Петя, Маша; личное, работа): свои куки, входы и данные сайтов.
/// Пространства идут одной лентой, у каждого — свой профиль; у пространств одного профиля входы общие.
@Observable
final class Profile: Identifiable {
    static let primaryID = UUID(uuidString: "00000000-0000-0000-0000-00000000F001")!
    /// Скрытый общий профиль «VPN»: сайты с «Through VPN» (Settings → Websites) открываются из него, всегда через туннель
    static let vpnID = UUID(uuidString: "00000000-0000-0000-0000-00000000F0F0")!
    let id: UUID
    var name: String
    var hue: Double          // < 0 — серый
    init(id: UUID = UUID(), name: String, hue: Double = -1) { self.id = id; self.name = name; self.hue = hue }
    var isPrimary: Bool { id == Self.primaryID }
    var color: Color { hue < 0 ? Color(white: 0.55) : Color(hue: hue, saturation: 0.55, brightness: 0.82) }
    static let hues: [Double] = [0.6, 0.33, 0.08, 0.9, 0.75, 0.48, 0.0, 0.14]
}

@Observable
final class BrowserModel {
    // MARK: Окна
    //
    // У каждого окна браузера — свой BrowserModel: какое пространство открыто, панель, сплит, командная строка,
    // перетаскивание, жесты. Пространства, вкладки и профили — общие (BrowserData), одни на всё приложение.
    // Одно пространство открыто только в одном окне — одна страница не может быть в двух окнах сразу.

    /// Первое окно (открывается при запуске)
    static let primary = BrowserModel(primary: true)
    /// Все окна браузера
    static var windows: [BrowserModel] = [primary]
    /// Окно, в котором сейчас работают (ключевое; если ключевое — не браузер, то последнее активное)
    static var current: BrowserModel {
        if let k = NSApplication.shared.keyWindow, let m = windows.first(where: { $0.window === k }) { return m }
        return lastActive ?? primary
    }
    static weak var lastActive: BrowserModel?
    /// Для кода вне окон (меню, клавиши, страницы): окно, в котором сейчас работают
    static var shared: BrowserModel { current }
    /// Окно, где открыта эта страница
    static func owner(of wv: WKWebView) -> BrowserModel {
        windows.first { $0.window != nil && $0.window === wv.window } ?? current
    }
    /// Окно, где открыто пространство
    static func window(showing sp: Space) -> BrowserModel? { windows.first { $0.currentSpaceID == sp.id && $0.window != nil } }
    /// Вкладка видна в каком-нибудь окне
    static func visibleAnywhere(_ t: Tab) -> Bool { windows.contains { $0.isVisible(t) } }

    let id = UUID()
    /// Своё окно
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var closeObserver: NSObjectProtocol?
    let isPrimary: Bool

    // Своё у каждого окна: перетаскивание, выделение, жесты, попапы…
    @ObservationIgnored lazy var drag = TabDrag()
    @ObservationIgnored lazy var activeRow = ActiveRow(model: self)
    @ObservationIgnored lazy var swipe = SpaceSwipe()
    @ObservationIgnored lazy var selection = TabSelection()
    @ObservationIgnored lazy var folderPeek = FolderPeekState()
    @ObservationIgnored lazy var hoverPreview = HoverPreview()
    @ObservationIgnored lazy var overview = TabOverview()
    @ObservationIgnored lazy var switcher = TabSwitcher()
    @ObservationIgnored lazy var find = FindController(model: self)
    @ObservationIgnored lazy var splitDrop = SplitDrop()
    @ObservationIgnored lazy var commandPos = CommandBarPosition()

    // Общее для всех окон — хранится в BrowserData
    private var data: BrowserData { BrowserData.shared }
    var spaces: [Space] { get { data.spaces } set { data.spaces = newValue } }
    var profiles: [Profile] { get { data.profiles } set { data.profiles = newValue } }
    var primaryProfile: Profile { profiles.first { $0.isPrimary }! }
    /// «Избранное» — общие для всех пространств вкладки (круглые значки сотами вверху панели)
    var favorites: [Tab] { get { data.favorites } set { data.favorites = newValue } }
    var lastSidebarWidth: CGFloat { get { data.lastSidebarWidth } set { data.lastSidebarWidth = newValue } }
    var sidebarWidth: CGFloat { get { data.sidebarWidth } set { data.sidebarWidth = newValue } }

    var currentSpaceID = UUID() {
        didSet {
            if !spaceTabbing, oldValue != currentSpaceID { touchSpaceMRU() }
            // Открыли пространство с туннелем — прокси должен работать (иначе страницы не грузятся)
            if oldValue != currentSpaceID, window != nil, let sp = spaces.first(where: { $0.id == currentSpaceID }),
               !sp.isIncognito, Tunnel.isOn(sp.profileID) { Tunnel.check(self, force: false) }
        }
    }
    var sidebarVisible = true
    /// Открыто окошко значка и цвета у этого пространства (правый клик по значку или меню Spaces)
    var spacePicker: UUID?
    /// «Reveal Tab in Sidebar»: к чему прокрутить список (строка верхнего уровня, сама вкладка)
    var revealTick = 0
    @ObservationIgnored var revealIDs: [UUID] = []
    /// Прокрутить так, чтобы вкладка была по центру (Reveal) или лишь бы видна (стрелки)
    @ObservationIgnored var revealCenter = true
    /// Узкая колонка значков ⇄ обычная ширина
    func toggleCompactSidebar() {
        let w = sidebarWidth == Metrics.compactWidth ? lastSidebarWidth : Metrics.compactWidth
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { sidebarWidth = w }
        UserDefaults.standard.set(Double(w), forKey: "sidebarWidth")
    }
    var sidebarPeek = false
    /// Открытые окошки поверх панели (центр сайта и т. п.) — пока есть, выехавшая панель не прячется
    @ObservationIgnored var popovers = 0
    /// Открыт ли сейчас какой-нибудь попап (или оторванная от него панель) — смотрим на сами окна,
    /// а не на счётчик: счётчик сбивался, если попап закрывался мимо onDisappear, и панель переставала прятаться
    static var popoverOpen: Bool {
        NSApp.windows.contains { w in
            w.isVisible && (w is FloatingPanel || String(describing: type(of: w)).contains("Popover"))
        }
    }
    /// Плавающая капсула сверху (при скрытой панели)
    var topBarShown = false
    @ObservationIgnored private var topBarWork: DispatchWorkItem?
    @ObservationIgnored private var topBarHovered = false

    static var topBarEnabled: Bool { UserDefaults.standard.object(forKey: Prefs.topBar) as? Bool ?? true }

    func topBarHover(_ on: Bool) { topBarHovered = on }
    /// Держать раскрытой (открыто окошко из неё)
    @ObservationIgnored var topBarHold = false

    /// Капсула сверху вообще уместна: полосы над страницей нет, строка команд закрыта
    /// (при закреплённой панели — тоже, над страницей)
    var topBarAllowed: Bool {
        Self.topBarEnabled && !PageToolbar.enabled && commandBar == nil && peek == nil
    }
    /// Сверху капсула (или её полоска) — загрузку показывает она, а не полоска над страницей.
    /// Одно условие на оба места, чтобы загрузка не двоилась
    var topLoaderShown: Bool { topBarAllowed }

    /// Раскрыть сразу (навели на полоску)
    func showTopBar() {
        topBarWork?.cancel(); topBarWork = nil
        if !topBarShown { topBarShown = true }
    }

    /// Вкладка «в закладках»: сохранённая (над чертой), в папке или закреплённая
    func isBookmarked(_ t: Tab) -> Bool {
        if let sp = space(of: t), sp.inTempFolder(t) { return false }
        return t.isSaved || t.isPinned || t.folderID != nil || isFavorite(t)
    }

    /// Звёздочка: временную вкладку — сохранить (над чертой, в архив не уходит), сохранённую — снова во временные
    func toggleBookmark(_ t: Tab) {
        guard let sp = space(of: t), !sp.isIncognito else { return }
        if t.isPinned || t.folderID != nil || isFavorite(t) {
            showToast(t.isPinned ? "The tab is pinned" : sp.inTempFolder(t) ? "The tab is in a temporary folder" : "The tab is saved in a folder")
            return
        }
        checkpoint(t.isSaved ? "Unsave Tab" : "Save Tab")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            t.isSaved.toggle()
            sp.normalize()
        }
        showToast(t.isSaved ? "Saved — stays above the line" : "Moved to temporary tabs")
    }

    /// Курсор у верхней кромки (панель скрыта): задержался ~0,12 с — капсула выезжает;
    /// ушёл ниже неё (с запасом) — прячется.
    private func topBarMoved(_ p: NSPoint, _ f: NSRect) {
        // С полосой над страницей капсула сверху не нужна — всё и так на виду
        guard Self.topBarEnabled, !PageToolbar.enabled, commandBar == nil else {
            if topBarShown { topBarShown = false }
            return
        }
        let inX = p.x > f.minX && p.x < f.maxX
        if topBarShown {
            if topBarHovered || topBarHold { return }
            if !inX || p.y < f.maxY - 90 || p.y > f.maxY + 20 { topBarWork?.cancel(); topBarWork = nil; topBarShown = false }
            return
        }
        if inX, p.y > f.maxY - 6, p.y <= f.maxY + 2, !sidebarPeek {
            guard topBarWork == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.topBarWork = nil
                let q = NSEvent.mouseLocation
                guard let win = self.mainWindow, q.y > win.frame.maxY - 8 else { return }
                self.topBarShown = true
            }
            topBarWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
        } else {
            topBarWork?.cancel(); topBarWork = nil
        }
    }

    // MARK: Выезд и скрытие панели по движению курсора
    //
    // Появление — по намерению: рука перед целью тормозит. Курсор в зоне у левой кромки
    // (а если вылетел изнутри окна — и в полосе за кромкой шириной в полпанели):
    //  • медленный или остановился — панель выезжает сразу;
    //  • резко тормозит и по замедлению видно, что встанет в зоне, — выезжает, не дожидаясь остановки;
    //  • летит почти на полной скорости — идёт дальше (на рабочий стол, другой монитор), не выезжает.
    // Скрытие: курсор ушёл левее зоны; резко пересёк правый край панели;
    // медленно пересёк его и ушёл ещё на 30 pt правее.
    // Если окно прижато к краю экрана, курсор дальше не уходит — движение «за край» копим виртуально.

    @ObservationIgnored private var peekHideWork: DispatchWorkItem?
    @ObservationIgnored private var peekStillWork: DispatchWorkItem?
    /// Где был бы курсор без упора в край экрана
    @ObservationIgnored private var peekX: CGFloat?
    @ObservationIgnored private var peekSamples: [(t: Double, x: CGFloat, y: CGFloat)] = []
    /// Курсор вылетел за левую кромку изнутри окна — зона появления продлевается за кромку
    @ObservationIgnored private var peekArmed = false

    private enum Peek {
        static let outside: CGFloat = 40      // зона за кромкой, если курсор пришёл не изнутри окна
        static let still = 0.03               // столько без движения — курсор остановился
        static let slow: CGFloat = 250        // pt/с — медленнее: курсор «прицеливается»
        static let braking: CGFloat = 0.45    // скорость упала ниже этой доли от пиковой — тормозит
        static let fastCross: CGFloat = 700   // pt/с — «резко» пересёк правый край панели
        static let slack: CGFloat = 30        // медленно ушёл вправо — прячем после этого запаса
    }

    /// Ширина зоны за левой кромкой — половина обычной ширины панели
    private var peekReach: CGFloat { max(lastSidebarWidth, Metrics.sidebarWidthRange.lowerBound) / 2 }

    /// Скорость на отрезке времени: (модуль, по горизонтали); nil — мало данных
    private func peekVelocity(_ t0: Double, _ t1: Double) -> (CGFloat, CGFloat)? {
        let s = peekSamples.filter { $0.t >= t0 && $0.t <= t1 }
        guard let a = s.first, let b = s.last, b.t - a.t > 0.006 else { return nil }
        let dt = CGFloat(b.t - a.t)
        return (hypot(b.x - a.x, b.y - a.y) / dt, (b.x - a.x) / dt)
    }

    /// Текущая скорость (последние 40 мс)
    private func peekSpeed() -> (CGFloat, CGFloat)? {
        let n = CACurrentMediaTime()
        return peekVelocity(n - 0.04, n + 0.001)
    }

    /// Курсор в зоне: собирается ли он здесь остановиться
    private func peekWillStop(x: CGFloat, zone: ClosedRange<CGFloat>) -> Bool {
        guard let (v, vx) = peekSpeed() else { return false }   // данных нет — решит таймер остановки
        if v < Peek.slow { return true }
        let n = CACurrentMediaTime()
        var peak: CGFloat = 0
        var t = n - 0.3
        while t < n - 0.03 { if let w = peekVelocity(t, t + 0.04) { peak = max(peak, w.0) }; t += 0.02 }
        guard v < peak * Peek.braking else { return false }     // летит почти на полной — мимо
        // Тормозит: где встанет при таком замедлении
        guard let prev = peekVelocity(n - 0.08, n - 0.04), prev.0 > v else { return true }
        let decel = (prev.0 - v) / 0.04
        let stopX = x + (vx < 0 ? -1 : 1) * v * v / (2 * decel)
        return zone.contains(stopX)
    }

    private func peekShow() {
        peekStillWork?.cancel(); peekStillWork = nil
        peekArmed = false
        if !sidebarPeek { sidebarPeek = true }
    }

    private func peekHide() {
        peekHideWork?.cancel(); peekHideWork = nil
        if folderPeek.folderID != nil || Self.popoverOpen { return }   // открыт попап папки или окошко — не прячем
        if sidebarPeek { sidebarPeek = false }
    }

    /// Наведение на полоску у кромки. Пока приложение активно, решает слежение за курсором;
    /// в неактивном окне событий движения нет — выезжаем сразу.
    func peekEntered() {
        peekHideWork?.cancel(); peekHideWork = nil
        guard !sidebarPeek, !sidebarVisible, !NSApp.isActive else { return }
        peekShow()
    }

    /// Курсор вне окна по вертикали — прячем с небольшой задержкой (вдруг вернётся)
    private func peekHideSoon() {
        guard sidebarPeek, peekHideWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.peekHideWork = nil; self?.peekHide() }
        peekHideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    /// Зона появления для текущего положения окна
    private func peekZone(_ f: NSRect) -> ClosedRange<CGFloat> {
        (f.minX - (peekArmed ? peekReach : Peek.outside))...(f.minX + Metrics.peekEdge)
    }

    private func peekMoved(_ e: NSEvent?) {
        // Капсула сверху — и при закреплённой панели (тогда над страницей, правее панели)
        if let win = mainWindow, win.isVisible, win.isKeyWindow || (NSApp.isActive && Self.current === self) {
            var f = win.frame
            if sidebarVisible { f.origin.x += Metrics.sidebarWidth; f.size.width -= Metrics.sidebarWidth }
            topBarMoved(NSEvent.mouseLocation, f)
        }
        // Выехавшая панель прячется, как только курсор ушёл от неё, — в каком бы окне ни был фокус
        // (раньше пряталась только в окне с фокусом: если он был у маленького окна, панели цвета, другого окна — висела)
        if sidebarPeek, !sidebarVisible, let win = mainWindow, win.isVisible, !win.isKeyWindow && !(NSApp.isActive && Self.current === self) {
            let p = NSEvent.mouseLocation, f = win.frame
            let inPanel = p.y > f.minY && p.y < f.maxY && p.x >= f.minX - peekReach && p.x <= f.minX + Metrics.sidebarWidth + Peek.slack
            if !inPanel { peekHideSoon() }
            return
        }
        // Окон несколько — выезжает панель только у того, в котором работают
        guard !sidebarVisible, let win = mainWindow, win.isVisible, win.isKeyWindow || (NSApp.isActive && Self.current === self) else { return }
        let p = NSEvent.mouseLocation, f = win.frame
        // Упёрся в левый край экрана — копим движение влево виртуально
        var x = p.x
        if let scr = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }),
           p.x <= scr.frame.minX + 0.5, let e {
            x = min(peekX ?? p.x, p.x) + min(e.deltaX, 0)
        }
        let prevX = peekX ?? x
        peekX = x
        let now = CACurrentMediaTime()
        peekSamples.append((now, x, p.y))
        peekSamples.removeAll { now - $0.t > 0.35 }
        let yIn = p.y > f.minY && p.y < f.maxY - 4

        if sidebarPeek {
            let edge = f.minX + Metrics.sidebarWidth
            if x < f.minX - peekReach { peekHide(); return }
            if prevX <= edge, x > edge, (peekSpeed()?.1 ?? 0) > Peek.fastCross { peekHide(); return }
            if x > edge + Peek.slack { peekHide(); return }
            if !yIn { peekHideSoon() } else { peekHideWork?.cancel(); peekHideWork = nil }
            return
        }

        if yIn, prevX > f.minX, x <= f.minX { peekArmed = true }
        if !yIn || x < f.minX - peekReach || x > f.minX + Metrics.peekEdge { peekArmed = false }

        peekStillWork?.cancel(); peekStillWork = nil
        let zone = peekZone(f)
        guard yIn, zone.contains(x) else { return }
        if peekWillStop(x: x, zone: zone) { peekShow(); return }
        // Событий движения больше нет — курсор остановился в зоне
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.peekStillWork = nil
            guard !self.sidebarVisible, !self.sidebarPeek, let win = self.mainWindow, let x = self.peekX else { return }
            let f = win.frame, y = NSEvent.mouseLocation.y
            guard y > f.minY, y < f.maxY - 4, self.peekZone(f).contains(x) else { return }
            self.peekShow()
        }
        peekStillWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Peek.still, execute: w)
    }

    @ObservationIgnored private var edgeMonitors: [Any] = []
    /// Окно закрыли — снять слежение за мышью и жестами
    func stopWatchers() {
        edgeMonitors.forEach { NSEvent.removeMonitor($0) }
        edgeMonitors = []
        swipe.stop()
    }

    func startEdgeWatcher() {
        guard edgeMonitors.isEmpty else { return }
        swipe.start(model: self)
        let kinds: NSEvent.EventTypeMask = [.mouseMoved]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] e in self?.peekMoved(e) }) { edgeMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] e in self?.peekMoved(e); return e }) { edgeMonitors.append(l) }
    }

    /// «Светофор» окна виден только вместе с боковой панелью.
    func updateWindowButtons() {
        DispatchQueue.main.async { self.applyWindowButtons() }
        // Система иногда заново включает слои рамки после перерисовки окна — повторяем чуть позже
        for d in [0.15, 0.5, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { self.applyWindowButtons() }
        }
        // …и после изменения размера, смены активного окна, выхода из полноэкранного режима
        if frameObservers.isEmpty {
            let nc = NotificationCenter.default
            for n in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didBecomeKeyNotification,
                      NSWindow.didResignKeyNotification, NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification] {
                frameObservers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                    self?.applyWindowButtons()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.applyWindowButtons() }
                })
            }
        }
    }
    @ObservationIgnored private var frameObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var overlayWatch: [NSKeyValueObservation] = []
    @ObservationIgnored private var overlayTimer: Timer?


    /// Прячет системную светлую обводку окна и следит, чтобы система не включила её снова.
    private func hideFrameOverlay(_ frame: NSView) {
        guard let frameLayer = frame.layer?.sublayers?.first(where: { $0.name == "CUIWindowFrameLayer" }) else { return }
        let overlays = frameLayer.sublayers?.filter { $0.name == "CUIWindowOverlayLayer" } ?? []
        for l in overlays where !l.isHidden { l.isHidden = true }
        // Показали снова — сразу прячем
        overlayWatch = overlays.map { l in
            l.observe(\.isHidden, options: [.new]) { layer, _ in
                if !layer.isHidden { DispatchQueue.main.async { layer.isHidden = true } }
            }
        }
        // Страховка: система может создать слой заново
        if overlayTimer == nil {
            overlayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak frame] _ in
                guard let self, let frame, frame.window?.isVisible == true,
                      let fl = frame.layer?.sublayers?.first(where: { $0.name == "CUIWindowFrameLayer" }) else { return }
                if fl.sublayers?.contains(where: { $0.name == "CUIWindowOverlayLayer" && !$0.isHidden }) == true {
                    self.hideFrameOverlay(frame)
                }
            }
        }
    }

    /// Системный светофор всегда скрыт — вместо него свой, внутри боковой панели.
    private func applyWindowButtons() {
        // Только главное окно браузера (не окно настроек)
        for w in NSApp.windows where w.standardWindowButton(.closeButton) != nil && w.title == "Sapfire" {
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(b)?.isHidden = true
            }
            w.isMovableByWindowBackground = false   // окно тащится только за явные зоны (WindowDragArea)
            // Для системы окно неподвижно: иначе полоса заголовка (с пустой панелью инструментов в macOS 26 — 66 pt)
            // тащит окно и за значки пространств в ней. Двигают окно свои зоны (WindowDragArea) и два пальца сверху
            w.isMovable = false
            // Пустая невидимая панель инструментов: с ней macOS даёт окну крупные углы (26 pt, как у Safari)
            if w.toolbar == nil {
                let t = NSToolbar(identifier: "sapfire.main")
                t.showsBaselineSeparator = false
                w.toolbar = t
                w.toolbarStyle = .unified
                w.titleVisibility = .hidden
                w.titlebarAppearsTransparent = true
            }
            // «Зоны под панелью инструментов» нет: иначе списки тянутся под неё и перекрывают кнопки вверху
            let bar = w.frame.height - w.contentLayoutRect.height
            if let cv = w.contentView, bar > 0, cv.additionalSafeAreaInsets.top != -bar {
                cv.additionalSafeAreaInsets = NSEdgeInsets(top: -bar, left: 0, bottom: 0, right: 0)
            }
            w.titlebarSeparatorStyle = .none
            // Перекрываем системную кромку-блик у верхней грани: прячем декоративные слои заголовка,
            // которые рисуются поверх содержимого окна
            if let frame = w.contentView?.superview {
                hideTitlebarDecorations(in: frame)
                // Полоса заголовка/панели инструментов целиком скрыта: иначе она перехватывает клики
                // в верхней части окна и отдаёт их странице (светофор и кнопки у нас свои)
                for sub in frame.subviews where String(describing: type(of: sub)) == "NSTitlebarContainerView" {
                    sub.isHidden = true
                }
                // Светлая кромка по краю окна: у системной рамки есть слой-«обводка» поверх — прячем его
                hideFrameOverlay(frame)
            }
        }
    }

    private func hideTitlebarDecorations(in v: NSView) {
        for sub in v.subviews {
            let name = String(describing: type(of: sub))
            if name == "_NSTitlebarDecorationView" || name == "NSTitlebarBackgroundView" {
                sub.isHidden = true
            } else if name.hasPrefix("NSTitlebar") {
                hideTitlebarDecorations(in: sub)
            }
        }
    }

    /// Окно браузера этой модели (у первого — пока не узнали — главное окно приложения)
    var mainWindow: NSWindow? {
        if let window { return window }
        guard isPrimary else { return nil }
        return NSApp.windows.first { w in
            w.title == "Sapfire" && !(w is LittleWindow) && w.standardWindowButton(.closeButton) != nil
                && !Self.windows.contains { $0 !== self && $0.window === w }
        }
    }

    /// Активная панель сплита (по порядку на экране); активная — это выбранная вкладка пространства
    var activePane: Int {
        get { currentSpace.paneTabs.firstIndex { $0.id == currentSpace.selectedTabID } ?? 0 }
        set { let p = currentSpace.paneTabs; if p.indices.contains(newValue), currentSpace.selectedTabID != p[newValue].id { currentSpace.selectedTabID = p[newValue].id } }
    }
    var commandBar: CommandTarget?
    /// Peek: страница карточкой поверх (ссылка из закреплённой вкладки)
    var peek: Tab?
    /// Тащат капсулу адреса панели сплита
    var paneDrag: PaneDrag?
    var commandText = ""
    var commandIndex = 0
    /// Уведомления справа сверху: что Sapfire сделал без явного показа (вкладка в фоне, копия, правило сайта…)
    var notices: [Notice] = []
    var adBlockEnabled: Bool = ContentBlocker.shared.enabled {
        didSet { ContentBlocker.shared.setEnabled(adBlockEnabled) }
    }

    /// Один делегат страниц на всё приложение
    static let delegate = WebDelegate()
    var delegate: WebDelegate { Self.delegate }
    private static var closedStack: [URL] = []
    private var closedStack: [URL] { get { Self.closedStack } set { Self.closedStack = newValue } }
    @ObservationIgnored private var timer: Timer?

    static let spaceIcons = ["person", "briefcase", "gamecontroller", "paintbrush", "cube", "book", "heart", "star", "leaf", "flame"]

    init(primary: Bool = false) {
        isPrimary = primary
        guard primary else { return }
        // Всё общее запускается один раз — с первым окном
        ContentBlocker.shared.compile()
        // Общественные списки фильтров: готовые — сразу, свежие — докачиваются в фоне
        FilterLists.shared.onChange = { ContentBlocker.shared.compileExceptions() }
        CosmeticFilter.shared.load()
        FilterLists.shared.start()
        SiteRules.shared.rebuild()
        load()
        if spaces.isEmpty {
            let s = Space(name: "Personal", icon: "person", hue: 0.58)
            spaces = [s]
            currentSpaceID = s.id
        }
        ThumbnailStore.shared.cleanup(keeping: Set(allTabs.map(\.id)))
        cleanupStores()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.sleepInactiveTabs()
            self?.autoArchive()
            DownloadStore.shared.prune()
            self?.save()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.autoArchive() }
        // Какое окно последним было активным (для меню и клавиш, пока ключевое — настройки или маленькое окно)
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            if let w = n.object as? NSWindow, let m = BrowserModel.windows.first(where: { $0.window === w }) { BrowserModel.lastActive = m }
        }
    }

    // MARK: Access

    var currentSpace: Space { spaces.first { $0.id == currentSpaceID } ?? spaces[0] }

    var activeTab: Tab? {
        let s = currentSpace
        return s.selectedTab
    }

    var allTabs: [Tab] { favorites + spaces.flatMap { $0.tabs } }
    func isFavorite(_ tab: Tab) -> Bool { favorites.contains { $0 === tab } }

    func tab(for webView: WKWebView) -> Tab? { allTabs.first { $0.webView === webView } }
    func space(of tab: Tab) -> Space? { spaces.first { sp in sp.tabs.contains { $0 === tab } } }

    func isVisible(_ tab: Tab) -> Bool {
        let s = currentSpace
        return tab.id == s.selectedTabID || s.inPanes(tab.id)
    }

    func isActive(_ tab: Tab) -> Bool { activeTab === tab }

    // MARK: Tabs

    /// Страница из маленького окна становится вкладкой — вместе со своей страницей, без перезагрузки
    func adopt(_ wv: WKWebView, title: String, in space: Space? = nil) {
        checkpoint("New Tab")
        let sp = space ?? (currentSpace.isIncognito ? (spaces.first { !$0.isIncognito } ?? currentSpace) : currentSpace)
        let t = Tab(url: wv.url, title: title)
        t.browser = self
        t.attach(wv)
        sp.tabs.insert(t, at: 0)
        select(t)
    }

    @discardableResult
    /// load — вкладку в фоне грузить сразу (название и значок в списке); false — для пачки вкладок разом
    func newTab(url: URL?, in space: Space? = nil, select: Bool = true, load: Bool = true,
                configuration: WKWebViewConfiguration? = nil, opener: Tab? = nil) -> Tab {
        checkpoint("New Tab")
        let sp = space ?? currentSpace
        if sp.isIncognito, let h = url?.host { FaviconStore.shared.markPrivate(h) }
        let t = Tab(url: url)
        t.browser = self
        if let configuration { t.ensureWebView(configuration: configuration) }
        if let o = opener, !o.isPinned, !isFavorite(o), sp.tabs.contains(where: { $0 === o }) {
            place(t, under: o, in: sp)
        } else {
            // Новая вкладка (⌘T) и ссылки из закреплённых — вверх списка
            sp.tabs.insert(t, at: 0)
        }
        // В фоне — сразу грузить (после того как вкладка встала в пространство: от него зависят входы),
        // иначе до первого показа в списке было бы только имя сайта вместо названия страницы
        if !select, load, configuration == nil, url != nil { t.ensureWebView() }
        if select {
            // Открылась на переднем плане в свёрнутой папке — раскрываем её, чтобы было видно, где ты
            var f = t.folderID.flatMap { fid in sp.folders.first { $0.id == fid } }
            while let cur = f {
                if !cur.expanded { ListMotion.animate { cur.expanded = true } }
                f = sp.parent(of: cur)
            }
            self.select(t)
        }
        Ext.opened(t)
        return t
    }

    /// Вкладка, открытая ссылкой из временной, встаёт под ней — после уже открытых оттуда же,
    /// в том же порядке (как в Chrome). Из сохранённой (папка, строка над разделителем) — наверх временных.
    private func place(_ t: Tab, under o: Tab, in sp: Space) {
        if o.folderID != nil || o.isSaved {
            sp.tabs.insert(t, at: 0)
            return
        }
        t.openerID = o.id
        t.folderID = o.folderID
        let list: [Tab] = {
            if let fid = o.folderID, let f = sp.folders.first(where: { $0.id == fid }) { return sp.tabs(in: f) }
            return sp.loose
        }()
        guard var k = list.firstIndex(where: { $0 === o }) else { sp.tabs.insert(t, at: 0); return }
        while k + 1 < list.count, list[k + 1].openerID == o.id { k += 1 }
        let anchor = list[k]
        // Порядок внутри папки — по массиву вкладок; порядок верхнего уровня — по layout
        let i = sp.tabs.firstIndex(where: { $0 === anchor }).map { $0 + 1 } ?? sp.tabs.count
        sp.tabs.insert(t, at: i)
        if o.folderID == nil {
            sp.layout = sp.entries.map(\.id).filter { $0 != t.id }
            if let j = sp.layout.firstIndex(of: anchor.id) { sp.layout.insert(t.id, at: j + 1) } else { sp.layout.insert(t.id, at: 0) }
        }
        sp.normalize()
    }

    /// Перенести папку со всеми вкладками в другое пространство
    func move(folder f: Folder, to dest: Space) {
        guard let from = spaces.first(where: { $0.folders.contains { $0 === f } }), from !== dest,
              from.isIncognito == dest.isIncognito else { return }
        checkpoint("Move Folder")
        let inner = from.descendants(of: f)
        let kids = from.allTabs(in: f)
        let reopen = from.dataStore !== dest.dataStore
        for t in kids { from.leavePanes(t.id) }
        if let sel = from.selectedTabID, kids.contains(where: { $0.id == sel }) {
            from.selectedTabID = from.tabs.first { t in !kids.contains { $0 === t } && !t.isPinned }?.id ?? from.ownPinned.first?.id
        }
        from.tabs.removeAll { t in kids.contains { $0 === t } }
        from.folders.removeAll { x in x === f || inner.contains { $0 === x } }
        from.layout.removeAll { $0 == f.id }
        f.parentID = nil
        dest.folders.append(f)
        dest.folders.append(contentsOf: inner)
        dest.tabs.append(contentsOf: kids)
        dest.layout.insert(f.id, at: 0)
        from.normalize(); dest.normalize()
        if reopen { kids.forEach { if $0.webView != nil { $0.sleep() } } }
        showToast("Folder moved to “\(dest.name)”")
    }

    func select(_ tab: Tab) {
        // Избранное и общие закреплённые открываются в текущем пространстве
        if peek != nil, peek !== tab { closePeek() }
        if MiniPlayer.shared.pausedID == tab.id { MiniPlayer.shared.pausedID = nil }
        let shared = currentSpace.pinned.contains { $0 === tab }
        guard let sp = shared ? currentSpace : (space(of: tab) ?? (isFavorite(tab) ? currentSpace : nil)) else { return }
        // Пространство вкладки открыто в другом окне — открываем там
        if let other = Self.window(showing: sp), other !== self {
            other.select(tab)
            other.mainWindow?.makeKeyAndOrderFront(nil)
            return
        }
        tab.hostID = id                      // страница показывается в этом окне
        let previous = activeTab
        if let cur = previous, cur !== tab { cur.capturePreview() }
        defer { if previous !== tab { Ext.activated(tab, previous: previous) } }
        if sp.id != currentSpaceID { currentSpaceID = sp.id }
        if sp.selectedTabID != tab.id {
            // Вкладка из того же сплита — просто другая панель активна; иначе на экране теперь она (или её сплит)
            if !sp.inPanes(tab.id) { for t in sp.paneTabs { t.lastActive = Date() } }
            sp.selectedTabID = tab.id
        }
        tab.lastActive = Date()
        focusWebView()
    }

    func focusWebView() {
        DispatchQueue.main.async {
            if let wv = self.activeTab?.webView { wv.window?.makeFirstResponder(wv) }
        }
    }

    func close(_ tab: Tab, auto: Bool = false, group: Folder? = nil) {
        if !auto { checkpoint("Close Tab") }
        if isFavorite(tab) { unload(favorite: tab); return }
        // Закреплённую ⌘W только закрывает: выгружается и возвращается на свой адрес, но остаётся закреплённой
        if tab.isPinned { unload(pinned: tab); return }
        guard let sp = space(of: tab), let idx = sp.tabs.firstIndex(where: { $0 === tab }) else { return }
        if let u = tab.url, !sp.isIncognito { closedStack.append(u) }       // из инкогнито — не запоминаем
        if !sp.isIncognito { ArchiveStore.shared.add(url: tab.url, title: tab.title, space: sp.name, auto: auto,
                                                          folder: group?.name, group: group?.id) }
        defer { sp.normalize() }     // веточки закрытой вкладки становятся обычными временными
        let wasSelected = sp.selectedTabID == tab.id
        Ext.closed(tab)
        sp.tabs.remove(at: idx)
        tab.sleep()
        if tab.temporary { tab.dropTempStore() }        // после выгрузки страницы: хранилище больше никому не нужно
        // Общий закреплённый мог быть открыт и в других пространствах
        for other in spaces where other !== sp {
            if !other.leavePanes(tab.id), other.selectedTabID == tab.id { other.selectedTabID = other.tabs.first?.id }
        }
        // Была в сплите — активной становится соседняя панель
        if !sp.leavePanes(tab.id), wasSelected {
            sp.selectedTabID = sp.tabs.isEmpty ? nil : sp.tabs[min(idx, sp.tabs.count - 1)].id
        }
        focusWebView()
    }

    /// «Закрыть» избранное — выгрузить его и убрать с экрана, но оставить в «Избранном».
    func unload(favorite tab: Tab) {
        for sp in spaces {
            if !sp.leavePanes(tab.id), sp.selectedTabID == tab.id { sp.selectedTabID = sp.tabs.first?.id }
        }
        tab.sleep()
        focusWebView()
    }

    /// Убрать закреплённую совсем (в архив, как обычную закрытую)
    func removePinned(_ tab: Tab) {
        checkpoint("Remove Pinned")
        tab.isPinned = false
        close(tab, auto: true)
    }

    /// «Закрыть» закреплённую — выгрузить, вернуть на адрес закрепления, убрать с экрана; в закреплённых остаётся
    func unload(pinned tab: Tab) {
        for sp in spaces where sp.selectedTabID == tab.id || sp.inPanes(tab.id) {
            if !sp.leavePanes(tab.id), sp.selectedTabID == tab.id { sp.selectedTabID = nearestAwake(to: tab, in: sp)?.id }
        }
        tab.sleep()
        tab.resetToPin()
        focusWebView()
    }

    func toggleFavorite(_ tab: Tab) {
        if isFavorite(tab) { moveTabs([tab.id], to: .list(0)) }
        else { moveTabs([tab.id], to: .favorites(favorites.count)) }
    }

    /// ⌘W: временная — закрывается в архив; сохранённая (в папке или над «Temp») — только выгружается
    /// и остаётся в списке спящей (удаляется крестиком); закреплённая — выгружается (см. close)
    func closeActiveTab() {
        // Пустое инкогнито — ⌘W закрывает его (и стирает всё)
        if activeTab == nil, currentSpace.isIncognito, currentSpace.tabs.isEmpty { closeIncognito(currentSpace); return }
        guard let t = activeTab else { return }
        if !t.isPinned, !isFavorite(t), !(space(of: t)?.isTemp(t) ?? true) { unload(saved: t) } else { close(t) }
    }

    /// «Закрыть» сохранённую вкладку — выгрузить (память освобождается) и убрать с экрана; в списке остаётся
    func unload(saved tab: Tab) {
        // Крестик строки закреплённой — как ⌘W: вернуть на адрес закрепления
        if tab.isPinned { unload(pinned: tab); return }
        for sp in spaces where sp.selectedTabID == tab.id || sp.inPanes(tab.id) {
            if !sp.leavePanes(tab.id), sp.selectedTabID == tab.id { sp.selectedTabID = nearestAwake(to: tab, in: sp)?.id }
        }
        tab.sleep()
        focusWebView()
    }

    /// Кого показать вместо закрытой (выгруженной) вкладки: ближайшую по списку открытую — ниже, а если ниже нет — выше
    /// (как в Arc). Закрытые (спящие) не будим; открытых нет — пустой экран
    func nearestAwake(to tab: Tab, in sp: Space) -> Tab? {
        let list = sp.pinned + sp.visual
        let i = list.firstIndex { $0 === tab } ?? 0
        let awake = list.enumerated().filter { $0.element !== tab && !$0.element.asleep }
        return (awake.first { $0.offset > i } ?? awake.last { $0.offset < i })?.element
    }

    /// ⌘⇧K — закрыть все незакреплённые вкладки пространства (папки не трогаем). Отменяется ⌘Z.
    func clearUnpinned() {
        let sp = currentSpace
        let loose = sp.unpinned.filter { $0.folderID == nil && !$0.isSaved && !$0.isBranch }
        let temps = sp.folders.filter { $0.parentID == nil && $0.isTemp }
        guard !loose.isEmpty || !temps.isEmpty else { showToast("No temporary tabs"); return }
        checkpoint("Clear Unpinned Tabs")
        let n = loose.count + temps.reduce(0) { $0 + sp.allTabs(in: $1).count }
        for t in loose { close(t, auto: true) }
        for f in temps { archive(folder: f, in: sp, auto: true) }
        showToast("Closed \(n) tab\(n == 1 ? "" : "s") — ⌘Z to undo")
    }

    /// Временную папку — в архив целиком: вкладки запоминают папку, из ⇧⌘A она возвращается папкой
    func archive(folder f: Folder, in sp: Space, auto: Bool) {
        let inner = sp.descendants(of: f)
        for t in sp.allTabs(in: f) { close(t, auto: auto, group: f) }
        sp.folders.removeAll { x in x === f || inner.contains { $0 === x } }
        sp.normalize()
    }

    /// Вернуть из архива временную папку целиком (все её вкладки) — наверх временных текущего пространства
    func restore(group: UUID) {
        let items = ArchiveStore.shared.entries.filter { $0.group == group }
        guard let first = items.first else { return }
        let sp = currentSpace
        checkpoint("Restore Folder")
        let f = Folder(name: first.folder ?? "Folder", hue: sp.colorless ? -1 : sp.hue)
        f.isTemp = true
        var made: [Tab] = []
        for e in items.reversed() {       // в архиве новые — сверху; возвращаем в прежнем порядке
            let t = Tab(url: e.url, title: e.title, isPinned: false)
            t.browser = self
            t.folderID = f.id
            t.asleep = true
            made.append(t)
            ArchiveStore.shared.remove(e)
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            sp.normalize()
            sp.folders.append(f)
            sp.tabs += made
            let at = sp.savedEntries.count
            sp.layout.insert(f.id, at: min(at, sp.layout.count))
            sp.normalize()
        }
        if let t = made.first { select(t) }
        showToast("Restored “\(f.name)”")
    }

    /// Закрыть в архив незакреплённые вкладки выше / ниже / кроме этой (папки не трогаем). Отменяется ⌘Z.
    enum CloseScope { case above, below, others }
    func closeTabs(_ scope: CloseScope, from tab: Tab) {
        guard let sp = space(of: tab) else { return }
        let loose = sp.unpinned.filter { $0.folderID == nil && !$0.isSaved && !$0.isBranch }
        guard let i = loose.firstIndex(where: { $0 === tab }) else { return }
        let victims: [Tab]
        switch scope {
        case .above: victims = Array(loose[..<i])
        case .below: victims = Array(loose[(i + 1)...])
        case .others: victims = loose.filter { $0 !== tab }
        }
        guard !victims.isEmpty else { return }
        checkpoint("Close Tabs")
        for t in victims { close(t, auto: true) }
        showToast("Closed \(victims.count) tab\(victims.count == 1 ? "" : "s") — ⌘Z to undo")
    }

    /// ⌥⌘I — инспектор страницы
    func showInspector() {
        guard let wv = activeTab?.webView else { return }
        let sel = NSSelectorFromString("_inspector")
        guard wv.responds(to: sel), let insp = wv.perform(sel)?.takeUnretainedValue() as? NSObject else { return }
        let show = NSSelectorFromString("show")
        if insp.responds(to: show) { insp.perform(show) }
    }

    /// ⌃⇧1…4 — фокус на панель сплита
    func focusPane(_ n: Int) {
        let sp = currentSpace
        guard n >= 1, n <= sp.paneTabs.count else { return }
        sp.selectedTabID = sp.paneTabs[n - 1].id
        focusWebView()
    }

    func reopenClosed() {
        guard let u = closedStack.popLast() else { return }
        newTab(url: u)
    }

    func togglePin(_ tab: Tab) {
        // Через общий механизм: у пространства с общими закреплёнными они живут у «хозяина»
        moveTabs([tab.id], to: tab.isPinned ? .list(0) : .pinned(currentSpace.pinned.count))
    }

    /// Открыть вкладку ещё одной панелью справа (до четырёх). Все четыре заняты — заменяет активную
    /// (или ту, что указана в `replacing`).
    func openInSplit(_ tab: Tab, replacing: Int? = nil) {
        let sp = currentSpace
        guard let sel = sp.selectedTab, sel !== tab else { return }
        guard sp.tabs.contains(where: { $0 === tab }) || sp.pinned.contains(where: { $0 === tab }) else { return }
        checkpoint("Split")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            var g = sp.group(of: sel.id) ?? [sel.id]
            if !g.contains(tab.id) {
                if let r = replacing ?? (g.count >= Space.maxPanes ? g.firstIndex(of: sel.id) : nil), r < g.count { g[r] = tab.id }
                else { g.append(tab.id) }
                sp.makeGroup(g)
            }
            sp.selectedTabID = tab.id
        }
        focusWebView()
    }

    /// Перетащил вкладки на вкладку в панели — сплит из них (до четырёх); если та уже в сплите — добавить туда
    func split(_ ids: [UUID], with target: Tab) {
        let sp = currentSpace
        let all = allTabs
        let add = ids.filter { id in id != target.id && all.contains { $0.id == id } }
        guard !add.isEmpty else { return }
        checkpoint("Split")
        // Вкладки из другого пространства сначала переезжают сюда
        for id in add { if let t = allTabs.first(where: { $0.id == id }), space(of: t) !== sp, !isFavorite(t) { move(t, to: sp) } }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            sp.makeGroup((sp.group(of: target.id) ?? [target.id]) + add)
            sp.selectedTabID = target.id
        }
        focusWebView()
    }

    /// Разделить сплит: вкладки остаются в списке по отдельности, на экране — активная
    func closeSplit() {
        let sp = currentSpace
        guard let g = sp.group(of: sp.selectedTabID) else { return }
        unsplit(g)
    }

    func unsplit(_ g: [UUID]) {
        let sp = currentSpace
        checkpoint("Separate Tabs")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            sp.splitGroups.removeAll { $0 == g }
            for id in g { sp.splitArrange[id] = nil; sp.splitSizes[id] = nil }
        }
    }

    /// Убрать из сплита одну панель (вкладка остаётся в списке)
    func closePane(_ i: Int) {
        let sp = currentSpace
        let panes = sp.paneTabs
        guard panes.count > 1, i < panes.count else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { sp.leavePanes(panes[i].id) }
        focusWebView()
    }

    func move(_ tab: Tab, to target: Space) {
        if isFavorite(tab) {
            // Из «Избранного» в пространство: в остальных пространствах она больше не открыта
            favorites.removeAll { $0 === tab }
            for sp in spaces where sp !== target {
                if !sp.leavePanes(tab.id), sp.selectedTabID == tab.id { sp.selectedTabID = sp.tabs.first?.id }
            }
            target.tabs.insert(tab, at: 0)
            return
        }
        guard let from = space(of: tab), from.id != target.id else { return }
        guard from.isIncognito == target.isIncognito else { return }   // входы инкогнито не смешиваем
        // У пространств разные входы — страница откроется заново уже с входами нового пространства
        let reopen = from.dataStore !== target.dataStore && tab.webView != nil
        defer { if reopen { tab.sleep() } }
        tab.folderID = nil
        // Переносим вкладку как есть — без выгрузки страницы (это и тормозило перенос)
        let idx = from.tabs.firstIndex { $0 === tab } ?? 0
        from.tabs.removeAll { $0 === tab }
        if !from.leavePanes(tab.id), from.selectedTabID == tab.id {
            from.selectedTabID = from.tabs.isEmpty ? nil : from.tabs[min(idx, from.tabs.count - 1)].id
        }
        target.tabs.insert(tab, at: 0)
    }

    /// ⌘1…9 — закреплённые сайты по порядку (⌘9 — последний): цифра всегда ведёт на один и тот же сайт
    func selectTab(number n: Int) {
        let list = currentSpace.pinned
        guard !list.isEmpty else { return }
        let i = n == 9 ? list.count - 1 : n - 1
        if i < list.count { select(list[i]) }
    }

    /// Следующая/предыдущая вкладка — только среди открытых (загруженных); спящие закреплённые и папки пропускаются
    func cycleTab(_ delta: Int) {
        let list = currentSpace.ordered.filter { $0.webView != nil || $0 === activeTab }
        guard !list.isEmpty else { return }
        let cur = list.firstIndex { $0 === activeTab } ?? 0
        select(list[(cur + delta + list.count) % list.count])
    }

    /// ⌥⌘R — режим чтения на открытой вкладке
    func toggleReader() { Reader.toggle(activeTab) }

    /// ⌘+ / ⌘− / ⌘0 — масштаб запоминается для сайта
    func zoom(_ delta: Double) {
        guard let t = activeTab, let wv = t.webView else { return }
        // ⌘0 — ещё и увеличение щипком обратно на 100%, страница снова ровно по центру окна
        if delta == 0, wv.magnification != 1 {
            wv.setMagnification(1, centeredAt: CGPoint(x: wv.bounds.midX, y: wv.bounds.midY))
        }
        let z = delta == 0 ? 1 : max(0.3, min(3, ((wv.pageZoom + delta) * 10).rounded() / 10))
        wv.pageZoom = z
        SiteSettings.shared.update(t.url, incognito: t.isIncognito) { $0.zoom = z }
    }

    func copyURL() {
        guard let u = activeTab?.url?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u, forType: .string)
        showToast("Link copied")
    }

    // MARK: Spaces

    func switchSpace(_ i: Int) {
        guard spaces.indices.contains(i) else { return }
        // Пространство открыто в другом окне — переходим туда
        if focusOwner(of: spaces[i]) { return }
        currentSpaceID = spaces[i].id
        focusWebView()
    }

    func addSpace() {
        checkpoint("New Space")
        let n = spaces.count
        let s = Space(name: "Space \(n + 1)",
                      icon: Self.spaceIcons[n % Self.spaceIcons.count],
                      hue: (0.58 + Double(n) * 0.17).truncatingRemainder(dividingBy: 1))
        spaces.append(s)
        currentSpaceID = s.id
    }

    func renameTab(_ tab: Tab) {
        guard let name = promptText("Tab name", initial: tab.displayTitle) else { return }
        checkpoint("Rename Tab")
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = n.isEmpty || n == tab.title ? nil : n
        save()
    }

    func rename(_ space: Space) {
        if let name = promptText("Space name", initial: space.name), !name.isEmpty {
            checkpoint("Rename Space")
            space.name = name
        }
    }

    /// Копия закреплённого сайта (новая вкладка с тем же адресом).
    func copyPinned(_ t: Tab) -> Tab {
        let c = Tab(url: t.pinnedURL ?? t.url, title: t.title, isPinned: true)
        c.pinnedURL = t.pinnedURL ?? t.url
        c.customTitle = t.customTitle
        c.browser = self
        return c
    }

    /// Взять закреплённые сайты у другого пространства (или вернуть свои: `from == nil`).
    func sharePinned(_ sp: Space, from source: Space?) {
        checkpoint("Pinned Sites")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if let source {
                let owner = source.pinOwner                    // без цепочек: берём у «хозяина»
                guard owner !== sp else { return }
                // Свои закреплённые не пропадают — становятся обычными вкладками
                for t in sp.ownPinned { t.isPinned = false }
                sp.pinnedFrom = owner.id
                // Кто брал закреплённые у этого пространства — теперь берут у нового хозяина
                for s in spaces where s.pinnedFrom == sp.id { s.pinnedFrom = owner.id }
                showToast("Pinned sites shared with “\(owner.name)”")
            } else if sp.pinnedFrom != nil {
                // Отключили общий набор — оставляем себе копию, чтобы не начинать с нуля
                let copies = sp.pinned.map { copyPinned($0) }
                sp.pinnedFrom = nil
                sp.tabs.insert(contentsOf: copies, at: 0)
                showToast("“\(sp.name)” has its own pinned sites")
            }
            sp.normalize()
        }
    }

    /// Пока поверх страницы висит выезжающая панель, попап папки или обзор — страница не реагирует на мышь
    /// (иначе под панелью подсвечиваются кнопки сайта и всплывают его подсказки).
    func updatePageMouse() {
        let covered = sidebarPeek || folderPeek.folderID != nil || overview.visible || peek != nil
        let js = covered
            ? "(function(){var s=document.getElementById('sf-mute');if(!s){s=document.createElement('style');s.id='sf-mute';(document.head||document.documentElement).appendChild(s);}s.textContent='html,html *{pointer-events:none!important}';})()"
            : "(function(){var s=document.getElementById('sf-mute');if(s)s.remove();})()"
        let unmute = "(function(){var s=document.getElementById('sf-mute');if(s)s.remove();})()"
        let shown = currentSpace.paneTabs
        for t in allTabs where t.webView != nil {
            // Приглушаем только видимые страницы; у остальных — снимаем, если осталось с прошлого раза
            t.webView?.evaluateJavaScript(covered && shown.contains { $0 === t } ? js : unmute)
        }
        pageMouseMuted = covered
    }
    @ObservationIgnored var pageMouseMuted = false
    /// Последний известный цвет страницы (пока у новой вкладки его нет)
    var lastPageColor: NSColor?

    /// ⌥Tab: следующее пространство по кругу (⌥⇧Tab — предыдущее).
    /// Пространства по свежести (первое — текущее) — для быстрого ⌥Tab
    @ObservationIgnored var spaceMRU: [UUID] = []
    /// Идёт ⌥Tab (⌥ ещё зажат): порядок свежести не трогаем до отпускания
    @ObservationIgnored var spaceTabbing = false

    func touchSpaceMRU() {
        spaceMRU.removeAll { $0 == currentSpaceID }
        spaceMRU.insert(currentSpaceID, at: 0)
        if spaceMRU.count > 32 { spaceMRU.removeLast(spaceMRU.count - 32) }
    }

    /// ⌥Tab: первое нажатие — в предыдущее пространство (два последних меняются местами);
    /// дальше, пока ⌥ зажат (или Tab держат), — по кругу
    func spaceTab(_ d: Int) {
        if spaceTabbing { cycleSpace(d); return }
        spaceTabbing = true
        let open = spaceMRU.dropFirst().first { id in
            guard let s = spaces.first(where: { $0.id == id }) else { return false }
            return Self.window(showing: s).map { $0 !== self } != true
        }
        guard let id = open, let j = spaces.firstIndex(where: { $0.id == id }),
              let i = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { cycleSpace(d); return }
        swipe.switchTo(j, model: self, direction: j > i ? 1 : -1)
        showToast(spaces[j].name)
    }

    /// Отпустил ⌥ — выбранное пространство становится последним
    func endSpaceTab() {
        guard spaceTabbing else { return }
        spaceTabbing = false
        touchSpaceMRU()
    }

    func cycleSpace(_ d: Int) {
        guard spaces.count > 1, let i = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        // По кругу, пропуская пространства, открытые в других окнах
        var j = i
        repeat { j = (j + d + spaces.count) % spaces.count } while j != i && Self.window(showing: spaces[j]).map { $0 !== self } == true
        guard j != i else { return }
        swipe.switchTo(j, model: self, direction: d)   // по кругу — всегда въезжает с нужной стороны
        showToast(spaces[j].name)
    }

    /// ⇧⌘N — инкогнито-пространство (одно; если уже есть — переходим в него).
    func openIncognito() {
        _ = incognitoSpace()
        showCommandBar(.newTab)
    }

    /// Пространство инкогнито (создаётся, если его нет) — на экран
    @discardableResult
    func incognitoSpace() -> Space {
        let (s, fresh) = findOrMakeIncognito()
        if let i = spaces.firstIndex(where: { $0 === s }) { swipe.switchTo(i, model: self) }
        if fresh { Incognito.opened(self) }
        return s
    }

    /// Найти инкогнито или создать (без перехода туда)
    private func findOrMakeIncognito() -> (Space, Bool) {
        if let s = spaces.first(where: { $0.isIncognito }) { return (s, false) }
        checkpoint("Incognito")
        let s = Space(name: "Incognito", icon: "eye.slash", hue: -1)
        s.isIncognito = true
        spaces.append(s)
        return (s, true)
    }

    /// «Open in Incognito»: те же адреса — новыми вкладками инкогнито (без входов и куки обычных пространств).
    /// Перенести саму вкладку нельзя: смешались бы входы, а история инкогнито ушла бы на диск.
    func openInIncognito(_ tabs: [Tab]) {
        let urls = tabs.compactMap(\.url).filter { ["http", "https"].contains($0.scheme ?? "") }
        guard !urls.isEmpty else { return }
        // Сначала вкладки — потом переход: иначе список инкогнито рисуется пустым в момент перехода
        // и добавленную следом вкладку не замечает
        let (sp, fresh) = findOrMakeIncognito()
        let made = urls.reversed().map { newTab(url: $0, in: sp, select: false, load: false) }     // пачкой — не грузить все разом
        if let i = spaces.firstIndex(where: { $0 === sp }) { swipe.switchTo(i, model: self) }
        if let first = made.last { select(first) }
        if fresh { Incognito.opened(self) }
        selection.clear()
    }

    /// Закрыть инкогнито: вкладки выгружаются, хранилище стирается.
    func closeIncognito(_ space: Space) {
        space.tabs.forEach { $0.sleep() }
        if currentSpaceID == space.id, let i = spaces.firstIndex(where: { !$0.isIncognito }) {
            swipe.switchTo(i, model: self)
        }
        spaces.removeAll { $0 === space }
        Self.fixWindows()
        BrowserModel.incognitoStore = nil
        Incognito.erase()
        IncognitoLock.shared.reset()
        showToast("Incognito closed — everything erased")
    }

    func delete(_ space: Space) {
        if space.isIncognito { closeIncognito(space); return }
        guard spaces.count > 1 else { return }
        let a = NSAlert()
        a.messageText = "Delete “\(space.name)”?"
        a.informativeText = "All tabs in this space will be closed."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        checkpoint("Delete Space")
        // Кто брал закреплённые у удаляемого — получают их копию
        for s in spaces where s.pinnedFrom == space.id {
            s.pinnedFrom = nil
            s.tabs.insert(contentsOf: space.ownPinned.map { copyPinned($0) }, at: 0)
            s.normalize()
        }
        space.tabs.forEach { $0.sleep() }
        spaces.removeAll { $0.id == space.id }
        if currentSpaceID == space.id { currentSpaceID = (spaces.first { Self.window(showing: $0) == nil } ?? spaces[0]).id }
        Self.fixWindows()
    }

    // MARK: Command bar

    func showCommandBar(_ target: CommandTarget) {
        commandText = target == .current ? (activeTab?.url?.absoluteString ?? "") : ""
        commandIndex = 0
        SearchSuggest.shared.reset()
        commandBar = target
    }

    func hideCommandBar() {
        commandBar = nil
        focusWebView()
    }

    var suggestions: [Suggestion] {
        let text = commandText.trimmingCharacters(in: .whitespaces)
        if commandBar == .history {
            return HistoryStore.shared.search(text, limit: 60).map { .history($0) }
        }
        if commandBar == .archive {
            return ArchiveStore.shared.search(text, limit: 100).map { .archived($0) }
        }
        if commandBar == .downloads {
            let q = text.lowercased()
            return DownloadStore.shared.items
                .filter { q.isEmpty || $0.file.lastPathComponent.lowercased().contains(q) }
                .map { .download($0) }
        }
        if text.isEmpty {
            return currentSpace.unpinned.prefix(6).map { Suggestion.tab($0) }
        }
        // Подсказки !-команд, пока набирается сама команда
        if text.hasPrefix("!"), !text.contains(" ") {
            let key = text.dropFirst().lowercased()
            let hits = Omnibox.bangs.filter { $0.key.hasPrefix(key) || $0.name.lowercased().hasPrefix(key) }
            var result: [Suggestion] = hits.prefix(8).map { Suggestion.bang($0) }
            if let exact = Omnibox.bangs.first(where: { $0.key == key }), let u = exact.url(query: "") {
                result.insert(.go(label: "Open \(exact.name)", url: u), at: 0)
            }
            return result
        }
        var result: [Suggestion] = []
        // Действия, подходящие под набранное (2+ буквы): если набрано точно действие — оно первым
        let acts = CommandAction.matching(text, model: self)
        if let first = acts.first, first.strong { result.append(.action(first)) }
        let incognito = currentSpace.isIncognito
        Tips.typed(text, self)
        if let u = Omnibox.url(for: text, incognito: incognito) {
            result.append(.go(label: Omnibox.label(for: text, incognito: incognito), url: u))
        }
        result += acts.filter { !$0.strong || $0.title != acts.first?.title }.prefix(3).map { .action($0) }
        // Открытые вкладки, потом подсказки поисковика, потом история (как в Arc)
        let q = text.lowercased()
        let tabs = allTabs.filter {
            $0.title.lowercased().contains(q) || ($0.url?.absoluteString.lowercased().contains(q) ?? false)
        }
        result += tabs.prefix(4).map { Suggestion.tab($0) }
        let sugg = SearchSuggest.shared
        // Пока новые подсказки не пришли, показываем прошлые (печатаешь дальше или стираешь) — список не мигает
        let sq = sugg.query.lowercased()
        if !sq.isEmpty, q.hasPrefix(sq) || sq.hasPrefix(q) {
            result += sugg.items.prefix(4).compactMap { s in
                Omnibox.url(for: s, incognito: incognito).map { Suggestion.search(s, $0) }
            }
        }
        let open = Set(tabs.compactMap { $0.url?.absoluteString })
        if !currentSpace.isIncognito {
            result += HistoryStore.shared.search(text, limit: 8)
                .filter { !open.contains($0.id) }
                .prefix(4).map { Suggestion.history($0) }
        }
        return result
    }

    func moveCommandSelection(_ d: Int) {
        let n = suggestions.count
        guard n > 0 else { return }
        commandIndex = max(0, min(n - 1, commandIndex + d))
    }

    func autocompleteBang() {
        let items = suggestions
        guard items.indices.contains(commandIndex), case .bang(let b) = items[commandIndex] else { return }
        commandText = "!\(b.key) "
    }

    func runCommand() {
        guard let target = commandBar else { return }
        let items = suggestions
        guard items.indices.contains(commandIndex) else { return }
        switch items[commandIndex] {
        case .bang(let b):
            commandText = "!\(b.key) "
            commandIndex = 0
            return
        case .tab(let t):
            commandBar = nil
            if target == .split, space(of: t)?.id == currentSpaceID, t.id != currentSpace.selectedTabID {
                openInSplit(t)
            } else {
                select(t)
            }
        case .go(_, let url), .search(_, let url):
            commandBar = nil
            open(url, target: target)
        case .history(let e):
            commandBar = nil
            open(e.url, target: target == .history ? .newTab : target)
        case .download(let d):
            commandBar = nil
            NSWorkspace.shared.activateFileViewerSelecting([d.file])
        case .archived(let e):
            commandBar = nil
            if let g = e.group { restore(group: g); return }
            ArchiveStore.shared.remove(e)
            open(e.url, target: target == .archive ? .newTab : target)
        case .action(let a):
            hideCommandBar()
            DispatchQueue.main.async { a.run() }
        }
    }

    func open(_ url: URL, target: CommandTarget) {
        switch target {
        case .current:
            if let t = activeTab { t.load(url); focusWebView() } else { newTab(url: url) }
        case .newTab:
            newTab(url: url)
        case .split:
            let sp = currentSpace
            let t = newTab(url: url, select: false)
            if sp.selectedTab == nil { select(t) } else { openInSplit(t) }
        case .history, .downloads, .archive:
            newTab(url: url)
        }
    }

    // MARK: Toast

    func showToast(_ text: String) { notify(text) }

    /// Уведомление справа сверху; с действием (кнопка «Show», «Undo»…) держится дольше. Не больше трёх сразу
    @discardableResult
    func notify(_ text: String, icon: String? = nil, action: String? = nil, _ run: (() -> Void)? = nil) -> Notice {
        // То же самое подряд — не плодить
        if let last = notices.last, last.text == text { notices.removeLast() }
        let n = Notice(text: text, icon: icon, action: action, run: run)
        notices.append(n)
        if notices.count > Notice.maxShown { notices.removeFirst(notices.count - Notice.maxShown) }
        scheduleDismiss(n)
        return n
    }

    func scheduleDismiss(_ n: Notice, after delay: TimeInterval? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? (n.action == nil ? Notice.life : Notice.lifeWithAction))) { [weak self] in
            guard let self, let i = self.notices.firstIndex(where: { $0.id == n.id }) else { return }
            // Под курсором — подождать и проверить снова (уже скоро, а не через весь срок)
            if self.notices[i].hovered { self.scheduleDismiss(n, after: 1); return }
            self.notices.remove(at: i)
        }
    }

    func dismiss(_ n: Notice) { notices.removeAll { $0.id == n.id } }

    /// Вкладку открыли в фоне — сказать и дать перейти к ней
    func openedInBackground(_ t: Tab) {
        let name = t.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "New tab"
        notify("Opened in background: \(name)", icon: "square.stack", action: "Show") { [weak self, weak t] in
            if let t { self?.select(t) }
        }
    }

    // MARK: Auto-archive

    /// Через сколько незакреплённая вкладка уходит в архив (0 — никогда). Settings → Tabs.
    static var archiveAfter: TimeInterval {
        UserDefaults.standard.object(forKey: Prefs.archiveAfter) as? Double ?? 24 * 3600
    }

    /// С какого момента считаем: при первом запуске с авто-архивом старые вкладки не пропадут разом
    private static let archiveSince: Date = {
        let d = UserDefaults.standard
        if let t = d.object(forKey: "archiveSince") as? Double { return Date(timeIntervalSince1970: t) }
        let now = Date()
        d.set(now.timeIntervalSince1970, forKey: "archiveSince")
        return now
    }()

    /// Уходят в архив: временные вкладки и веточки (если их вкладка не просит оставить)
    static func archivable(_ t: Tab, in sp: Space) -> Bool {
        if sp.isIncognito || t.isPinned { return false }
        if t.isBranch { return sp.tabs.first(where: { $0.id == t.openerID })?.keepBranches != true }
        return t.folderID == nil && !t.isSaved
    }

    /// Сколько секунд временной папке осталось до архива (nil — не уйдёт): отсчёт от последней вкладки, которую трогали
    static func archiveLeft(folder f: Folder, in sp: Space, now: Date = Date()) -> TimeInterval? {
        let limit = archiveAfter
        guard limit > 0, f.isTemp, f.parentID == nil, !sp.isIncognito else { return nil }
        let tabs = sp.allTabs(in: f)
        if tabs.contains(where: { sp.inPanes($0.id) || visibleAnywhere($0) || $0.audible }) { return nil }
        if ActiveClock.enabled {
            return limit - (ActiveClock.shared.now - tabs.map(\.activeMark).reduce(f.touchedMark, max))
        }
        let last = tabs.map(\.lastActive).reduce(max(f.touched, archiveSince), max)
        return limit - now.timeIntervalSince(last)
    }

    /// Сколько вкладка простояла без дела: по часам присутствия или просто по календарю
    static func idleTime(_ t: Tab, now: Date = Date()) -> TimeInterval {
        ActiveClock.enabled ? ActiveClock.shared.now - t.activeMark : now.timeIntervalSince(max(t.lastActive, archiveSince))
    }

    /// Сколько секунд вкладке осталось до архива (nil — не уйдёт)
    static func archiveLeft(_ t: Tab, in sp: Space, now: Date = Date()) -> TimeInterval? {
        let limit = archiveAfter
        guard limit > 0, archivable(t, in: sp), !sp.inPanes(t.id), !visibleAnywhere(t) else { return nil }
        return limit - idleTime(t, now: now)
    }

    /// Незакреплённые вкладки вне папок, которых давно не открывали, закрываются в архив (⇧⌘A).
    /// Не трогаем: видимые, выбранные в своём пространстве, играющие звук, инкогнито.
    func autoArchive() {
        let limit = Self.archiveAfter
        guard limit > 0 else { return }
        let now = Date()
        for sp in spaces where !sp.isIncognito {
            // Временные папки — целиком
            for f in sp.folders where f.isTemp && f.parentID == nil {
                if let left = Self.archiveLeft(folder: f, in: sp, now: now), left < 0 { archive(folder: f, in: sp, auto: true) }
            }
            for t in sp.unpinned where !sp.inPanes(t.id) && !Self.visibleAnywhere(t) {
                guard Self.archivable(t, in: sp) else { continue }
                guard Self.idleTime(t, now: now) > limit else { continue }
                if let wv = t.webView {
                    wv.requestMediaPlaybackState { [weak self] state in
                        if state != .playing { self?.close(t, auto: true); if let self { Tips.show(.archive, self) } }
                    }
                } else {
                    close(t, auto: true)
                    Tips.show(.archive, self)
                }
            }
        }
    }

    // MARK: Sleeping tabs

    /// Через сколько фоновая вкладка засыпает: Settings → Tabs → Memory (Prefs.sleepAfterMinutes, по умолчанию 10 минут;
    /// 0 — никогда). perfSleepMinutes в UserDefaults — для замеров, важнее настройки
    static var sleepAfter: TimeInterval? {
        let d = UserDefaults.standard
        let perf = d.double(forKey: "perfSleepMinutes")
        if perf > 0 { return perf * 60 }
        let m = d.object(forKey: Prefs.sleepAfterMinutes) == nil ? 10 : d.double(forKey: Prefs.sleepAfterMinutes)
        return m > 0 ? m * 60 : nil
    }

    func sleepInactiveTabs() {
        let after = Self.sleepAfter
        for t in allTabs where !t.asleep {
            if Self.visibleAnywhere(t) || t.autoReload != nil { t.lastActive = Date(); continue }
            guard let after, Date().timeIntervalSince(t.lastActive) > after, let wv = t.webView else { continue }
            wv.requestMediaPlaybackState { state in
                guard state != .playing else { return }
                t.sleep()
                if !Tab.pinnedRemember { t.resetToPin() }
            }
        }
    }

    // MARK: Web configuration

    static let safariVersion: String = {
        let info = Bundle(path: "/Applications/Safari.app")?.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "18.0"
    }()

    /// Одно «одноразовое» хранилище на инкогнито-сеанс: всё только в памяти
    static var incognitoStore: WKWebsiteDataStore?
    /// Страница инкогнито (её хранилище — общее хранилище инкогнито; одноразовые контейнеры — нет)
    static func isIncognito(_ wv: WKWebView) -> Bool { incognitoStore != nil && wv.configuration.websiteDataStore === incognitoStore }
    /// Хранилища, у которых уже есть страницы. Движок «замораживает» прокси хранилища при первой загрузке:
    /// у работавшего хранилища дорогу уже не сменить (инкогнито — пересоздаём, профиль — после перезапуска)
    static var usedStores = Set<ObjectIdentifier>()

    /// Отдельные хранилища входов пространств — по одному на пространство, живут всё время работы
    private static var stores: [UUID: WKWebsiteDataStore] = [:]
    static func store(for id: UUID) -> WKWebsiteDataStore {
        if let s = stores[id] { return s }
        let s = WKWebsiteDataStore(forIdentifier: id)
        WebEngine.applyCookies(to: s)
        stores[id] = s
        Tunnel.apply(s)                  // профиль через туннель — сразу, до первой загрузки
        return s
    }
    /// Чьё это хранилище (профиль); инкогнито — nil
    static func profileID(of store: WKWebsiteDataStore) -> UUID? {
        if store === WKWebsiteDataStore.default() { return Profile.primaryID }
        return stores.first { $0.value === store }?.key
    }

    /// Все хранилища, что сейчас в ходу (основное, профилей, инкогнито)
    static var allStores: [WKWebsiteDataStore] {
        [.default()] + Array(stores.values) + (incognitoStore.map { [$0] } ?? [])
    }
    static func newIncognitoStore() -> WKWebsiteDataStore {
        let s = WKWebsiteDataStore.nonPersistent()
        WebEngine.applyCookies(to: s)
        Incognito.apply(to: s)          // через прокси (Happ), если включено
        return s
    }

    /// Хранилища удалённых профилей стираем при запуске (не сразу — удаление можно отменить)
    func cleanupStores() {
        // Общий ящик VPN (Settings → Websites → Through VPN) — не профиль из списка, но его входы хранятся
        var keep = Set(profiles.filter { !$0.isPrimary }.map(\.id))
        keep.insert(Profile.vpnID)
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { ids in
            for id in ids where !keep.contains(id) {
                WKWebsiteDataStore.remove(forIdentifier: id) { _ in }
            }
        }
    }

    /// Сменить профиль пространства: открытые страницы перезагрузятся со входами нового профиля
    func setProfile(_ space: Space, _ p: Profile) {
        guard !space.isIncognito, space.profileID != p.id else { return }
        // Общие закреплённые берутся только у пространств того же профиля
        if space.pinnedFrom != nil, space.pinOwner.profileID != p.id { sharePinned(space, from: nil) }
        for other in spaces where other.pinnedFrom == space.id && other.profileID != p.id { sharePinned(other, from: nil) }
        space.profileID = p.id
        for t in space.tabs where t.webView != nil {
            let visible = isVisible(t)
            t.sleep()
            if visible { t.ensureWebView() }
        }
        save()
        showToast("“\(space.name)” — profile “\(p.name)”")
    }

    /// Новый профиль; если указано пространство — сразу ему
    @discardableResult
    func newProfile(for space: Space? = nil) -> Profile? {
        guard let name = promptText("Profile name", initial: ""), !name.isEmpty else { return nil }
        let p = Profile(name: name, hue: Profile.hues[(profiles.count - 1) % Profile.hues.count])
        profiles.append(p)
        if let space { setProfile(space, p) } else { save() }
        return p
    }

    func renameProfile(_ p: Profile) {
        if let name = promptText("Profile name", initial: p.name), !name.isEmpty { p.name = name; save() }
    }

    /// Удалить профиль: его пространства переходят к «Primary», входы профиля сотрутся при следующем запуске
    func deleteProfile(_ p: Profile) {
        guard !p.isPrimary else { return }
        let a = NSAlert()
        a.messageText = "Delete profile “\(p.name)”?"
        a.informativeText = "Its spaces move to “\(primaryProfile.name)”. Sign-ins of this profile will be erased."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for s in spaces where s.profileID == p.id { setProfile(s, primaryProfile) }
        profiles.removeAll { $0 === p }
        // Правила «всегда открывать как этот профиль» и вкладки, открытые им, — больше не его
        Self.profileRules = Self.profileRules.filter { $0.value != p.id }
        for t in allTabs where t.profileOverride == p.id {
            t.profileOverride = nil
            if t.webView != nil {
                let visible = Self.visibleAnywhere(t)
                t.sleep()
                if visible { t.ensureWebView() }
            }
        }
        save()
    }

    static func makeConfiguration(incognito: Bool = false) -> WKWebViewConfiguration {
        if incognito {
            if incognitoStore == nil { incognitoStore = newIncognitoStore() }
            return makeConfiguration(store: incognitoStore!)
        }
        return makeConfiguration(store: .default())
    }

    static func makeConfiguration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        usedStores.insert(ObjectIdentifier(store))
        let c = WKWebViewConfiguration()
        c.websiteDataStore = store
        c.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
        // Общие: поменял в Settings — действует сразу на всех страницах. У инкогнито и профилей через туннель —
        // свои (без предзагрузки DNS: она шла бы мимо прокси)
        let tunnelled = store.isPersistent && profileID(of: store).map(Tunnel.isOn) == true
        c.preferences = !store.isPersistent ? Incognito.preferences : tunnelled ? Incognito.tunnelPreferences : WebEngine.preferences
        c.mediaTypesRequiringUserActionForPlayback = []
        // Perf.off — выключатели надстроек для замеров (Perf.swift)
        if !Perf.off("blocker") { ContentBlocker.shared.apply(to: c.userContentController) }
        if !Perf.off("focus") { EditingFocus.shared.install(in: c.userContentController) }
        if !Perf.off("probe") { PageColorProbe.shared.install(in: c.userContentController) }
        if !Perf.off("scripts") {
        if !Perf.off("rules") { SiteRules.shared.install(in: c.userContentController) }
        if Module.boosts.isOn, !Perf.off("tweaks") { PageTweaks.shared.install(in: c.userContentController) }
        if store.isPersistent, !Perf.off("css") { WebEngine.installStyleSheet(in: c.userContentController) }   // свой стиль виден сайту — не в инкогнито
        if !Perf.off("geo") { Geolocation.shared.install(in: c.userContentController) }
        if Module.localApps.isOn, !Perf.off("bridge") { LocalBridge.shared.install(in: c.userContentController) }     // модуль Apps on This Mac: страницы → программы на этом Mac (ws://127.0.0.1)
        if !Perf.off("optclick") { OptionClick.shared.install(in: c.userContentController) }   // ⌥-клик по ссылке — новая вкладка
        if !Perf.off("translate") { TranslateNotifier.shared.install(in: c.userContentController) }
        if !Perf.off("pw") { PasswordAgent.shared.install(in: c.userContentController) }
        // Свой скрипт против рекламы на YouTube — если нет полноценного блокировщика-расширения
        if ContentBlocker.shared.enabled && !Ext.hasAdBlocker, !Perf.off("yt") { c.userContentController.addUserScript(YouTubeAds.script) }
        // Capture Image: правый клик — запомнить элемент (в своём мире скриптов)
        if Module.capture.isOn, !Perf.off("capture") { c.userContentController.addUserScript(ImageCapture.contextScript) }
        if !Perf.off("media") { MediaFrames.shared.install(in: c.userContentController) }   // рамка, где играет видео (и встроенный плеер) — для мини-плеера и PiP
        if !Perf.off("lastlink") { LastLink.shared.install(in: c.userContentController) }   // ссылка под правым кликом (и из iframe) — для своих пунктов меню
        }
        if store.isPersistent {
            if !Perf.off("ext") { Ext.configure(c) }            // расширения в инкогнито не заходят
            // Профиль через туннель: дорога — до первой загрузки; без предзагрузки DNS; WebRTC (мимо прокси) —
            // выключен по настройке
            Tunnel.apply(store)
            if tunnelled { c.userContentController.addUserScript(Tunnel.blockWebRTC ? Incognito.script : Incognito.noPrefetch) }
        } else {
            c.userContentController.addUserScript(Incognito.script)   // без WebRTC — он ходит мимо прокси
        }
        return c
    }

    // MARK: Persistence

    private struct SavedTab: Codable {
        var id: UUID; var url: String?; var title: String; var pinned: Bool
        var folder: UUID? = nil; var last: Date? = nil; var mark: Double? = nil
        var branch: Bool? = nil; var opener: UUID? = nil
        var saved: Bool? = nil; var collapsed: Bool? = nil; var keep: Bool? = nil
        var muted: Bool? = nil
        var home: String? = nil
        var reload: Int? = nil; var reloadKeep: Bool? = nil
        var opened: Date? = nil
        var profile: String? = nil      // «Open As»
        var custom: String? = nil       // своё название
    }
    private struct SavedFolder: Codable {
        var id: UUID; var name: String; var icon: String; var hue: Double; var expanded: Bool
        var sat: Double? = nil; var bri: Double? = nil
        var parent: UUID? = nil
        var temp: Bool? = nil
    }
    private struct SavedSpace: Codable {
        var id: UUID; var name: String; var icon: String; var hue: Double
        var sat: Double? = nil; var bri: Double? = nil
        var tabs: [SavedTab]; var selected: UUID?; var split: UUID?
        var splits: [UUID]? = nil
        var groups: [[UUID]]? = nil
        var arrange: [String: String]? = nil
        var sizes: [String: [Double]]? = nil
        var folders: [SavedFolder]? = nil
        var layout: [UUID]? = nil
        var pinnedFrom: UUID? = nil
        var separate: Bool? = nil          // старое «Separate Logins» — при загрузке становится профилем
        var profile: UUID? = nil
        var savedCollapsed: Bool? = nil
        var tempCollapsed: Bool? = nil
        var glow: SpaceGlow? = nil
        var glass: Double? = nil
    }
    private struct SavedProfile: Codable { var id: UUID; var name: String; var hue: Double }
    struct SavedWindow: Codable { var space: UUID; var sidebar: Bool; var frame: String? }
    /// Окна (кроме первого), которые были открыты при выходе — откроются снова
    static var pendingWindows: [SavedWindow] = []
    private struct SavedState: Codable {
        var spaces: [SavedSpace]; var current: UUID; var sidebar: Bool
        var favorites: [SavedTab]? = nil
        var profiles: [SavedProfile]? = nil
        var windows: [SavedWindow]? = nil
    }

    static var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sapfire", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    func save() {
        // Инкогнито не сохраняется
        let keep = spaces.filter { !$0.isIncognito }
        // Первое окно — в «current/sidebar», остальные открытые окна — списком (откроются при запуске)
        let main = isPrimary ? self : Self.primary
        let current = keep.contains { $0.id == main.currentSpaceID } ? main.currentSpaceID : (keep.first?.id ?? main.currentSpaceID)
        let extra: [SavedWindow] = Self.windows.compactMap { m in
            guard !m.isPrimary, let w = m.window, w.isVisible, keep.contains(where: { $0.id == m.currentSpaceID }) else { return nil }
            return SavedWindow(space: m.currentSpaceID, sidebar: m.sidebarVisible, frame: NSStringFromRect(w.frame))
        }
        let state = SavedState(
            spaces: keep.map { sp in
                SavedSpace(id: sp.id, name: sp.name, icon: sp.icon, hue: sp.hue, sat: sp.sat, bri: sp.bri,
                           tabs: sp.tabs.filter { !$0.temporary }.map { SavedTab(id: $0.id, url: $0.url?.absoluteString, title: $0.title,
                                                        pinned: $0.isPinned, folder: $0.folderID, last: $0.lastActive, mark: $0.activeMark,
                                                        branch: $0.isBranch ? true : nil, opener: $0.isBranch ? $0.openerID : nil,
                                                        saved: $0.isSaved ? true : nil, collapsed: $0.branchesExpanded ? nil : true,
                                                        keep: $0.keepBranches ? true : nil, muted: $0.muted ? true : nil,
                                                        home: $0.isPinned ? $0.pinnedURL?.absoluteString : nil,
                                                        reload: $0.autoReload, reloadKeep: $0.reloadKeepView ? nil : false,
                                                        opened: $0.opened, profile: $0.profileOverride?.uuidString, custom: $0.customTitle) },
                           selected: sp.selectedTabID, split: nil, groups: sp.splitGroups.isEmpty ? nil : sp.splitGroups,
                           arrange: sp.splitArrange.isEmpty ? nil : Dictionary(uniqueKeysWithValues: sp.splitArrange.map { ($0.key.uuidString, $0.value.rawValue) }),
                           sizes: sp.splitSizes.isEmpty ? nil : Dictionary(uniqueKeysWithValues: sp.splitSizes.map { ($0.key.uuidString, $0.value) }),
                           folders: sp.folders.map { SavedFolder(id: $0.id, name: $0.name, icon: $0.icon, hue: $0.hue, expanded: $0.expanded,
                                                                 sat: $0.sat, bri: $0.bri, parent: $0.parentID, temp: $0.isTemp ? true : nil) },
                           layout: sp.layout, pinnedFrom: sp.pinnedFrom,
                           profile: sp.profileID == Profile.primaryID ? nil : sp.profileID,
                           savedCollapsed: sp.savedCollapsed ? true : nil,
                           tempCollapsed: sp.tempCollapsed ? true : nil,
                           glow: sp.glow, glass: sp.glass > 0 ? sp.glass : nil)
            },
            current: current, sidebar: main.sidebarVisible,
            favorites: favorites.map { SavedTab(id: $0.id, url: $0.url?.absoluteString, title: $0.title, pinned: false) },
            profiles: profiles.map { SavedProfile(id: $0.id, name: $0.name, hue: $0.hue) },
            windows: extra.isEmpty ? nil : extra)
        if StateBackups.restoring { return }          // восстанавливается копия: нынешнее не затирать
        if let data = try? JSONEncoder().encode(state) {
            StateBackups.snapshot(of: Self.stateURL)    // прежний файл — в копии (не чаще раза в полчаса)
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    private func load() {
        StateBackups.snapshot(of: Self.stateURL, force: true)   // копия на запуске
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        if let ps = state.profiles, !ps.isEmpty {
            profiles = ps.map { Profile(id: $0.id, name: $0.name, hue: $0.hue) }
            if !profiles.contains(where: \.isPrimary) { profiles.insert(Profile(id: Profile.primaryID, name: "Primary"), at: 0) }
        }
        spaces = state.spaces.map { s in
            let sp = Space(id: s.id, name: s.name, icon: s.icon, hue: s.hue)
            // Старые значения по умолчанию (0.75 / 0.82 — цвет значка) → светлая пастельная панель, как было на вид
            if let v = s.sat, let b = s.bri, !(abs(v - 0.75) < 0.001 && abs(b - 0.82) < 0.001) { sp.sat = v; sp.bri = b }
            sp.glow = s.glow
            sp.glass = s.glass ?? 0
            if let p = s.profile {
                sp.profileID = p
            } else if s.separate == true {
                // Было «Separate Logins» у пространства: его входы лежат в хранилище с id пространства — делаем такой же профиль
                if !profiles.contains(where: { $0.id == s.id }) {
                    profiles.append(Profile(id: s.id, name: s.name, hue: Profile.hues[(profiles.count - 1) % Profile.hues.count]))
                }
                sp.profileID = s.id
            }
            sp.tabs = s.tabs.map { st in
                let t = Tab(id: st.id, url: st.url.flatMap(URL.init(string:)), title: st.title, isPinned: st.pinned)
                t.browser = self
                t.folderID = st.folder
                t.isBranch = false          // веточек больше нет: бывшие веточки — обычные временные вкладки
                if st.branch == true { t.folderID = nil }
                t.openerID = st.opener
                t.isSaved = st.saved ?? false
                t.branchesExpanded = !(st.collapsed ?? false)
                t.keepBranches = st.keep ?? false
                t.muted = st.muted ?? false
                t.autoReload = st.reload
                t.opened = st.opened
                // Профиль «Open As» могли удалить — тогда как у пространства (ящик VPN и основной — всегда есть)
                t.profileOverride = st.profile.flatMap(UUID.init(uuidString:))
                    .flatMap { id in id == Profile.vpnID || id == Profile.primaryID || profiles.contains { $0.id == id } ? id : nil }
                t.customTitle = st.custom
                t.reloadKeepView = st.reloadKeep ?? true
                AutoReload.schedule(t)
                // У закреплённого адрес закрепления; у старых сохранений — тот, что был открыт
                if st.pinned {
                    t.pinnedURL = st.home.flatMap(URL.init(string:)) ?? t.url
                    if !Tab.pinnedRemember { t.resetToPin() }
                }
                if let d = st.last { t.lastActive = d }
                if let m = st.mark { t.activeMark = min(m, ActiveClock.shared.now) }
                return t
            }
            sp.folders = (s.folders ?? []).map { sf in
                let f = Folder(id: sf.id, name: sf.name, icon: sf.icon, hue: sf.hue, expanded: sf.expanded)
                f.isTemp = sf.temp ?? false
                if let v = sf.sat { f.sat = v }
                if let v = sf.bri { f.bri = v }
                f.parentID = sf.parent
                return f
            }
            // Раньше папки всегда шли над вкладками — так и оставляем, если порядка ещё нет
            sp.layout = s.layout ?? (sp.folders.filter { $0.parentID == nil }.map(\.id) + sp.tabs.filter { !$0.isPinned && $0.folderID == nil }.map(\.id))
            sp.normalize()
            sp.selectedTabID = s.selected
            sp.splitGroups = s.groups ?? []
            for (k, v) in s.arrange ?? [:] { if let id = UUID(uuidString: k), let a = Space.SplitArrange(rawValue: v) { sp.splitArrange[id] = a } }
            for (k, v) in s.sizes ?? [:] { if let id = UUID(uuidString: k) { sp.splitSizes[id] = v } }
            // Старое сохранение: основная вкладка и панели справа — одна группа
            if s.groups == nil, let sel = s.selected, let extra = s.splits ?? s.split.map({ [$0] }) { sp.makeGroup([sel] + extra) }
            sp.pinnedFrom = s.pinnedFrom
            sp.savedCollapsed = s.savedCollapsed ?? false
            sp.tempCollapsed = s.tempCollapsed ?? false
            return sp
        }
        currentSpaceID = state.current
        sidebarVisible = state.sidebar
        Self.pendingWindows = state.windows ?? []
        // Общего «Избранного» больше нет: его сайты становятся закреплёнными в каждом пространстве
        let oldFavorites = (state.favorites ?? []).map { st in
            let t = Tab(id: st.id, url: st.url.flatMap(URL.init(string:)), title: st.title, isPinned: true)
            t.browser = self
            return t
        }
        if !oldFavorites.isEmpty {
            for (k, sp) in spaces.enumerated() where sp.pinnedFrom == nil {
                let items = k == 0 ? oldFavorites : oldFavorites.map { copyPinned($0) }
                sp.tabs.insert(contentsOf: items, at: 0)
                sp.normalize()
            }
            for sp in spaces {
                if let sel = sp.selectedTabID, !sp.tabs.contains(where: { $0.id == sel }) { sp.selectedTabID = sp.tabs.first?.id }
                for gi in sp.splitGroups.indices { sp.splitGroups[gi].removeAll { id in !sp.tabs.contains { $0.id == id } } }
                sp.splitGroups.removeAll { $0.count < 2 }
            }
        }
    }
}

// MARK: - Helpers

func promptText(_ title: String, initial: String) -> String? {
    let a = NSAlert()
    a.messageText = title
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = initial
    a.accessoryView = field
    a.addButton(withTitle: "OK")
    a.addButton(withTitle: "Cancel")
    a.window.initialFirstResponder = field
    return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
}


// MARK: - Звук вкладки

/// Слышен ли звук со страницы (движок сообщает об этом сам) и выключение звука вкладки
final class AudioWatch: NSObject {
    private weak var wv: WKWebView?
    private let changed: (Bool) -> Void
    private static let key = "_isPlayingAudio"

    init?(_ wv: WKWebView, _ changed: @escaping (Bool) -> Void) {
        guard wv.responds(to: NSSelectorFromString(Self.key)) else { return nil }
        self.wv = wv
        self.changed = changed
        super.init()
        wv.addObserver(self, forKeyPath: Self.key, options: [.new, .initial], context: nil)
    }

    deinit { wv?.removeObserver(self, forKeyPath: Self.key) }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let on = (change?[.newKey] as? Bool) ?? false
        DispatchQueue.main.async { self.changed(on) }
    }

    /// Выключить / включить звук страницы (закрытый, но стабильный вызов WebKit)
    static func setMuted(_ wv: WKWebView, _ muted: Bool) {
        let sel = NSSelectorFromString("_setPageMuted:")
        guard wv.responds(to: sel), let m = wv.method(for: sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(m, to: F.self)(wv, sel, muted ? 1 : 0)      // 1 — звук выключен
    }
}

extension BrowserModel {
    /// Выключить звук во всех вкладках (или включить обратно, если всё уже тихо)
    func muteAll() {
        let loud = allTabs.filter { $0.audible && !$0.muted }
        if loud.isEmpty {
            allTabs.filter(\.muted).forEach { $0.muted = false }
            showToast("Sound on")
        } else {
            loud.forEach { $0.muted = true }
            showToast("Muted \(loud.count) tab\(loud.count == 1 ? "" : "s")")
        }
    }
}
