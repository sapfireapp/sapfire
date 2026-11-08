import AppKit
import LocalAuthentication
import SwiftUI
import WebKit

// MARK: - Защита как в приватном режиме Safari

/// Где включено: только инкогнито / инкогнито и профили через VPN / везде / выключено
enum PrivacyScope: String, CaseIterable {
    case incognito, private_, everywhere, off

    var title: String {
        switch self {
        case .incognito: "In incognito"
        case .private_: "In incognito and VPN profiles"
        case .everywhere: "Everywhere"
        case .off: "Off"
        }
    }

    /// Действует ли для страницы этого хранилища
    func covers(_ store: WKWebsiteDataStore) -> Bool {
        switch self {
        case .off: return false
        case .everywhere: return true
        case .incognito: return !store.isPersistent
        case .private_: return !store.isPersistent || (BrowserModel.profileID(of: store).map(Tunnel.isOn) ?? false)
        }
    }
}

enum PrivacyGuard {
    static var fingerprintScope: PrivacyScope {
        UserDefaults.standard.string(forKey: Prefs.fingerprintProtection).flatMap(PrivacyScope.init) ?? .private_
    }
    static var linkScope: PrivacyScope {
        UserDefaults.standard.string(forKey: Prefs.linkCleaning).flatMap(PrivacyScope.init) ?? .everywhere
    }

    // MARK: Защита от отпечатка (скрытая настройка движка, та же, что у приватных окон Safari)

    /// Базовая защита + «шум» в холсте, звуке и т. п. (сайты не узнают устройство) + фильтр меток в ссылках;
    /// в инкогнито ещё и сначала HTTPS
    /// fingerprint: false — у сайта своя настройка «без шума» (YouTube через VPN иначе принимает за бота)
    static func apply(to p: WKWebpagePreferences, store: WKWebsiteDataStore, fingerprint: Bool = true) {
        guard fingerprintScope.covers(store) else { return }
        let baseline: UInt = 1 << 0, httpsFirst: UInt = 1 << 1, fingerprinting: UInt = 1 << 6, linkFiltering: UInt = 1 << 8
        var policy = baseline | linkFiltering
        if fingerprint { policy |= fingerprinting }
        if !store.isPersistent { policy |= httpsFirst }
        let sel = NSSelectorFromString("_setNetworkConnectionIntegrityPolicy:")
        guard let m = class_getInstanceMethod(WKWebpagePreferences.self, sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(method_getImplementation(m), to: F.self)(p, sel, policy)
    }

    // MARK: Следящие метки в ссылках

    /// Метки, которые ставят рекламные сети и рассылки, чтобы следить за переходами
    private static let params: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid", "igsh",
        "yclid", "ysclid", "_openstat", "twclid", "ttclid", "li_fat_id", "epik", "_hsenc", "_hsmi", "__hssc", "__hstc",
        "__hsfp", "hsctatracking", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_conv", "vero_id", "rb_clickid",
        "s_cid", "wickedid", "irclickid", "_gl", "srsltid", "fb_action_ids", "fb_action_types", "fb_source", "fb_ref",
        "action_object_map", "action_type_map", "action_ref_map", "_branch_match_id", "zanpid", "sms_ss", "trk_sid",
    ]
    /// Метки, которые следят только на своих сайтах (на других это могут быть нужные параметры)
    private static let perSite: [String: Set<String>] = [
        "youtube.com": ["si", "pp", "feature"], "youtu.be": ["si", "feature"],
        "open.spotify.com": ["si", "nd"], "twitter.com": ["ref_src", "ref_url", "s", "t"], "x.com": ["ref_src", "ref_url", "s", "t"],
        "instagram.com": ["igsh"], "tiktok.com": ["_r", "_t", "is_from_webapp", "sender_device"],
        "linkedin.com": ["trk", "trackingid", "lipi"], "amazon.com": ["tag", "ref_", "pf_rd_r", "pf_rd_p"],
    ]

    /// Ссылка без следящих меток (nil — чистить нечего)
    static func clean(_ url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = c.queryItems, !items.isEmpty else { return nil }
        let host = (url.host ?? "").lowercased()
        let local = perSite.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value ?? []
        let kept = items.filter { i in
            let n = i.name.lowercased()
            return !(n.hasPrefix("utm_") || params.contains(n) || local.contains(n))
        }
        guard kept.count != items.count else { return nil }
        c.queryItems = kept.isEmpty ? nil : kept
        return c.url
    }

    private static var lastCleaned: [ObjectIdentifier: (url: URL, at: Date)] = [:]

    /// Переход по ссылке: если в ней метки — идём по чистой (true — переход заменён)
    static func cleanNavigation(_ a: WKNavigationAction, in wv: WKWebView) -> Bool {
        guard a.targetFrame?.isMainFrame ?? true, a.navigationType != .backForward, a.navigationType != .reload,
              (a.request.httpMethod ?? "GET") == "GET", let u = a.request.url, u.scheme?.hasPrefix("http") == true,
              linkScope.covers(wv.configuration.websiteDataStore), let clean = clean(u) else { return false }
        // Сайт сам снова добавляет метку (перенаправление) — второй раз подряд не трогаем, иначе круг
        let id = ObjectIdentifier(wv)
        if let last = lastCleaned[id], last.url == u, Date().timeIntervalSince(last.at) < 3 { return false }
        lastCleaned[id] = (u, Date())
        var r = a.request
        r.url = clean
        wv.load(r)
        return true
    }
}

// MARK: - Замок на инкогнито (Touch ID)

/// Инкогнито запирается, когда Mac заблокирован или уснул, либо Sapfire 5 минут в фоне; открыть — Touch ID
/// (или пароль Mac). Пока заперто, страницы и вкладки инкогнито закрыты заслонкой.
@Observable
final class IncognitoLock {
    static let shared = IncognitoLock()
    private(set) var locked = false
    @ObservationIgnored private var away: DispatchWorkItem?
    @ObservationIgnored private var watching = false
    static let background: TimeInterval = 5 * 60

    static var enabled: Bool { UserDefaults.standard.object(forKey: Prefs.incognitoLock) as? Bool ?? true }
    /// Запирать по уходу в фон, только если за Mac никого нет: пока есть щелчки и клавиши — не запирать
    static var onlyWhenIdle: Bool { UserDefaults.standard.object(forKey: Prefs.incognitoLockIdle) as? Bool ?? true }
    /// Сколько секунд за Mac ничего не трогали (мышь, клавиатура, трекпад — во всей системе)
    /// (kCGAnyInputEventType = ~0 — «любое касание»; `.null` считал бы время с последнего пустого события)
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .mouseMoved)
    }
    private var hasIncognito: Bool { BrowserData.shared.spaces.contains { $0.isIncognito } }

    func start() {
        guard !watching else { return }
        watching = true
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.lock() }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.lock() }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.lock() }
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleAway(after: Self.background)
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.away?.cancel(); self?.away = nil
        }
    }

    /// Вкладка за замком: её страница, название и звук не должны показываться и управляться
    static func hides(_ t: Tab) -> Bool { shared.locked && t.isIncognito }
    /// Окно сейчас показывает запертое инкогнито
    static func covers(_ m: BrowserModel) -> Bool { shared.locked && m.currentSpace.isIncognito }

    private var incognitoViews: [WKWebView] {
        BrowserData.shared.spaces.filter(\.isIncognito).flatMap(\.tabs).compactMap(\.webView)
    }

    /// Sapfire в фоне: запереть через `delay`; с «только когда никого нет» — если за Mac всё это время не трогали
    /// ни мышь, ни клавиатуру; иначе ждём ещё, пока не наберётся 5 минут тишины
    private func scheduleAway(after delay: TimeInterval) {
        away?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if Self.onlyWhenIdle {
                let idle = Self.idleSeconds
                if idle < Self.background { self.scheduleAway(after: Self.background - idle); return }
            }
            self.lock()
        }
        away = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func lock() {
        guard Self.enabled, hasIncognito, !locked else { return }
        locked = true
        for wv in incognitoViews {
            // Звук и видео — на паузу и под запрет: ни пробел, ни медиаклавиши, ни «Пункт управления»,
            // ни сама страница не запустят их, пока не отперто. «Картинка в картинке» и полный экран — закрыть
            wv.pauseAllMediaPlayback()
            wv.setAllMediaPlaybackSuspended(true)
            wv.closeAllMediaPresentations()
            // Клавиатура больше не идёт в страницу за заслонкой
            if let w = wv.window, let r = w.firstResponder as? NSView, r === wv || r.isDescendant(of: wv) { w.makeFirstResponder(nil) }
            // Страница за заслонкой спрятана совсем: иначе она ловит курсор (наведение раскрывает меню сайта) и рисуется
            wv.isHidden = true
        }
        // Обзор вкладок, ⌃Tab, поиск по странице — закрыть
        for m in BrowserModel.windows where m.currentSpace.isIncognito {
            m.overview.close()
            m.switcher.cancel()
            m.find.hide()
        }
    }

    func unlock() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { release(); return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock incognito") { ok, _ in
            DispatchQueue.main.async { if ok { self.release() } }
        }
    }

    /// Отперто: звук снова можно включить (сам не запускается — до замка всё поставлено на паузу)
    private func release() {
        locked = false
        for wv in incognitoViews { wv.isHidden = false; wv.setAllMediaPlaybackSuspended(false) }
    }

    /// Инкогнито закрыли — замка больше нет
    func reset() { locked = false }
}

/// Заслонка поверх запертого инкогнито
struct IncognitoLockView: View {
    @Environment(BrowserModel.self) private var model
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            VStack(spacing: 14) {
                Image(systemName: "lock.fill").font(.system(size: 34, weight: .medium)).foregroundStyle(.secondary)
                Text("Incognito is locked").font(.system(size: 17, weight: .semibold))
                Text("Unlock with Touch ID or your Mac password.").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Unlock") { IncognitoLock.shared.unlock() }
                        .keyboardShortcut(.defaultAction)
                    if let i = model.spaces.firstIndex(where: { !$0.isIncognito }) {
                        Button("Other Space") { model.swipe.switchTo(i, model: model) }
                    }
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }
}
