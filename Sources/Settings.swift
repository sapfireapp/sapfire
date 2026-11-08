import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Translation

// MARK: - Настройки (⌘,) — по макету: слева поиск и разделы с цветными значками, справа страница

enum Prefs {
    static let checkUpdates = "checkUpdates"            // Updates.swift: раз в сутки — новый выпуск на GitHub
    static let threeFingerGestures = "threeFingerGestures"
    static let folderPeekCount = "folderPeekCount"
    static let searchSuggestions = "searchSuggestions"
    static let archiveAfter = "archiveAfter"
    /// Сон фоновых вкладок: через сколько минут (0 — никогда), по умолчанию 10
    static let sleepAfterMinutes = "sleepAfterMinutes"
    /// Последний срок сна до выключения — возвращается при включении
    static let sleepAfterLast = "sleepAfterLast"
    static let archiveClock = "archiveClock"
    static let linksInLittleWindow = "linksInLittleWindow"
    static let topBar = "topBar"
    static let topBarStrip = "topBarStrip"
    static let branches = "branches"
    static let floatOnTop = "floatOnTop"
    static let peekPinned = "peekPinned"
    /// Закреплённые помнят последнюю страницу после сна и перезапуска (по умолчанию — возвращаются на свой адрес)
    static let pinnedRemember = "pinnedRemember"
    static let paneChipCenter = "paneChipCenter"
    static let toolbar = "toolbar"
    static let twoFingerPages = "twoFingerPages"
    static let twoFingerSpaces = "twoFingerSpaces"
    static let twoFingerWindow = "twoFingerWindow"
    // Как в Safari
    static let searchEngine = "searchEngine"
    static let privateSearchEngine = "privateSearchEngine"
    static let newTabActive = "newTabActive"
    static let downloadLocation = "downloadLocation"      // downloads / ask / custom
    static let downloadFolder = "downloadFolder"
    static let downloadRemoval = "downloadRemoval"        // quit / success / day / manual
    static let openSafeFiles = "openSafeFiles"
    static let historyKeep = "historyKeep"
    static let fraudWarning = "fraudWarning"
    static let httpWarning = "httpWarning"
    static let blockAllCookies = "blockAllCookies"
    static let javaScript = "javaScript"
    static let fullAddress = "fullAddress"
    static let minFontSize = "minFontSize"
    static let tabHighlights = "tabHighlights"
    static let styleSheet = "styleSheet"
    static let incognitoProxy = "incognitoProxy"
    static let incognitoProxyHost = "incognitoProxyHost"
    static let incognitoProxyPort = "incognitoProxyPort"
    static let incognitoProxyType = "incognitoProxyType"      // socks / http
    static let tunnelBlockWebRTC = "tunnelBlockWebRTC"
    static let fingerprintProtection = "fingerprintProtection"   // incognito / private_ / everywhere / off
    static let linkCleaning = "linkCleaning"
    static let incognitoLock = "incognitoLock"
    /// Замок инкогнито — только когда за Mac никого нет (фоновое видео с активностью за компьютером не запирается)
    static let incognitoLockIdle = "incognitoLockIdle"
    static let summaryModel = "summaryModel"
    static let summaryLanguage = "summaryLanguage"
    static let summaryViaProxy = "summaryViaProxy"
    static let translateTarget = "translateTarget"
    static let passwordFillAuth = "passwordFillAuth"
    static let passwordOffer = "passwordOffer"
}

/// Разделы — как в настройках Safari и в его порядке
enum SettingsPage: String, CaseIterable, Identifiable {
    // Порядок колонки — блоками: ты и основное · сёрфинг · безопасность и сайты · управление · надстройки
    case general, profiles, tabs, search, privacy, passwords, websites, gestures, shortcuts, extensions, modules, advanced
    var id: String { rawValue }

    /// Блок в колонке (между блоками — узкий просвет)
    var group: Int {
        switch self {
        case .general, .profiles: 0
        case .tabs, .search: 1
        case .privacy, .passwords, .websites: 2
        case .gestures, .shortcuts: 3
        case .extensions, .modules, .advanced: 4
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .tabs: "Tabs"
        case .passwords: "Passwords"
        case .search: "Search"
        case .privacy: "Privacy"
        case .websites: "Websites"
        case .profiles: "Profiles"
        case .extensions: "Extensions"
        case .modules: "Modules"
        case .advanced: "Advanced"
        case .gestures: "Gestures"
        case .shortcuts: "Shortcuts"
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .tabs: "square.on.square"
        case .passwords: "key.fill"
        case .search: "magnifyingglass"
        case .privacy: "hand.raised"
        case .websites: "globe"
        case .profiles: "person.crop.circle"
        case .extensions: "puzzlepiece.extension"
        case .modules: "square.grid.2x2"
        case .advanced: "gearshape.2"
        case .gestures: "hand.draw"
        case .shortcuts: "command"
        }
    }
    var color: Color {
        switch self {
        case .general: Color(white: 0.55)
        case .tabs: .blue
        case .passwords: Color(white: 0.45)
        case .search: .orange
        case .privacy: .green
        case .websites: .teal
        case .profiles: .indigo
        case .extensions: .purple
        case .modules: .brown
        case .advanced: Color(white: 0.5)
        case .gestures: .pink
        case .shortcuts: Color(white: 0.4)
        }
    }
    /// Разделы страницы (заголовки) и слова, по которым их находит поиск
    var sections: [(title: String, words: String)] {
        switch self {
        case .general: [("Default Browser", "default browser make"),
                        ("Import", "import arc chrome brave edge vivaldi opera yandex firefox safari migrate move bookmarks history passwords"),
                        ("Translation", "translate translation language перевод"),
                        ("Links From Other Apps", "links other apps little window open in"),
                        ("Downloads", "download location folder ask remove list clear safe files open"),
                        ("History", "history remove items keep")]
        case .tabs: [("Toolbar", "address bar toolbar above page sidebar focus"),
                     ("Tab Layout", "sidebar style attached floating compact"),
                     ("Top Bar", "floating top bar hidden sidebar"),
                     ("Split View", "split pane page address"),
                     ("Archive", "archive unpinned tabs auto close"),
                     ("Links", "command click new tab active background little window"),
                     ("Pinned Tabs", "pinned links other sites peek"),
                     ("Memory", "sleep sleeping tabs memory"),
                     ("Folders", "folder preview recent tabs")]
        case .search: [("Search Engine", "engine google bing duckduckgo ecosia yahoo yandex startpage brave kagi incognito private"),
                       ("Suggestions", "suggestions"),
                       ("Bangs", "bangs bang ! commands shortcuts yt youtube wikipedia keywords")]
        case .privacy: [("Content", "ads trackers block blocker filter lists easylist"),
                        ("Security", "fraudulent warning http secure connection javascript web content"),
                        ("Tracking", "fingerprint fingerprinting tracking links utm fbclid gclid protection"),
                        ("VPN Proxy", "vpn proxy happ socks tunnel check connection ip"),
                        ("Incognito", "incognito private proxy vpn happ socks tunnel webrtc lock touch id idle background video"),
                        ("Cookies and Website Data", "cookies block website data manage remove"),
                        ("History", "clear history")]
        case .websites, .extensions, .modules, .passwords: []
        case .profiles: [("Profiles", "profile logins cookies accounts new rename delete space move vpn directly"),
                         ("Network", "vpn proxy tunnel happ webrtc direct")]
        case .advanced: [("Address", "full website address smart search field"),
                         ("Summarize", "summarize summary gemini ai key tldr google"),
                         ("Accessibility", "font size minimum smaller tab highlight"),
                         ("Style Sheet", "style sheet css"),
                         ("Network", "proxies network")]
        case .gestures: [("Two Fingers", "two fingers swipe back forward spaces window move"),
                         ("Three Fingers", "three fingers swipe tap")]
        case .shortcuts: []
        }
    }

    /// Совпавшие разделы (пустой запрос — ни одного)
    func matchingSections(_ q: String) -> [String] {
        guard !q.isEmpty else { return [] }
        return sections.filter { $0.title.lowercased().contains(q) || $0.words.contains(q) }.map(\.title)
    }
    func matches(_ q: String) -> Bool {
        q.isEmpty || title.lowercased().contains(q) || keywords.contains(q) || !matchingSections(q).isEmpty
    }

    /// Для поиска: что есть на странице
    var keywords: String {
        switch self {
        case .general: "default browser links little window other apps downloads folder ask safe files history remove"
        case .tabs: "sidebar style attached floating compact top bar focus split pane address peek pinned archive auto close sleep folder preview recent layout appearance command click new tab active"
        case .search: "command bar search engine suggestions google bing duckduckgo ecosia yahoo yandex startpage brave kagi private incognito bangs bang ! commands"
        case .privacy: "ads block blocker filter lists history clear fraudulent warning http secure javascript cookies website data security"
        case .passwords: "passwords password logins autofill keychain import arc chrome csv strong"
        case .extensions: "extensions add-ons addons chrome web store firefox safari puzzle"
        case .modules: "modules boosts peek mini player auto reload live folders capture notes easel"
        case .advanced: "full address font size accessibility tab highlight style sheet css proxies"
        case .websites: "site sites zoom reader translate javascript camera microphone location cookies erase dark pop-ups autoplay"
        case .profiles: "logins cookies separate accounts profiles profile person spaces"
        case .gestures: "trackpad three fingers swipe tap"
        case .shortcuts: "hotkeys keyboard keys shortcuts"
        }
    }
}

/// Переход к разделу страницы настроек: прокрутка к заголовку и короткая подсветка
@Observable
final class SettingsNav {
    static let shared = SettingsNav()
    /// Где на странице заголовки разделов (от верха содержимого)
    @ObservationIgnored var anchors: [String: CGFloat] = [:]
    @ObservationIgnored var scroll: ((CGFloat) -> Void)?
    /// Раздел, к которому перешли, — подсвечивается
    var flash: String?
    /// Открыть окно настроек на этой странице (меню Extensions → Manage…)
    var requested: SettingsPage?
    /// Идёт запись сочетания (Shortcuts) — стрелки не трогаем
    @ObservationIgnored var recording = false
    static let space = "settingsPage"

    func go(to section: String) {
        // Страница могла только что смениться — даём ей разложиться
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if let y = self.anchors[section] { self.scroll?(max(0, y - 12)) }
            withAnimation(.easeOut(duration: 0.15)) { self.flash = section }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                withAnimation(.easeOut(duration: 0.5)) { if self.flash == section { self.flash = nil } }
            }
        }
    }
}

struct SettingsView: View {
    @State private var page: SettingsPage = .general
    @State private var section: String?
    @State private var query = ""
    @State private var window: NSWindow?
    @State private var keys: Any?

    /// Пункт колонки: страница или раздел страницы (при поиске)
    private struct NavItem: Hashable { let page: SettingsPage; let section: String? }

    private var q: String { query.lowercased().trimmingCharacters(in: .whitespaces) }

    private var items: [NavItem] {
        SettingsPage.allCases.filter { $0.matches(q) }.flatMap { p in
            [NavItem(page: p, section: nil)] + p.matchingSections(q).map { NavItem(page: p, section: $0) }
        }
    }

    private func select(_ it: NavItem) {
        if page != it.page { page = it.page }
        section = it.section
        if let s = it.section { SettingsNav.shared.go(to: s) } else { SettingsNav.shared.scroll?(0) }
    }

    /// ↑ / ↓ — по разделам колонки (и по найденному, пока идёт поиск)
    private func installKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 125 || e.keyCode == 126, let w = window, e.window === w,
                  e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  !SettingsNav.shared.recording else { return e }
            // В поле на странице стрелки — полю; в поле поиска колонки — нам
            if let v = w.firstResponder as? NSView, v is NSText || v is NSTextField,
               v.convert(v.bounds, to: nil).minX > 210 { return e }
            let list = items
            guard !list.isEmpty else { return e }
            let cur = list.firstIndex(of: NavItem(page: page, section: section)) ?? list.firstIndex(of: NavItem(page: page, section: nil)) ?? -1
            let next = e.keyCode == 125 ? min(list.count - 1, cur + 1) : max(0, cur - 1)
            if next != cur { select(list[next]) }
            return nil
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                Text(page.title)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                Divider()
                // Страница прокручивается своей прокруткой — без размытия заголовка над ней (macOS 26)
                // Все отступы равны: между блоками, от колонки (у неё свой отступ справа), от края окна — Metrics.inset
                PlainScroll(content: SettingsPageView(page: page)
                    .padding(.trailing, PrefSection<EmptyView>.gap).padding(.top, PrefSection<EmptyView>.gap).padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .coordinateSpace(name: SettingsNav.space)
                    .environment(BrowserModel.primary))
                    .id(page)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topLeading) {
            // Свой «светофор»: системная полоса заголовка скрыта (в macOS 26 она размывала название страницы)
            TrafficLights(target: window).padding(.leading, 20).padding(.top, 20)
        }
        // Окно тянется: у страниц своя прокрутка, колонка разделов — постоянной ширины
        .frame(minWidth: 680, idealWidth: 780, maxWidth: .infinity, minHeight: 420, idealHeight: 572, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(SettingsWindowStyle(title: page.title, window: $window))
        .onAppear(perform: installKeys)
        .onDisappear { if let k = keys { NSEvent.removeMonitor(k); keys = nil } }
        .onChange(of: page) { SettingsNav.shared.anchors = [:] }
        .onAppear { if let p = SettingsNav.shared.requested { page = p; SettingsNav.shared.requested = nil } }
        .onChange(of: SettingsNav.shared.requested) { _, p in if let p { page = p; section = nil; SettingsNav.shared.requested = nil } }
    }

    private var sidebar: some View {
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44)                       // место под «светофор»
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .padding(.horizontal, Metrics.inset)
            .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    let list = items
                    ForEach(Array(list.enumerated()), id: \.element) { i, it in
                        // Новый блок — узкий просвет (пока ищешь — подряд)
                        if q.isEmpty, it.section == nil, i > 0, list[i - 1].page.group != it.page.group {
                            Color.clear.frame(height: 10)
                        }
                        if let s = it.section {
                            // Найденный раздел — под своей страницей
                            SectionItem(title: s, selected: it.page == page && s == section) { select(it) }
                        } else {
                            SidebarItem(page: it.page, selected: it.page == page && (section == nil || q.isEmpty)) { select(it) }
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.horizontal, Metrics.inset)
                .padding(.bottom, 12)
            }
        }
        // Колонка — карточка, как боковая панель браузера: на равном отступе от краёв окна,
        // скругление концентрично углу окна (радиус окна − отступ)
        .frame(width: 210 - Metrics.inset * 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .circular))
        .padding(Metrics.inset)
        .onChange(of: query) { _, _ in
            if q.isEmpty { section = nil; return }
            // Открытая страница не подходит — первая найденная (а если нашёлся раздел — сразу к нему)
            if !page.matches(q), let first = items.first(where: { $0.section != nil }) ?? items.first { select(first) }
        }
    }
}

/// Окно настроек без полосы заголовка: «светофор» над боковой колонкой, как в макете
private struct SettingsWindowStyle: NSViewRepresentable {
    let title: String
    @Binding var window: NSWindow?
    func updateNSView(_ v: NSView, context: Context) {
        v.window?.title = title   // для «Окна» и Mission Control
        // Система возвращает полосу заголовка при перерисовке — прячем снова
        Self.hideTitlebar(v.window)
        DispatchQueue.main.async { Self.hideTitlebar(v.window) }
    }

    /// Полосу заголовка система включает снова — при изменении размера, смене активного окна, прокрутке;
    /// следим за ней и прячем сразу
    private static var watches: [ObjectIdentifier: [Any]] = [:]
    static func watch(_ w: NSWindow) {
        let id = ObjectIdentifier(w)
        guard watches[id] == nil else { return }
        var list: [Any] = []
        let nc = NotificationCenter.default
        for n in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didBecomeKeyNotification,
                  NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didChangeScreenNotification] {
            list.append(nc.addObserver(forName: n, object: w, queue: .main) { [weak w] _ in
                hideTitlebar(w)
                DispatchQueue.main.async { hideTitlebar(w) }
            })
        }
        if let frame = w.contentView?.superview {
            for sub in frame.subviews where String(describing: type(of: sub)) == "NSTitlebarContainerView" {
                list.append(sub.observe(\.isHidden, options: [.new]) { v, _ in
                    if !v.isHidden { DispatchQueue.main.async { v.isHidden = true } }
                })
            }
        }
        list.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            watches[id] = nil
        })
        watches[id] = list
    }

    static func hideTitlebar(_ w: NSWindow?) {
        // Окно настроек тянется (система у окна Settings это отключает — возвращаем)
        if let w, !w.styleMask.contains(.resizable) {
            w.styleMask.insert(.resizable)
            w.minSize = NSSize(width: 680, height: 420)
            w.maxSize = NSSize(width: 10000, height: 10000)
        }
        guard let frame = w?.contentView?.superview else { return }
        for sub in frame.subviews where String(describing: type(of: sub)) == "NSTitlebarContainerView" && !sub.isHidden {
            sub.isHidden = true
        }
    }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.styleMask.insert(.fullSizeContentView)
            w.styleMask.insert(.resizable)
            w.minSize = NSSize(width: 680, height: 420)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.titlebarSeparatorStyle = .none
            w.title = title
            window = w
            // Пустая панель инструментов — ради крупных углов окна (26 pt, как у браузера): тогда угол окна
            // концентричен карточке колонки (её радиус 20 + отступ 6). Сама полоса заголовка скрыта
            if w.toolbar == nil {
                let t = NSToolbar(identifier: "sapfire.settings")
                t.showsBaselineSeparator = false
                w.toolbar = t
                w.toolbarStyle = .unified
            }
            w.isMovableByWindowBackground = true
            // Полоса заголовка целиком скрыта — светофор свой (см. SettingsView)
            Self.hideTitlebar(w)
            Self.watch(w)
            for d in [0.1, 0.4] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { Self.hideTitlebar(w) } }
        }
        return v
    }
}

/// Найденный раздел страницы — строка под страницей
private struct SectionItem: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12))
                Spacer()
            }
            .padding(.leading, 20).padding(.trailing, 6)
            .frame(height: 24)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : .clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SidebarItem: View {
    let page: SettingsPage
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: page.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    // Значок — круг: на равном отступе 4 от краёв строки-капсулы (14 − 4 = 10 = половина значка)
                    .background(page.color.gradient, in: Circle())
                Text(page.title).font(.system(size: 13))
                Spacer()
            }
            .padding(.leading, 4).padding(.trailing, 10)
            .frame(height: 28)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : .clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Строки и секции как в макете: подпись справа по колонке, элемент справа от неё

private let labelWidth: CGFloat = 190

private struct PrefSection<Content: View>: View {
    /// Отступ внутри блока и его скругление: кнопки-капсулы (высота ~22) стоят концентрично углу
    static var pad: CGFloat { Metrics.settingsPad }
    /// Промежуток между блоками (и поля страницы по бокам)
    static var gap: CGFloat { Metrics.inset }
    static var radius: CGFloat { Metrics.settingsRadius }
    let title: String
    @ViewBuilder let content: Content
    @State private var nav = SettingsNav.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Раздел — блок со скруглением, как блоки в панели браузера; название — внутри блока
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                content
            }
                .padding(Self.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(Metrics.blockShade), in: RoundedRectangle(cornerRadius: Self.radius, style: .circular))
                // Перешли к разделу из поиска — коротко подсвечиваем
                .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .circular).fill(Color.accentColor.opacity(nav.flash == title ? 0.12 : 0)))
        }
        .background(GeometryReader { g in
            let y = g.frame(in: .named(SettingsNav.space)).minY
            Color.clear.onAppear { nav.anchors[title] = y }.onChange(of: y) { nav.anchors[title] = y }
        })
        .padding(.bottom, Self.gap)
    }
}

private struct PrefRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.isEmpty ? "" : label + ":")
                .font(.system(size: 13))
                .frame(width: labelWidth, alignment: .trailing)
            content
            Spacer(minLength: 0)
        }
    }
}

private struct PrefHint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, labelWidth + 10)
            .padding(.top, -4)
    }
}

private struct RestoreDefaults: View {
    let keys: [String]
    var body: some View {
        HStack {
            Spacer()
            Button("Restore Defaults") { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        }
        .padding(.top, 4)
    }
}

// MARK: Страницы

private struct SettingsPageView: View {
    let page: SettingsPage

    @AppStorage(Prefs.threeFingerGestures) private var gestures = true
    @AppStorage(Prefs.folderPeekCount) private var peekCount = 5
    @AppStorage("sidebarStyle") private var sidebarStyle = "attached"
    @AppStorage(Prefs.searchSuggestions) private var suggestions = true
    @AppStorage(Prefs.checkUpdates) private var checkUpdates = true
    @AppStorage(Prefs.archiveAfter) private var archiveAfter: Double = 24 * 3600
    @AppStorage(Prefs.archiveClock) private var archiveClock = true
    @AppStorage(Prefs.sleepAfterMinutes) private var sleepMinutes: Double = 10
    @AppStorage(Prefs.sleepAfterLast) private var sleepLast: Double = 10
    @AppStorage(Prefs.linksInLittleWindow) private var linksInLittle = true
    @AppStorage(Prefs.topBar) private var topBar = true
    @AppStorage(Prefs.topBarStrip) private var topBarStrip = true
    @AppStorage(Prefs.peekPinned) private var peekPinned = true
    @AppStorage(Prefs.pinnedRemember) private var pinnedRemember = false
    @AppStorage(Prefs.paneChipCenter) private var chipCenter = true
    @AppStorage(Prefs.toolbar) private var toolbar = true
    @AppStorage(Prefs.twoFingerPages) private var twoPages = true
    @AppStorage(Prefs.twoFingerSpaces) private var twoSpaces = true
    @AppStorage(Prefs.twoFingerWindow) private var twoWindow = true
    @AppStorage(Prefs.searchEngine) private var engine = SearchEngine.google.rawValue
    @AppStorage(Prefs.privateSearchEngine) private var privateEngine = ""
    @AppStorage(Prefs.newTabActive) private var newTabActive = false
    @AppStorage(Prefs.downloadLocation) private var downloadLocation = "downloads"
    @AppStorage(Prefs.downloadFolder) private var downloadFolder = ""
    @AppStorage(Prefs.downloadRemoval) private var downloadRemoval = "quit"
    @AppStorage(Prefs.openSafeFiles) private var openSafe = false
    @AppStorage(Prefs.historyKeep) private var historyKeep: Double = 365 * 86400
    @AppStorage(Prefs.fraudWarning) private var fraudWarning = true
    @AppStorage(Prefs.httpWarning) private var httpWarning = false
    @AppStorage(Prefs.blockAllCookies) private var blockCookies = false
    @AppStorage(Prefs.javaScript) private var javaScript = true
    @AppStorage(Prefs.fullAddress) private var fullAddress = false
    @AppStorage(Prefs.minFontSize) private var minFontSize = 0
    @AppStorage(Prefs.tabHighlights) private var tabHighlights = false
    @AppStorage(Prefs.styleSheet) private var styleSheet = ""
    @AppStorage(Prefs.incognitoProxy) private var incProxy = false
    @AppStorage(Prefs.incognitoProxyHost) private var incHost = "127.0.0.1"
    @AppStorage(Prefs.incognitoProxyPort) private var incPort = 10808
    @AppStorage(Prefs.incognitoProxyType) private var incType = "socks"
    @State private var ipCheck: String?
    @State private var tunnelTick = 0
    @AppStorage(Prefs.tunnelBlockWebRTC) private var tunnelNoRTC = true
    @AppStorage(Prefs.fingerprintProtection) private var fpScope = PrivacyScope.private_.rawValue
    @AppStorage(Prefs.linkCleaning) private var linkScope = PrivacyScope.everywhere.rawValue
    @AppStorage(Prefs.incognitoLock) private var incLock = true
    @AppStorage(Prefs.incognitoLockIdle) private var incLockIdle = true
    @AppStorage(Prefs.summaryModel) private var sumModel = "gemini-2.5-flash"
    @AppStorage(Prefs.summaryLanguage) private var sumLang = "ru"
    @AppStorage(Prefs.summaryViaProxy) private var sumProxy = true
    @State private var sumKey = ""
    @State private var sumHasKey = Summarizer.hasKey
    @State private var sumModels: [String] = []
    @AppStorage(Prefs.translateTarget) private var trTarget = ""
    @State private var trLangs: [String] = []
    @State private var gestureTick = 0
    @State private var isDefault = SettingsPageView.checkDefault()
    @State private var model = BrowserModel.shared

    static func checkDefault() -> Bool { WebEngine.isDefaultBrowser }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch page {
            case .general: general
            case .tabs: VStack(alignment: .leading, spacing: 0) { appearance; tabs }
            case .search: commandBar
            case .privacy: privacy
            case .websites: WebsitesPage()
            case .profiles: spaces
            case .passwords: PasswordsPage()
            case .extensions: ExtensionsPage()
            case .modules: ModulesPage()
            case .advanced: advanced
            case .gestures: gesturesPage
            case .shortcuts: shortcuts
            }
        }
        .onChange(of: fraudWarning) { WebEngine.applyPreferences() }
        .onChange(of: tabHighlights) { WebEngine.applyPreferences() }
        .onChange(of: minFontSize) { WebEngine.applyPreferences() }
        .onChange(of: blockCookies) { WebEngine.applyCookiesEverywhere() }
        .onChange(of: styleSheet) { WebEngine.reloadStyleSheet() }
        .onChange(of: historyKeep) { HistoryStore.shared.prune() }
        .onChange(of: downloadRemoval) { DownloadStore.shared.removalChanged() }
        .onChange(of: incProxy) { Incognito.settingsChanged(); ipCheck = nil }
        .onChange(of: incHost) { Incognito.settingsChanged(); Tunnel.applyAll(); ipCheck = nil }
        .onChange(of: incPort) { Incognito.settingsChanged(); Tunnel.applyAll(); ipCheck = nil }
        .onChange(of: incType) { Incognito.settingsChanged(); Tunnel.applyAll(); ipCheck = nil }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(title: "Default Browser") {
                PrefRow(label: "Default browser") {
                    if isDefault {
                        Label("Sapfire", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Make Sapfire Default") {
                            // macOS сама спросит подтверждение
                            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { _ in
                                DispatchQueue.main.async { isDefault = SettingsPageView.checkDefault() }
                            }
                        }
                    }
                }
            }
            PrefSection(title: "Updates") {
                PrefRow(label: "New versions") {
                    Toggle("Check once a day", isOn: $checkUpdates)
                }
                PrefHint("Sapfire \(Updates.current). Only asks GitHub for the latest version number — nothing about you is sent, nothing installs by itself.")
            }
            PrefSection(title: "Import") {
                PrefRow(label: "From Arc") {
                    Button("Import from Arc…") { ArcImport.run() }.disabled(!ArcImport.available)
                }
                PrefHint(ArcImport.available ? "Spaces with their profiles, pinned tabs, folders, splits, favorites, open tabs, history and passwords." : "Arc isn’t installed on this Mac.")
                PrefRow(label: "From another browser") {
                    Button("Import…") { BrowserImport.run() }
                }
                PrefHint("Chrome, Dia, Brave, Edge, Vivaldi, Opera, Yandex: bookmarks, history and passwords. Firefox: bookmarks and history. Safari: from its exported file. Bookmarks become a folder in the current space.")
            }
            PrefSection(title: "Links From Other Apps") {
                PrefRow(label: "Open in") {
                    Picker("", selection: $linksInLittle) {
                        Text("Little window").tag(true)
                        Text("New tab").tag(false)
                    }
                    .labelsHidden().fixedSize()
                }
                PrefHint("A little window floats above everything — close it or turn it into a tab with “Open in Sapfire”. ⌥⌘N opens an empty one.")
            }
            PrefSection(title: "Downloads") {
                PrefRow(label: "File download location") {
                    Picker("", selection: Binding(get: { downloadLocation }, set: { v in
                        if v == "choose" { chooseDownloadFolder() } else { downloadLocation = v }
                    })) {
                        Text("Downloads").tag("downloads")
                        if !downloadFolder.isEmpty {
                            Text((downloadFolder as NSString).lastPathComponent).tag("custom")
                        }
                        Text("Ask for each download").tag("ask")
                        Divider()
                        Text("Other…").tag("choose")
                    }
                    .labelsHidden().fixedSize()
                }
                PrefRow(label: "Remove download list items") {
                    Picker("", selection: $downloadRemoval) {
                        Text("After one day").tag("day")
                        Text("When Sapfire quits").tag("quit")
                        Text("Upon successful download").tag("success")
                        Text("Manually").tag("manual")
                    }
                    .labelsHidden().fixedSize()
                }
                PrefRow(label: "") {
                    Button("Clear Download List") { DownloadStore.shared.clear() }
                }
                PrefRow(label: "") {
                    Toggle("Open “safe” files after downloading", isOn: $openSafe)
                }
                PrefHint("“Safe” files are pictures, movies, sounds, PDFs and text documents. The list of downloads — ⌘⇧J.")
            }
            PrefSection(title: "Translation") {
                PrefRow(label: "Translate pages into") {
                    Picker("", selection: Binding(get: { trTarget.isEmpty ? PageTranslator.targetCode : trTarget }, set: { trTarget = $0 })) {
                        ForEach(Array(Set(trLangs + [PageTranslator.targetCode])).sorted { a, b in
                            (Locale.current.localizedString(forLanguageCode: a) ?? a) < (Locale.current.localizedString(forLanguageCode: b) ?? b)
                        }, id: \.self) { code in
                            Text(Locale(identifier: code).localizedString(forLanguageCode: code)?.capitalized ?? code).tag(code)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .task {
                        if #available(macOS 15.0, *) {
                            let all = await LanguageAvailability().supportedLanguages
                            trLangs = Array(Set(all.compactMap { $0.languageCode?.identifier }))
                        }
                    }
                }
                PrefHint("⌥⌘T. Done by macOS on your Mac — the text doesn’t leave it. Parts already in this language stay as they are; pages with several languages are translated from each of them.")
            }
            PrefSection(title: "History") {
                PrefRow(label: "Remove history items") {
                    Picker("", selection: $historyKeep) {
                        Text("After one day").tag(86400.0)
                        Text("After one week").tag(7 * 86400.0)
                        Text("After two weeks").tag(14 * 86400.0)
                        Text("After one month").tag(30 * 86400.0)
                        Text("After one year").tag(365 * 86400.0)
                        Text("Manually").tag(0.0)
                    }
                    .labelsHidden().fixedSize()
                }
            }
            RestoreDefaults(keys: [Prefs.linksInLittleWindow, Prefs.downloadLocation, Prefs.downloadRemoval,
                                   Prefs.openSafeFiles, Prefs.historyKeep])
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(title: "Toolbar") {
                PrefRow(label: "Address bar") {
                    Picker("", selection: $toolbar) {
                        Text("Above the page").tag(true)
                        Text("In the sidebar").tag(false)
                    }
                    .labelsHidden().fixedSize()
                }
                PrefHint(toolbar ? "Back, forward, the address and extension buttons sit in a bar above the page, in the site’s color." : "The address sits at the bottom of the sidebar, like in Arc.")
            }
            PrefSection(title: "Tab Layout") {
                PrefRow(label: "Pinned sidebar style") {
                    Picker("", selection: $sidebarStyle) {
                        Text("Attached").tag("attached")
                        Text("Floating").tag("floating")
                    }
                    .labelsHidden().fixedSize()
                }
                PrefHint(sidebarStyle == "attached" ? "The page overlaps the sidebar; the active tab bridges into the page." : "The sidebar is a card above the page; the window takes the site’s color.")
                PrefRow(label: "Compact sidebar") {
                    Text("Drag the sidebar edge all the way left, or ⌥⌘S").foregroundStyle(.secondary)
                }
            }
            PrefSection(title: "Top Bar") {
                PrefRow(label: "Floating top bar") {
                    Toggle("Show at the top edge when the address bar is hidden", isOn: $topBar)
                }
                PrefRow(label: "") {
                    Toggle("Show a strip where it hides", isOn: $topBarStrip).disabled(!topBar)
                }
                PrefHint(topBarStrip ? "The strip also shows page loading. Point at it or at the top edge to open the bar." : "Nothing at the top edge except page loading. Point at the top edge to open the bar.")
            }
            PrefSection(title: "Split View") {
                PrefRow(label: "Page address") {
                    Picker("", selection: $chipCenter) {
                        Text("Top center").tag(true)
                        Text("Top right").tag(false)
                    }
                    .labelsHidden().fixedSize()
                }
                PrefHint("Appears when the pointer nears the top edge of a pane. Drag it to the sidebar, onto another pane or out of the window.")
            }

        }
    }

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(title: "Archive") {
                PrefRow(label: "Archive unpinned tabs after") {
                    Picker("", selection: $archiveAfter) {
                        Text("12 hours").tag(12 * 3600.0)
                        Text("1 day").tag(24 * 3600.0)
                        Text("7 days").tag(7 * 24 * 3600.0)
                        Text("30 days").tag(30 * 24 * 3600.0)
                        Text("Never").tag(0.0)
                    }
                    .labelsHidden().fixedSize()
                }
                PrefRow(label: "Count time") {
                    Picker("", selection: $archiveClock) {
                        Text("Only while you’re at the Mac").tag(true)
                        Text("Always").tag(false)
                    }
                    .labelsHidden().fixedSize()
                    .disabled(archiveAfter == 0)
                }
                PrefHint((archiveClock ? "Nights, weekends and time away don’t count — tabs don’t vanish while you’re gone. " : "")
                         + "Tabs in folders, pinned and playing tabs stay. A red dot marks tabs leaving within an hour. Find archived tabs with ⇧⌘A.")
            }
            PrefSection(title: "Links") {
                PrefRow(label: "⌘-click opens a link") {
                    Toggle("In a new tab and switches to it", isOn: $newTabActive)
                }
                PrefHint(newTabActive ? "⌘⇧-click opens it in the background. ⌥⌘-click opens it in a little window."
                                      : "In a background tab; ⌘⇧-click switches to it. ⌥⌘-click opens it in a little window.")
            }
            PrefSection(title: "Pinned Tabs") {
                PrefRow(label: "Links to other sites") {
                    Toggle("Open in Peek", isOn: $peekPinned)
                }
                PrefHint("A link from a pinned tab to another site opens as a card above the page. Esc closes it; keep it as a tab or put it in split.")
                PrefRow(label: "After sleep and relaunch") {
                    Toggle("Keep the last opened page", isOn: $pinnedRemember)
                }
                PrefHint(pinnedRemember ? "A pinned tab stays where you left it. ⌘W still takes it back to its pinned address."
                                        : "A pinned tab goes back to its pinned address when it sleeps, closes or Sapfire relaunches.")
            }
            PrefSection(title: "Memory") {
                PrefRow(label: "Sleeping tabs") {
                    Toggle("Put background tabs to sleep", isOn: Binding(
                        get: { sleepMinutes > 0 },
                        set: { on in
                            if on { sleepMinutes = max(1, sleepLast) } else { sleepLast = sleepMinutes; sleepMinutes = 0 }
                        }))
                }
                if sleepMinutes > 0 {
                    PrefRow(label: "After") {
                        HStack(spacing: 6) {
                            TextField("", value: Binding(
                                get: { Int(sleepMinutes) },
                                set: { sleepMinutes = Double(min(max($0, 1), 1440)) }), format: .number)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 48)
                            Stepper("", value: Binding(
                                get: { Int(sleepMinutes) },
                                set: { sleepMinutes = Double($0) }), in: 1...1440)
                                .labelsHidden()
                            Text(Int(sleepMinutes) == 1 ? "minute" : "minutes")
                        }
                    }
                }
                PrefHint(sleepMinutes == 0
                         ? "Background tabs keep running and use memory and battery."
                         : "A sleeping tab frees its memory and reloads when you open it, keeping scroll position, back history and text you typed. Tabs playing video or sound and auto-reloading tabs stay awake.")
            }
            PrefSection(title: "Folders") {
                PrefRow(label: "Folder preview") {
                    Stepper("\(peekCount) recent tabs", value: $peekCount, in: 1...15)
                }
            }
            RestoreDefaults(keys: [Prefs.archiveAfter, Prefs.archiveClock, Prefs.sleepAfterMinutes, Prefs.sleepAfterLast, Prefs.folderPeekCount, Prefs.peekPinned, Prefs.pinnedRemember, Prefs.newTabActive,
                                   "sidebarStyle", Prefs.topBar, Prefs.topBarStrip, Prefs.paneChipCenter, Prefs.toolbar])
        }
    }

    private var commandBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(title: "Search Engine") {
                PrefRow(label: "Search engine") {
                    Picker("", selection: $engine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                PrefRow(label: "Incognito search engine") {
                    Picker("", selection: $privateEngine) {
                        Text("Same as above").tag("")
                        Divider()
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                PrefHint("!-commands still work anywhere: “cats !yt”, “!w Blender”.")
            }
            PrefSection(title: "Suggestions") {
                let e = SearchEngine(rawValue: engine) ?? .google
                PrefRow(label: "Search suggestions") {
                    Toggle("From \(e.name)", isOn: $suggestions).disabled(e.suggest == nil)
                }
                PrefHint(e.suggest == nil ? "\(e.name) doesn’t offer suggestions to other apps."
                                          : "What you type is sent to \(e.name) to suggest queries. Never in incognito, never for addresses.")
            }
            PrefSection(title: "Bangs") {
                BangsView()
            }
            RestoreDefaults(keys: [Prefs.searchSuggestions, Prefs.searchEngine, Prefs.privateSearchEngine])
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(title: "Content") {
                PrefRow(label: "Ads and trackers") {
                    Toggle("Block", isOn: Binding(get: { model.adBlockEnabled }, set: { model.adBlockEnabled = $0 }))
                }
                PrefRow(label: "Filter lists") {
                    BlockerListsView()
                }
                PrefHint("Lists update by themselves every few days. Turn blocking off for one site, or allow a single request there, in its settings (gear in the address bar).")
            }
            PrefSection(title: "Your Rules") {
                BlockerRulesView()
            }
            PrefSection(title: "Security") {
                PrefRow(label: "Fraudulent websites") {
                    Toggle("Warn when visiting a fraudulent website", isOn: $fraudWarning)
                }
                PrefRow(label: "Not secure connection") {
                    Toggle("Warn before connecting to a website over HTTP", isOn: $httpWarning)
                }
                PrefRow(label: "Web content") {
                    Toggle("Enable JavaScript", isOn: $javaScript)
                }
                PrefHint(javaScript ? "Turn it off for one site in its settings (gear in the address bar)." : "Most websites won’t work without JavaScript. Applies to pages as they load.")
            }
            PrefSection(title: "Cookies and Website Data") {
                PrefRow(label: "Cookies") {
                    Toggle("Block all cookies", isOn: $blockCookies)
                }
                if blockCookies { PrefHint("Websites won’t be able to keep you signed in or remember settings.") }
                PrefRow(label: "Website data") {
                    Button("Manage Website Data…") { WebsiteDataWindow.show() }
                }
            }
            PrefSection(title: "Tracking") {
                PrefRow(label: "Fingerprinting protection") {
                    Picker("", selection: $fpScope) {
                        ForEach(PrivacyScope.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                PrefHint("Like Safari’s private windows: sites get slightly altered canvas, audio and screen data, so they can’t recognize your Mac. A rare site may notice; applies to pages as they load.")
                PrefRow(label: "Remove tracking from links") {
                    Picker("", selection: $linkScope) {
                        ForEach(PrivacyScope.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                PrefHint("Drops utm_, fbclid, gclid and other labels that ad networks and newsletters add to links to follow you.")
            }
            PrefSection(title: "VPN Proxy") {
                PrefRow(label: "Proxy of your VPN app") {
                    Picker("", selection: $incType) {
                        Text("SOCKS5").tag("socks")
                        Text("HTTP").tag("http")
                    }
                    .labelsHidden().fixedSize()
                    TextField("127.0.0.1", text: $incHost).textFieldStyle(.roundedBorder).frame(width: 120)
                    Text(":").foregroundStyle(.secondary)
                    TextField("10808", value: $incPort, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 64)
                }
                PrefRow(label: "") {
                    Button("Check Connection") {
                        ipCheck = "Checking…"
                        Incognito.reachable { ok in
                            guard ok else { ipCheck = "Nothing answers at \(Incognito.host):\(Incognito.port) — is Happ running?"; return }
                            Incognito.checkIP(viaProxy: true) { via in
                                Incognito.checkIP(viaProxy: false) { direct in
                                    if let via, let direct {
                                        ipCheck = via == direct ? "Sites see \(via) either way — Happ tunnels Sapfire too: TUN for all apps, system proxy, or Sapfire is in Happ’s per-app VPN list."
                                                                : "Through the proxy: \(via) · directly: \(direct)"
                                    } else {
                                        ipCheck = via.map { "Through the proxy: \($0)" } ?? "The proxy answers, but pages don’t load through it"
                                    }
                                }
                            }
                        }
                    }
                    if let ipCheck { Text(ipCheck).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                PrefHint("Used by incognito and by profiles you send through the tunnel (Profiles). In Happ use Proxy mode, or Mixed with per-app routing that leaves Sapfire out of the VPN (SOCKS5 is usually 10808, HTTP 10809). If the proxy is off, their pages don’t load: nothing goes around the tunnel.")
            }
            PrefSection(title: "Incognito") {
                PrefRow(label: "Network") {
                    Toggle("Only through the VPN proxy", isOn: $incProxy)
                }
                PrefRow(label: "Lock") {
                    Toggle("Require Touch ID to view incognito", isOn: $incLock)
                }
                PrefHint("Locks when your Mac locks or sleeps, or Sapfire has been in the background for 5 minutes. Spaces → Lock Incognito locks it right away.")
                PrefRow(label: "") {
                    Toggle("Only when nobody is at the Mac", isOn: $incLockIdle).disabled(!incLock)
                }
                PrefHint("While you keep using the Mac — a video from incognito playing in the background, for example — it stays open. The 5 minutes count from your last click or keystroke.")
                PrefRow(label: "Always") {
                    Text("No WebRTC, nothing written to disk, extensions stay out").foregroundStyle(.secondary)
                }
                PrefHint("Closing incognito erases its cookies, site data, cache, icons, site settings, closed tabs and downloads list. Downloaded files stay where you saved them. Search engine for incognito — in Search.")
            }
            PrefSection(title: "History") {
                PrefRow(label: "History") {
                    Button("Clear History…") {
                        let a = NSAlert()
                        a.messageText = "Clear all history?"
                        a.informativeText = "Visited pages will be forgotten. Open tabs stay."
                        a.addButton(withTitle: "Clear")
                        a.addButton(withTitle: "Cancel")
                        if a.runModal() == .alertFirstButtonReturn { HistoryStore.shared.clear() }
                    }
                }
                PrefHint("Incognito is never written to history. Browse history with ⌘Y.")
            }
            RestoreDefaults(keys: [Prefs.fraudWarning, Prefs.httpWarning, Prefs.javaScript, Prefs.blockAllCookies])
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(title: "Address") {
                PrefRow(label: "Smart search field") {
                    Toggle("Show full website address", isOn: $fullAddress)
                }
            }
            PrefSection(title: "Accessibility") {
                PrefRow(label: "Font size") {
                    Toggle("Never use font sizes smaller than", isOn: Binding(get: { minFontSize > 0 }, set: { minFontSize = $0 ? 9 : 0 }))
                    Picker("", selection: $minFontSize) {
                        ForEach([9, 10, 11, 12, 14, 18, 24], id: \.self) { Text("\($0)").tag($0) }
                        if minFontSize == 0 { Text("9").tag(0) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(minFontSize == 0)
                }
                PrefRow(label: "") {
                    Toggle("Press Tab to highlight each item on a webpage", isOn: $tabHighlights)
                }
                PrefHint("Otherwise Tab moves only between text fields and pop-up menus.")
            }
            PrefSection(title: "Style Sheet") {
                PrefRow(label: "Style sheet") {
                    Picker("", selection: Binding(get: { styleSheet }, set: { v in
                        if v == "choose" { chooseStyleSheet() } else { styleSheet = v }
                    })) {
                        Text("None Selected").tag("")
                        if !styleSheet.isEmpty { Text((styleSheet as NSString).lastPathComponent).tag(styleSheet) }
                        Divider()
                        Text("Other…").tag("choose")
                    }
                    .labelsHidden().fixedSize()
                }
                PrefHint("Your own CSS, applied to every website. Change the file and pick it again to update.")
            }
            PrefSection(title: "Summarize") {
                PrefRow(label: "Gemini key") {
                    if sumHasKey {
                        Label("Saved in Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Remove") { Summarizer.setKey(nil); sumHasKey = false; sumModels = [] }
                    } else {
                        SecureField("Paste the key", text: $sumKey).textFieldStyle(.roundedBorder).frame(width: 220)
                        Button("Save") {
                            Summarizer.setKey(sumKey); sumKey = ""; sumHasKey = Summarizer.hasKey
                            Summarizer.fetchModels { sumModels = $0 }
                        }
                        .disabled(sumKey.trimmingCharacters(in: .whitespaces).count < 20)
                        Button("Get a Free Key") { if let u = URL(string: "https://aistudio.google.com/apikey") { BrowserModel.current.newTab(url: u) } }
                    }
                }
                Text("With a free key Google may use the pages you summarize to train its models; a key from a billed project keeps them private.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                PrefRow(label: "Model") {
                    Picker("", selection: $sumModel) {
                        ForEach(Array(Set(sumModels + [sumModel])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .onAppear { if sumHasKey && sumModels.isEmpty { Summarizer.fetchModels { sumModels = $0 } } }
                }
                PrefRow(label: "Language") {
                    Picker("", selection: $sumLang) {
                        ForEach(Summarizer.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden().fixedSize()
                }
                PrefRow(label: "") {
                    Toggle("Through the VPN proxy", isOn: $sumProxy)
                }
                PrefHint("⌥⌘U, ⋯ → Summarize Page, or right-click the page. With text selected — only the selection. The page text goes to Google; off in incognito. Gemini isn’t available directly in some countries — then keep the proxy on and Happ running (Privacy → VPN Proxy).")
            }
            PrefSection(title: "Network") {
                PrefRow(label: "Proxies") {
                    Button("Change Settings…") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") { NSWorkspace.shared.open(u) }
                    }
                }
                PrefHint("Sapfire uses the proxies set for your network in System Settings → Network → Details → Proxies.")
            }
            RestoreDefaults(keys: [Prefs.fullAddress, Prefs.minFontSize, Prefs.tabHighlights, Prefs.styleSheet])
        }
    }

    private func chooseDownloadFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Select"
        if p.runModal() == .OK, let u = p.url { downloadFolder = u.path; downloadLocation = "custom" }
    }

    private func chooseStyleSheet() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "css") ?? .plainText]
        p.prompt = "Select"
        if p.runModal() == .OK, let u = p.url {
            styleSheet = u.path
            WebEngine.reloadStyleSheet()          // тот же файл выбрали снова — перечитать
        }
    }

    private var spaces: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(title: "Profiles") {
                // Таблица блоками: профиль — шапка (имя, дорога в сеть, меню), под ней его пространства
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.profiles) { p in profileBlock(p) }
                }
                .id(tunnelTick)
                PrefRow(label: "") {
                    Button("New Profile…") { model.newProfile(); tunnelTick += 1 }
                }
                PrefHint("A profile is a person or a role: its own cookies, sign-ins and site data. Spaces of one profile share sign-ins. Any tab can open with another profile: right-click → Reopen As / Open Link As.")
            }
            PrefSection(title: "Network") {
                PrefRow(label: "WebRTC") {
                    Toggle("Off in profiles through the proxy", isOn: $tunnelNoRTC)
                }
                PrefHint("A profile through the VPN proxy: its spaces, search suggestions and site icons go through your VPN app; the rest — directly. Its spaces get a shield on their icon. WebRTC (video calls in the browser) goes around the proxy and would show your real address — keep it off unless you need calls there. The proxy address — Privacy → VPN Proxy.")
            }
        }
    }

    /// Блок профиля: шапка и его пространства
    private func profileBlock(_ p: Profile) -> some View {
        let own = model.spaces.filter { !$0.isIncognito && $0.profileID == p.id }
        let others = model.profiles.filter { $0.id != p.id }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(p.color).frame(width: 10, height: 10)
                Text(p.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Picker("", selection: Binding(get: { Tunnel.isOn(p.id) }, set: { Tunnel.set(p.id, $0); tunnelTick += 1 })) {
                    Text("Directly").tag(false)
                    Text("Through VPN").tag(true)
                }
                .labelsHidden().fixedSize().controlSize(.small)
                Menu {
                    Button("Rename…") { model.renameProfile(p); tunnelTick += 1 }
                    if !p.isPrimary {
                        Divider()
                        Button("Delete Profile…") { model.deleteProfile(p); tunnelTick += 1 }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 12).frame(height: 38)
            Divider().opacity(0.6)
            if own.isEmpty {
                Text("No spaces — use it for single tabs with Open As")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).frame(height: 32)
            } else {
                ForEach(own) { sp in
                    HStack(spacing: 8) {
                        Image(systemName: sp.icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                        Text(sp.name).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 8)
                        if !others.isEmpty {
                            Menu {
                                ForEach(others) { o in Button(o.name) { model.setProfile(sp, o); tunnelTick += 1 } }
                                Divider()
                                Button("New Profile…") { model.newProfile(for: sp); tunnelTick += 1 }
                            } label: { Text("Move to…").font(.system(size: 12)) }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                    .padding(.horizontal, 12).frame(height: 30)
                }
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .circular))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .circular).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var gesturesPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(title: "Two Fingers") {
                PrefRow(label: "On the page") {
                    Toggle("Swipe to go back and forward", isOn: $twoPages)
                }
                PrefRow(label: "On the sidebar") {
                    Toggle("Swipe to switch spaces", isOn: $twoSpaces)
                }
                PrefRow(label: "At the top edge") {
                    Toggle("Swipe to move the window", isOn: $twoWindow)
                }
            }
            PrefSection(title: "Three Fingers") {
                PrefRow(label: "Three-finger gestures") {
                    Toggle("On", isOn: $gestures)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(GestureID.allCases, id: \.self) { GestureRow(gesture: $0, labelWidth: labelWidth) }
                }
                .id(gestureTick)
                .disabled(!gestures)
                .opacity(gestures ? 1 : 0.4)
                PrefHint("Any action from Shortcuts, or Nothing. If macOS also reacts to these gestures, switch its swipes to four fingers in System Settings → Trackpad → More Gestures, and turn off “Look up & data detectors: Tap with three fingers” in Point & Click.")
            }
            HStack {
                Spacer()
                Button("Restore Defaults") {
                    for k in [Prefs.threeFingerGestures, Prefs.twoFingerPages, Prefs.twoFingerSpaces, Prefs.twoFingerWindow] {
                        UserDefaults.standard.removeObject(forKey: k)
                    }
                    Gestures.reset()
                    gestureTick += 1
                }
            }
            .padding(.top, 4)
        }
    }

    private var shortcuts: some View { ShortcutsPage() }
}

private struct GestureHint: View {
    let arrow: String
    let text: String
    var fingers = 3
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 1) {
                ForEach(0..<fingers, id: \.self) { _ in Circle().frame(width: 4, height: 4) }
            }
            .frame(width: 14, alignment: .leading)
            .foregroundStyle(.secondary)
            Image(systemName: arrow).font(.system(size: 11, weight: .semibold)).frame(width: 14)
            Text(text).font(.system(size: 12))
        }
    }
}

// MARK: - Жесты тремя пальцами

/// Следим за касаниями трекпада: три пальца сдвинулись достаточно — одно действие за жест.
final class ThreeFingerGestures {
    static let shared = ThreeFingerGestures()
    private var monitor: Any?
    private var start: CGPoint?
    private var fired = false
    /// Пальцев было больше трёх — жест не считается до полного отрыва (иначе три оставшихся при отрыве дали бы свайп)
    private var blocked = false
    private var began: Date?
    private var moved: CGFloat = 0
    /// Сколько пальцев было на трекпаде в прошлый раз и могут ли эти три пальца быть тапом
    private var lastCount = 0
    private var tapCandidate = false
    /// Когда первый палец коснулся трекпада (пальцы тапа ложатся не разом — с разницей в доли секунды)
    private var touchDown: Date?
    /// Когда последний раз шла прокрутка (двумя пальцами) — во время неё тапа нет
    static var lastScroll = Date.distantPast

    func start(model: BrowserModel) {
        guard monitor == nil else { return }
        // Касания приходят, только если окно их принимает
        for w in NSApp.windows { w.contentView?.allowedTouchTypes.insert(.indirect) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .gesture) { [weak self] e in
            // Жест — в том окне, где работают
            self?.handle(e, model: BrowserModel.current)
            return e
        }
    }

    /// Сколько пальцев на трекпаде и три соседних из них (если есть).
    /// Лежащие касания (ладонь, большой палец на краю) не считаются; три касания — «три пальца»,
    /// только если между крайними из них не больше ~55 мм. Иначе (два пальца и ладонь) — это два пальца.
    static func fingers(_ all: Set<NSTouch>) -> (Int, [NSTouch]?) {
        let ts = Array(all.filter { !$0.isResting })
        guard ts.count >= 3 else { return (ts.count, nil) }
        var size = ts[0].deviceSize                          // в пунктах (1/72 дюйма)
        if size.width < 1 || size.height < 1 { size = CGSize(width: 453, height: 283) }   // ~160×100 мм
        func d(_ a: NSTouch, _ b: NSTouch) -> CGFloat {
            hypot((a.normalizedPosition.x - b.normalizedPosition.x) * size.width,
                  (a.normalizedPosition.y - b.normalizedPosition.y) * size.height)
        }
        var best: (trio: [NSTouch], span: CGFloat)?
        for i in 0..<ts.count { for j in (i + 1)..<ts.count { for k in (j + 1)..<ts.count {
            let span = max(d(ts[i], ts[j]), d(ts[i], ts[k]), d(ts[j], ts[k]))
            if best == nil || span < best!.span { best = ([ts[i], ts[j], ts[k]], span) }
        } } }
        let maxSpan: CGFloat = 55 * 72 / 25.4
        // Четыре-пять пальцев рядом — это не три пальца (тап четырьмя/пятью — не наш жест).
        // Далёкое четвёртое касание (ладонь у края) не в счёт — тогда берём три соседних
        if ts.count >= 4 {
            var all: CGFloat = 0
            for i in 0..<ts.count { for j in (i + 1)..<ts.count { all = max(all, d(ts[i], ts[j])) } }
            if all <= 85 * 72 / 25.4 { return (ts.count, nil) }
        }
        if let b = best, b.span <= maxSpan { return (3, b.trio) }
        return (2, nil)
    }

    private func handle(_ e: NSEvent, model: BrowserModel) {
        guard UserDefaults.standard.object(forKey: Prefs.threeFingerGestures) as? Bool ?? true else { return }
        // Только из окон браузера: касания в настройках и других окнах — не жесты по вкладкам
        // Не из настроек и маленького окна: там жесты по вкладкам не нужны (главное окно — SwiftUI-окно, его не трогаем)
        if e.window is SettingsWindow || e.window is LittleWindow { return }
        let active = e.allTouches().filter { $0.phase != .ended && $0.phase != .cancelled }
        // Пальцы — без лежащей ладони; «три пальца» — три касания рядом (ладонь у края не в счёт,
        // а из четырёх касаний годятся три соседних)
        let (count, trio) = Self.fingers(active)
        let prev = lastCount
        lastCount = count
        // Пальцев стало больше трёх — этот жест уже не тап и не свайп тремя пальцами, до полного отрыва
        if count > 3 { tapCandidate = false; fired = true; began = nil; blocked = true }
        // Тап — только если три пальца легли почти вместе (а не добавились к прокрутке двумя) и страница не прокручивалась
        if prev == 0 && count > 0 { touchDown = Date() }
        if count == 0 { touchDown = nil; blocked = false }
        // Пальцы тапа ложатся почти вместе: третий — не позже ~0.18 с после первого (иначе это палец, добавленный к прокрутке)
        if count == 3 && prev < 3 {
            let together = prev == 0 || (touchDown.map { Date().timeIntervalSince($0) < 0.18 } ?? false)
            tapCandidate = together && Date().timeIntervalSince(Self.lastScroll) > 0.3
        }
        guard count == 3, let touches = trio else {
            // Три пальца коснулись и почти сразу отпустили, не сдвигаясь — это тап
            if count < 3, !blocked, let b = began, !fired, tapCandidate, moved < 0.04, Date().timeIntervalSince(b) < 0.45,
               Date().timeIntervalSince(Self.lastScroll) > 0.2 {
                began = nil
                tapCandidate = false
                if let action = Gestures.action(.tap) { DispatchQueue.main.async { Shortcuts.run(action, model) } }
            }
            if count < 2 { start = nil; fired = false; began = nil; moved = 0 }
            else if count < 3 { began = nil }
            return
        }
        guard !blocked else { return }
        let c = touches.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.normalizedPosition.x / 3, y: $0.y + $1.normalizedPosition.y / 3) }
        guard let s = start else { start = c; fired = false; began = Date(); moved = 0; return }
        guard !fired else { return }
        let dx = c.x - s.x, dy = c.y - s.y          // доли ширины/высоты трекпада, y — вверх
        moved = max(moved, max(abs(dx), abs(dy)))
        let limit: CGFloat = 0.14
        guard max(abs(dx), abs(dy)) > limit else { return }
        fired = true
        // Какое действие назначено этому жесту (Settings → Gestures)
        let g: GestureID = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .up : .down)
        guard let action = Gestures.action(g) else { return }
        DispatchQueue.main.async {
            Shortcuts.run(action, model)
            Tour.shared.mark(.gestures)
            if action == .closeTab { model.showToast("Tab closed") }
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
    }
}

/// Прокрутка без размытого края (в macOS 26 обычная размывает заголовок над ней).
/// Высота страницы считается под текущую ширину окна — подписи переносятся, верх не обрезается.
private struct PlainScroll<Content: View>: NSViewRepresentable {
    let content: Content

    final class Flipped: NSClipView { override var isFlipped: Bool { true } }
    final class Doc: NSView { override var isFlipped: Bool { true } }
    /// Содержимое поменяло высоту (появилась подсказка, раскрылся список) — пересчитать
    final class Host: NSHostingView<AnyView> {
        var changed: (() -> Void)?
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { self.changed?() }
        }
    }

    final class Coordinator {
        var content: Content
        weak var scroll: NSScrollView?
        var host: Host?
        var width: CGFloat = -1
        init(_ c: Content) { content = c }

        var height: CGFloat = 0

        func relayout(force: Bool = false) {
            guard let sv = scroll, let host else { return }
            let w = sv.contentView.bounds.width
            guard w > 0 else { return }
            if force || w != width {
                width = w
                // Содержимое сообщает свою высоту само (поиск сократил список — страница сразу короче)
                host.rootView = AnyView(content
                    .frame(width: w)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { self.setHeight(g.size.height) }
                            .onChange(of: g.size.height) { _, h in self.setHeight(h) }
                    })
                    .frame(maxHeight: .infinity, alignment: .top))
            }
            if height == 0 { height = host.fittingSize.height }
            place()
        }

        func setHeight(_ h: CGFloat) {
            guard h != height else { return }
            height = h
            DispatchQueue.main.async { self.place() }
        }

        private func place() {
            guard let sv = scroll, let host, let doc = sv.documentView, width > 0 else { return }
            let h = max(height, sv.contentView.bounds.height)
            host.frame = NSRect(x: 0, y: 0, width: width, height: h)
            doc.frame = NSRect(x: 0, y: 0, width: width, height: h)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(content) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay         // полоса прокрутки поверх — не съедает правый отступ
        sv.drawsBackground = false
        sv.automaticallyAdjustsContentInsets = false
        sv.contentInsets = NSEdgeInsets()
        let clip = Flipped()
        clip.drawsBackground = false
        clip.postsFrameChangedNotifications = true
        sv.contentView = clip
        let doc = Doc()
        let host = Host(rootView: AnyView(EmptyView()))
        doc.addSubview(host)
        sv.documentView = doc
        let c = context.coordinator
        c.scroll = sv; c.host = host
        host.changed = { [weak c] in c?.relayout() }
        // Переход к разделу (поиск, стрелки) — прокрутить к его заголовку
        SettingsNav.shared.scroll = { [weak sv, weak clip] y in
            guard let sv, let clip, let doc = sv.documentView else { return }
            let maxY = max(0, doc.frame.height - clip.bounds.height)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: min(y, maxY)))
            }
            sv.reflectScrolledClipView(clip)
        }
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak c] _ in c?.relayout() }
        DispatchQueue.main.async { c.relayout(force: true) }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.content = content
        context.coordinator.relayout(force: true)
    }
}

// MARK: - Websites: все сайты со своими настройками

/// Как в Safari → Websites: сайты, у которых что-то настроено (через шестерёнку в адресной строке), —
/// что именно изменено, и сброс.
/// Окно настроек (⌘,): обычное окно — тянется, помнит размер и место
final class SettingsWindow: NSWindow {
    private static var shared: SettingsWindow?

    static func show(page: SettingsPage) {
        SettingsNav.shared.requested = page
        show()
    }

    static func show() {
        if let w = shared { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 572),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 680, height: 420)
        // Светофор — свой (в SettingsView), системный прячем
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
        w.contentView = NSHostingView(rootView: SettingsView().environment(BrowserModel.primary).background(WindowCorner()))
        w.center()
        w.setFrameAutosaveName("SapfireSettings")
        shared = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}


// MARK: - Блокировщик: списки, свои правила, разрешённое

/// Списки фильтров: включить / выключить каждый, когда обновлялся, обновить сейчас
private struct BlockerListsView: View {
    @State private var prefs = BlockerPrefs.shared
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: Binding(get: { prefs.isOn(BlockerPrefs.builtinID) }, set: { prefs.setOn(BlockerPrefs.builtinID, $0) })) {
                HStack(spacing: 6) {
                    Text("Built-in").font(.system(size: 12))
                    Text("the biggest ad and tracking networks").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ForEach(FilterLists.sources, id: \.id) { src in
                let t = UserDefaults.standard.double(forKey: "filters.updated." + src.id)
                Toggle(isOn: Binding(get: { prefs.isOn(src.id) }, set: { prefs.setOn(src.id, $0) })) {
                    HStack(spacing: 6) {
                        Text(src.name).font(.system(size: 12))
                        Text(Self.about[src.id] ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("· " + (t > 0 ? Date(timeIntervalSince1970: t).formatted(.relative(presentation: .named)) : "not loaded yet"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
            // YouTube: сетевые правила там ломают плеер — рекламу убирает скрипт по свежим правилам uBlock Origin
            let yt = UserDefaults.standard.double(forKey: UBOYouTube.updatedKey)
            Toggle(isOn: Binding(get: { prefs.isOn(UBOYouTube.id) }, set: { prefs.setOn(UBOYouTube.id, $0) })) {
                HStack(spacing: 6) {
                    Text("YouTube").font(.system(size: 12))
                    Text("video ads, fixes from uBlock Origin").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("· " + (yt > 0 ? Date(timeIntervalSince1970: yt).formatted(.relative(presentation: .named)) : "built-in"))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Toggle(isOn: Binding(get: { prefs.genericHiding }, set: { prefs.genericHiding = $0; tick += 1 })) {
                HStack(spacing: 6) {
                    Text("Hide ad placeholders on every site").font(.system(size: 12))
                    Text("thousands of extra style rules on each page — pages get noticeably slower").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            Button("Update Now") { FilterLists.shared.updateIfNeeded(force: true) }
                .controlSize(.small)
        }
        .id(tick)
    }

    private static let about = ["easylist": "ads", "easyprivacy": "trackers and analytics", "ruadlist": "ads on Russian sites — on by default when the Mac speaks Russian",
                                "cookies": "cookie consent banners"]
}

/// Свои правила (как в Adblock Plus / uBlock) и всё, что разрешено на отдельных сайтах
private struct BlockerRulesView: View {
    @State private var prefs = BlockerPrefs.shared
    @State private var text = BlockerPrefs.shared.custom

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 110)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .circular))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("||ads.example.com^\n@@||cdn.example.com^$domain=site.com")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: text) { _, v in prefs.setCustom(v) }
            PrefHint("One rule per line, like in Adblock Plus or uBlock: “||site.com^” blocks a site, “@@” in front allows it, “$domain=” limits the rule to some sites. Applies in a couple of seconds, to pages as they load.")
            let allows = prefs.allows
            if !allows.isEmpty {
                Text("Allowed on sites").font(.system(size: 12, weight: .semibold)).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(allows) { a in
                        HStack(spacing: 6) {
                            Text(a.host).font(.system(size: 12))
                            Text("on " + a.site).font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Block Again") { prefs.removeAllow(a) }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
    }
}


/// Settings → Search → Bangs: !-команды строками-капсулами — ключ, название, адрес с %s; свои добавляются
private struct BangsView: View {
    @State private var store = BangStore.shared
    @State private var query = ""
    /// Только что добавленная — её ключ сразу в правке
    @FocusState private var focus: UUID?

    var body: some View {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let list = store.list.filter { q.isEmpty || $0.key.contains(q) || $0.name.lowercased().contains(q) || $0.template.lowercased().contains(q) }
        VStack(alignment: .leading, spacing: Metrics.inset) {
            Text("Type “!yt cats” or “cats !yt” in the command bar. Unknown ones go to DuckDuckGo, which knows thousands more.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Metrics.inset) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Search bangs", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 10).frame(height: BangRow.height)
                .background(Color.primary.opacity(Metrics.blockShade), in: Capsule())
                Button("Add Bang") { query = ""; focus = store.add().id }.controlSize(.small)
                if store.customized {
                    Button("Restore Built-in…") {
                        let a = NSAlert()
                        a.messageText = "Restore the built-in bangs?"
                        a.informativeText = "Your own bangs and changes will be removed."
                        a.addButton(withTitle: "Restore")
                        a.addButton(withTitle: "Cancel")
                        if a.runModal() == .alertFirstButtonReturn { store.restore() }
                    }
                    .controlSize(.small)
                }
            }
            VStack(spacing: Metrics.inset / 2) {
                ForEach(list) { b in BangRow(bang: b, focus: $focus) }
            }
            if list.isEmpty {
                Text("Nothing found").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
        }
    }
}

private struct BangRow: View {
    let bang: Bang
    var focus: FocusState<UUID?>.Binding
    @State private var store = BangStore.shared
    @State private var key = ""
    @State private var name = ""
    @State private var template = ""
    @State private var hover = false
    /// Капсула строки; значок внутри — круг на отступе inset (концентричен капсуле)
    static let height: CGFloat = 28

    var body: some View {
        let problem = store.problem(bang)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Favicon(url: URL(string: bang.template.replacingOccurrences(of: "%s", with: "")))
                    .frame(width: Self.height - Metrics.inset * 2, height: Self.height - Metrics.inset * 2)
                HStack(spacing: 0) {
                    Text("!").foregroundStyle(.secondary)
                    TextField("key", text: $key)
                        .focused(focus, equals: bang.id)
                        .onSubmit(commit)
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 64, alignment: .leading)
                TextField("Name", text: $name)
                    .onSubmit(commit)
                    .font(.system(size: 12))
                    .frame(width: 120, alignment: .leading)
                TextField("https://site.com/search?q=%s", text: $template)
                    .onSubmit(commit)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button { store.remove(bang) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: Self.height - Metrics.inset * 2, height: Self.height - Metrics.inset * 2)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hover ? 1 : 0)
                .help("Delete !\(bang.key)")
            }
            .textFieldStyle(.plain)
            .padding(.horizontal, Metrics.inset)
            .frame(height: Self.height)
            .background(Color.primary.opacity(hover ? Metrics.blockShade : 0), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.red.opacity(problem == nil ? 0 : 0.6), lineWidth: 1))
            .onHover { hover = $0 }
            if let problem {
                Text(problem).font(.system(size: 10.5)).foregroundStyle(.red).padding(.leading, Self.height)
            }
        }
        .onAppear { key = bang.key; name = bang.name; template = bang.template }
        .onChange(of: bang) { key = bang.key; name = bang.name; template = bang.template }
        // Правка сохраняется, как только ушёл из поля (и по ↩)
        .onChange(of: focus.wrappedValue) { commit() }
        .onChange(of: key) { commitSoon() }
        .onChange(of: name) { commitSoon() }
        .onChange(of: template) { commitSoon() }
    }

    @State private var work: DispatchWorkItem?
    private func commitSoon() {
        work?.cancel()
        let w = DispatchWorkItem { commit() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    private func commit() {
        var b = bang
        b.key = BangStore.clean(key); b.name = name.trimmingCharacters(in: .whitespaces); b.template = template.trimmingCharacters(in: .whitespaces)
        if b != bang { store.update(b) }
    }
}
