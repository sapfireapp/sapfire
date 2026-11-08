import SwiftUI
import WebKit

// MARK: - Знакомство (Welcome Tour)

/// Тур для нового пользователя: карточка у панели, шаг за шагом — то, чего нет у других браузеров.
/// Каждый шаг можно пропустить («Skip»), пройденный (сделал действие) засчитывается сам.
/// Первый запуск — сам; потом — Help → Welcome Tour. Ключ Gemini в туре не просим: Summarize спросит его при первом пересказе.
@Observable
final class Tour {
    static let shared = Tour()

    enum Step: Int, CaseIterable {
        case spaces, pinned, gestures, undo, split, media, privacy, modules, shortcuts
    }

    private(set) var step: Step?
    /// Действие шага сделано — «Skip» становится «Next», через миг шаг сменится сам
    private(set) var done: Set<Step> = []

    private static let seenKey = "tourSeen"

    /// Сам тур не открывается: его предлагает последний экран первого запуска (Setup), потом — Help → Welcome Tour
    func start() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        done = []
        withAnimation(Self.motion) { step = .spaces }
    }

    func end() { withAnimation(Self.motion) { step = nil } }

    func next() {
        guard let s = step else { return }
        withAnimation(Self.motion) { step = Step(rawValue: s.rawValue + 1) }
    }

    /// Пользователь сделал то, о чём шаг
    func mark(_ s: Step) {
        guard step == s, !done.contains(s) else { return }
        done.insert(s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if self?.step == s { self?.next() }
        }
    }

    /// Действие из Shortcuts.run — какие шаги оно проходит
    func ran(_ id: ShortcutID) {
        guard step != nil else { return }
        switch id {
        case .nextSpace, .prevSpace: mark(.spaces)
        case .pin, .pinned1, .pinned2, .pinned3: mark(.pinned)
        case .undo, .redo, .reopenClosed: mark(.undo)
        case .splitNew: mark(.split)
        default: break
        }
    }

    static let motion = Animation.spring(response: 0.32, dampingFraction: 0.86)
}

/// Размеры карточки тура: от угла карточки — поле и капсулы кнопок концентричны ему
private enum TourMetrics {
    static let width: CGFloat = 360
    static let pad = Metrics.inset
    /// Блок текста внутри карточки и капсулы кнопок: радиус = угол карточки − поле
    static var innerRadius: CGFloat { Metrics.cardRadius - pad }
    static var button: CGFloat { innerRadius * 2 }
    /// Фон карточки — сплошной цвет окна: полупрозрачный брал цвет страницы, и серый текст тонул
    static let fill = Color(nsColor: .windowBackgroundColor)
    /// Второстепенный текст (счётчик, подсказки, клавиши) — плотнее системного .secondary
    static let muted = Color.primary.opacity(0.62)
    /// Подписи жестов в туре: точки + значок + подпись (14 + 10 + 14 + 10 + 90) — строка начинается от кромки текста
    static let gestureLabel: CGFloat = 138
}

/// Карточка тура — внизу слева от страницы, у панели
struct TourOverlay: View {
    @Environment(BrowserModel.self) private var model
    @State private var tour = Tour.shared

    var body: some View {
        if let s = tour.step {
            TourCard(step: s)
                .id(s)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(Metrics.inset)
                .padding(.leading, model.sidebarVisible ? Metrics.sidebarWidth : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .onChange(of: model.currentSpaceID) { tour.mark(.spaces) }
                .onChange(of: model.activeTab?.isPinned) { if model.activeTab?.isPinned == true { tour.mark(.pinned) } }
                .onChange(of: model.currentSpace.splitGroups.count) { o, n in if n > o { tour.mark(.split) } }
        }
    }
}

private struct TourCard: View {
    let step: Tour.Step
    @State private var tour = Tour.shared
    @AppStorage(Prefs.twoFingerSpaces) private var twoSpaces = true
    @AppStorage(Prefs.twoFingerPages) private var twoPages = true
    @AppStorage(Prefs.twoFingerWindow) private var twoWindow = true
    @AppStorage(Prefs.pinnedRemember) private var pinnedRemember = false
    @AppStorage(Prefs.threeFingerGestures) private var gestures = true

    private var count: Int { Tour.Step.allCases.count }
    private var isLast: Bool { step.rawValue == count - 1 }
    private var isDone: Bool { tour.done.contains(step) }

    var body: some View {
        VStack(spacing: TourMetrics.pad) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    if isDone { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).transition(.scale) }
                    Text("\(step.rawValue + 1) of \(count)").font(.system(size: 11)).foregroundStyle(TourMetrics.muted).monospacedDigit()
                }
                Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                controls
                if let off = turnOff {
                    Text(off).font(.system(size: 11)).foregroundStyle(TourMetrics.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(TourMetrics.innerRadius)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sidebarShade(Metrics.blockShade), in: RoundedRectangle(cornerRadius: TourMetrics.innerRadius, style: .circular))
            HStack(spacing: TourMetrics.pad) {
                if !isLast {
                    Button("End Tour") { tour.end() }.buttonStyle(TourButton(prominent: false))
                }
                Spacer(minLength: 0)
                Button(isLast ? "Done" : (isDone ? "Next" : "Skip")) {
                    isLast ? tour.end() : tour.next()
                }
                .buttonStyle(TourButton(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(TourMetrics.pad)
        .frame(width: TourMetrics.width)
        .background(TourMetrics.fill, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .circular))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .circular).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        .animation(Tour.motion, value: isDone)
    }

    private var icon: String {
        switch step {
        case .spaces: "square.stack"
        case .pinned: "pin"
        case .gestures: "hand.draw"
        case .undo: "arrow.uturn.backward"
        case .split: "rectangle.split.2x1"
        case .media: "play.rectangle"
        case .privacy: "hand.raised"
        case .modules: "puzzlepiece"
        case .shortcuts: "keyboard"
        }
    }

    private var title: String {
        switch step {
        case .spaces: "Spaces"
        case .pinned: "Pinned and Temporary Tabs"
        case .gestures: "Gestures"
        case .undo: "Undo for Tabs"
        case .split: "Split View"
        case .media: "Peek and Mini Player"
        case .privacy: "Privacy Built In"
        case .modules: "Modules"
        case .shortcuts: "Shortcuts"
        }
    }

    private var text: String {
        switch step {
        case .spaces: "Each space is its own set of tabs with its own color, and can sign in with its own profile. Swipe two fingers across the sidebar or press ⌥Tab to switch. Right-click a space icon to change its color and icon; right-click a tab → Reopen As to open it with another profile’s sign-ins or in a throwaway container."
        case .pinned: "Pinned tabs come back to their own page after sleep and relaunch; ⌘1…⌘9 open them. Pin this tab with ⇧⌘D. Other tabs are temporary and archive themselves — ⇧⌘A brings them back."
        case .gestures: "Two fingers swipe the page back and forward, switch spaces on the sidebar and move the window at its top edge. Three fingers move between open tabs, close one with a swipe up, undo with a swipe down and tap for the tab overview. Pick any action for each:"
        case .undo: "⌘Z brings back a closed tab, a moved tab or a removed folder; ⇧⌘Z redoes. Try closing a tab and pressing ⌘Z."
        case .split: "Up to four pages side by side. Drag a tab onto the page, or press ⇧⌘E. Drag the gap between pages to resize, right-click it for layouts. ⌥⌘E closes the split."
        case .media: "A link from a pinned tab to another site opens as a card above it. Video from another tab keeps playing in a small player under New Tab — with picture in picture."
        case .privacy: "Ads are blocked, YouTube too. Tracking tags are stripped from links. Incognito goes only through your proxy and locks with Touch ID. Per-site rules — blocker, VPN, profile — are under the gear in the address."
        case .modules: "The core stays light; extras are modules. Turn on what you need:"
        case .shortcuts: "The keys worth remembering:"
        }
    }

    private var turnOff: String? {
        switch step {
        case .shortcuts: "All shortcuts and gestures can be changed in Settings."
        case .spaces: "Hide the sidebar with ⌘S, or make it a narrow column with ⌥⌘S."
        case .pinned: "Archive timing: Settings → Tabs."
        case .gestures: "If macOS also reacts to three fingers, switch its swipes to four fingers in Trackpad settings."
        case .undo: nil
        case .split: nil
        case .media: "Later: Settings → Modules."
        case .privacy: "Turn off later: Settings → Privacy, or per site under the gear."
        case .modules: "Summarize asks for a free Gemini key the first time you use it."
        }
    }

    @ViewBuilder private var controls: some View {
        switch step {
        case .spaces:
            Toggle("Swipe on the sidebar to switch spaces", isOn: $twoSpaces).controlSize(.small)
        case .pinned:
            Toggle("Pinned tabs keep the last opened page", isOn: $pinnedRemember).controlSize(.small)
        case .gestures:
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Swipe the page to go back and forward", isOn: $twoPages).controlSize(.small)
                Toggle("Swipe the sidebar to switch spaces", isOn: $twoSpaces).controlSize(.small)
                Toggle("Swipe the top edge to move the window", isOn: $twoWindow).controlSize(.small)
                Toggle("Three-finger gestures", isOn: $gestures).controlSize(.small)
                ForEach(GestureID.allCases, id: \.self) { GestureRow(gesture: $0, labelWidth: TourMetrics.gestureLabel, flexible: true) }
                    .disabled(!gestures)
                    .opacity(gestures ? 1 : 0.4)
                    .controlSize(.small)
                Button("Trackpad Settings…") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") { NSWorkspace.shared.open(u) }
                }
                .controlSize(.small)
            }
        case .media:
            ModuleToggles(modules: [.peek, .miniPlayer])
        case .modules:
            ModuleToggles(modules: [.summarize, .capture, .tidyTitles, .autoReload, .boosts, .extensions])
        case .shortcuts:
            ShortcutCheatSheet()
        default:
            EmptyView()
        }
    }
}

/// Кнопка тура — капсула высотой в два радиуса (концентрична углу карточки)
private struct TourButton: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, TourMetrics.innerRadius)
            .frame(height: TourMetrics.button)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(sidebarShade(Metrics.blockShade)), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Выключатели модулей — те же ключи, что в Settings → Modules
private struct ModuleToggles: View {
    let modules: [Module]
    @State private var tick = 0
    var body: some View {
        let _ = tick
        VStack(alignment: .leading, spacing: 6) {
            ForEach(modules.filter { !$0.planned }) { m in
                Toggle(isOn: Binding(get: { m.isOn }, set: { on in
                    UserDefaults.standard.set(on, forKey: m.key)
                    tick += 1
                    Modules.changed(m, on)
                })) {
                    Label(m.title, systemImage: m.icon).font(.system(size: 12))
                }
                .controlSize(.small)
            }
        }
    }
}

/// Основные клавиши — по текущим сочетаниям (свои из Settings → Shortcuts тоже)
private struct ShortcutCheatSheet: View {
    /// nil — клавиша не настраивается (⌃Tab перехватывается в AppDelegate)
    private let rows: [(ShortcutID?, String)] = [
        (.newTab, "New tab"), (.closeTab, "Close tab"), (.undo, "Undo tab action"), (.pin, "Pin tab"),
        (nil, "Recent tabs"), (.overview, "Tab overview"), (.nextSpace, "Next space"), (.sidebar, "Sidebar"),
        (.toolbar, "Toolbar"), (.splitNew, "Split"), (.reader, "Reader"), (.translate, "Translate"),
        (.littleWindow, "Little window"), (.incognito, "Incognito"),
    ]
    var body: some View {
        let sc = Shortcuts.shared
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(Array(stride(from: 0, to: rows.count, by: 2)), id: \.self) { i in
                GridRow {
                    cell(rows[i], sc)
                    if i + 1 < rows.count { cell(rows[i + 1], sc) }
                }
            }
        }
        .font(.system(size: 12))
    }

    @ViewBuilder private func cell(_ r: (ShortcutID?, String), _ sc: Shortcuts) -> some View {
        Text(r.0.map { sc.combos($0).first?.text ?? "—" } ?? "⌃Tab").foregroundStyle(TourMetrics.muted).monospaced()
        Text(r.1)
    }
}

// MARK: - Подсказки по случаю

/// Подсказка к месту — уведомлением справа сверху, каждая один раз.
/// Не во время тура и не чаще раза в 10 минут (пропущенная из-за паузы покажется в следующий раз).
enum Tip: String {
    case littleWindow, miniPlayer, article, capture, bang, focus, archive, split
    case folder, passwords, translate, windows, toolbarButtons, stalled
}

enum Tips {
    private static var last = Date.distantPast
    private static let gap: TimeInterval = 10 * 60

    static func shown(_ tip: Tip) -> Bool { UserDefaults.standard.bool(forKey: "tip." + tip.rawValue) }

    static func show(_ tip: Tip, _ m: BrowserModel = .current, text: String? = nil) {
        guard Tour.shared.step == nil, Setup.shared.page == nil, !shown(tip), Date().timeIntervalSince(last) > gap else { return }
        let keys = Shortcuts.shared
        var action: (String, () -> Void)?
        let message: String
        let icon: String
        switch tip {
        case .littleWindow:
            message = "Links from other apps open in a little window. “Open in Sapfire” moves the page into a tab."
            icon = "macwindow"
        case .miniPlayer:
            guard Module.miniPlayer.isOn else { return }
            message = "The video keeps playing in the mini player under New Tab — picture in picture is there too."
            icon = "play.rectangle"
        case .article:
            let summary = Module.summarize.isOn ? ", or a short summary with \(keys.text(.summarize))" : ""
            message = "A long read? Reader mode with \(keys.text(.reader))\(summary)."
            icon = "doc.plaintext"
            action = ("Reader", { Shortcuts.run(.reader, m) })
        case .capture:
            guard Module.capture.isOn else { return }
            message = "Capture Image takes any picture on a page at full size — \(keys.text(.captureImage))."
            icon = "camera.viewfinder"
            action = ("Try", { Shortcuts.run(.captureImage, m) })
        case .bang:
            guard let text else { return }
            message = text
            icon = "magnifyingglass"
        case .focus:
            message = "The address is now in the sidebar; point at the top edge for back, forward and reload. \(keys.text(.toolbar)) brings the bar back."
            icon = "rectangle.topthird.inset.filled"
        case .split:
            message = "Drag the gap between pages to resize them. Right-click it to stack the pages, make a grid or even out the sizes."
            icon = "rectangle.split.2x1"
        case .folder:
            message = "Folders nest up to three levels. Right-click a folder → Make Folder Temporary: it goes to the archive with its tabs when you stop using it."
            icon = "folder"
        case .passwords:
            message = "Saved. Next time Sapfire offers the sign-in right in the field. All passwords, behind Touch ID, and import from Arc or Chrome — Settings → Passwords."
            icon = "key"
        case .translate:
            message = "This page is in another language. \(keys.text(.translate)) translates it right on your Mac."
            icon = "translate"
            action = ("Translate", { Shortcuts.run(.translate, m) })
        case .windows:
            message = "Each window shows its own space. \(keys.text(.floatOnTop)) keeps a window above the others."
            icon = "macwindow.on.rectangle"
        case .toolbarButtons:
            message = "Drag toolbar buttons to reorder them; right-click one to hide it. Hidden ones are in ⋯ → Toolbar Buttons."
            icon = "slider.horizontal.below.rectangle"
        case .stalled:
            message = "The page wasn’t answering, so Sapfire asked again. If pages hang after switching VPN or Wi-Fi — Tab → Reset Network Connections."
            icon = "arrow.clockwise"
        case .archive:
            message = "Temporary tabs you haven’t used for a while went to the archive. \(keys.text(.archive)) brings them back."
            icon = "archivebox"
            action = ("Archive", { Shortcuts.run(.archive, m) })
        }
        UserDefaults.standard.set(true, forKey: "tip." + tip.rawValue)
        last = Date()
        if let (title, run) = action { m.notify(message, icon: icon, action: title, run) } else { m.notify(message, icon: icon) }
    }

    /// Набрали «youtube котики» — подсказать !-команду этого сайта
    static func typed(_ text: String, _ m: BrowserModel) {
        guard !shown(.bang) else { return }
        let words = text.lowercased().split(separator: " ", maxSplits: 1).map(String.init)
        guard words.count == 2, words[1].count >= 2,
              let b = Omnibox.bangs.first(where: { $0.name.lowercased() == words[0] || $0.key.lowercased() == words[0] }) else { return }
        show(.bang, m, text: "Search \(b.name) right away: start with !\(b.key) — for example, !\(b.key) \(words[1]). More in Settings → Search → Bangs.")
    }

    /// Страница догрузилась — длинная статья? (только пока подсказка не показана)
    static func pageLoaded(_ wv: WKWebView, _ m: BrowserModel?) {
        guard let m, m.activeTab?.webView === wv else { return }
        if !shown(.article) {
            let js = "(()=>{const r=document.querySelector('article,main,[role=main]')||document.body;let n=0;r.querySelectorAll('p').forEach(p=>n+=p.innerText.length);return n})()"
            wv.evaluateJavaScript(js) { r, _ in
                if let n = r as? Int, n > 4000, m.activeTab?.webView === wv { show(.article, m) }
            }
        }
        // Страница на чужом языке (по lang документа) и с заметным текстом — подсказать перевод.
        // Сначала дешёвая проверка языка; объём текста (innerText — обход всей страницы) считается только для чужого
        if #available(macOS 15.0, *), !shown(.translate) {
            let mine = Set(Locale.preferredLanguages.map { String($0.prefix(2)).lowercased() })
            let list = mine.map { "'\($0)'" }.joined(separator: ",")
            let js = "(()=>{const l=(document.documentElement.lang||'').slice(0,2).toLowerCase();if(l.length!==2||[\(list)].includes(l))return 0;return (document.body&&document.body.innerText||'').length})()"
            wv.evaluateJavaScript(js) { r, _ in
                if let n = r as? Int, n > 1500, m.activeTab?.webView === wv { show(.translate, m) }
            }
        }
    }
}


// MARK: - Первый запуск (Setup)

/// Первый запуск — четыре экрана, на каждом решение, а не объяснение: откуда переезжаешь (импорт в одно нажатие),
/// вид панели и цвет пространства, браузер по умолчанию; последний — предложение тура (2 минуты) или сразу работать.
/// Только когда истории ещё нет; потом — Help → Set Up Sapfire…
@Observable
final class Setup {
    static let shared = Setup()
    enum Page: Int, CaseIterable { case from, look, browser, ready }

    private(set) var page: Page?
    private static let seenKey = "setupSeen"

    /// Новый человек: истории нет, ни настройку, ни тур ещё не показывали
    func autoStart() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.seenKey), !d.bool(forKey: "tourSeen") else { return }
        d.set(true, forKey: Self.seenKey)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sapfire", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.json").path) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.start() }
    }

    func start() {
        Tour.shared.end()
        withAnimation(Tour.motion) { page = .from }
    }

    func next() {
        guard let p = page else { return }
        withAnimation(Tour.motion) { page = Page(rawValue: p.rawValue + 1) }
    }

    func back() {
        guard let p = page, p.rawValue > 0 else { return }
        withAnimation(Tour.motion) { page = Page(rawValue: p.rawValue - 1) }
    }

    func finish(tour: Bool) {
        withAnimation(Tour.motion) { page = nil }
        if tour { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Tour.shared.start() } }
    }
}

/// Откуда можно переехать: Arc и найденные на Mac браузеры (Safari — всегда, через его файл экспорта)
private struct SetupSource: Identifiable {
    let name: String
    let detail: String
    let bundleID: String?
    let run: () -> Void
    var id: String { name }

    static var all: [SetupSource] {
        var out: [SetupSource] = []
        if ArcImport.available {
            out.append(.init(name: "Arc", detail: "spaces, pinned tabs, folders, history, passwords", bundleID: "company.thebrowser.Browser") { ArcImport.run() })
        }
        let ids = ["Chrome": "com.google.Chrome", "Dia": "company.thebrowser.dia", "Brave": "com.brave.Browser",
                   "Microsoft Edge": "com.microsoft.edgemac", "Vivaldi": "com.vivaldi.Vivaldi", "Opera": "com.operasoftware.Opera",
                   "Chromium": "org.chromium.Chromium", "Yandex Browser": "ru.yandex.desktop.yandex-browser",
                   "Firefox": "org.mozilla.firefox", "Safari": "com.apple.Safari"]
        for s in BrowserImport.sources {
            if case .html = s.kind { continue }
            let what = [s.bookmarks ? "bookmarks" : nil, s.history ? "history" : nil, s.passwords ? "passwords" : nil].compactMap { $0 }
            let detail: String
            if case .safari = s.kind { detail = "from its exported file" } else { detail = what.joined(separator: ", ") }
            out.append(.init(name: s.name, detail: detail, bundleID: ids[s.name]) { BrowserImport.run(preferring: s.name) })
        }
        return out
    }

    var icon: NSImage? {
        guard let b = bundleID, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return nil }
        return NSWorkspace.shared.icon(forFile: u.path)
    }
}

/// Карточка первого запуска — посередине окна поверх затемнения; те же поля, углы и кнопки, что у карточки тура
struct SetupOverlay: View {
    @State private var setup = Setup.shared

    var body: some View {
        if let p = setup.page {
            ZStack {
                Color.black.opacity(0.22).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}                     // страница под затемнением не нажимается
                SetupCard(page: p)
                    .id(p)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
            .transition(.opacity)
        }
    }
}

private struct SetupCard: View {
    let page: Setup.Page
    @State private var setup = Setup.shared
    @Environment(BrowserModel.self) private var model
    @AppStorage("sidebarStyle") private var sidebarStyle = "attached"
    @State private var isDefault = WebEngine.isDefaultBrowser
    @State private var hover: String?
    @State private var tick = 0

    static let width: CGFloat = 440
    private var count: Int { Setup.Page.allCases.count }

    var body: some View {
        VStack(spacing: TourMetrics.pad) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("\(page.rawValue + 1) of \(count)").font(.system(size: 11)).foregroundStyle(TourMetrics.muted).monospacedDigit()
                }
                Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                if page == .look { look }
            }
            .padding(TourMetrics.innerRadius)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sidebarShade(Metrics.blockShade), in: RoundedRectangle(cornerRadius: TourMetrics.innerRadius, style: .circular))
            if page == .from { sources }
            buttons
        }
        .padding(TourMetrics.pad)
        .frame(width: Self.width)
        .background(TourMetrics.fill, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .circular))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .circular).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
    }

    private var title: String {
        switch page {
        case .from: "Where are you coming from?"
        case .look: "Make it yours"
        case .browser: isDefault ? "Sapfire is your default browser" : "Make Sapfire your default browser?"
        case .ready: "You’re set"
        }
    }

    private var text: String {
        switch page {
        case .from: "Bring your tabs, bookmarks, history and passwords. Nothing leaves your Mac. You can also do it later from the File menu."
        case .look: "The sidebar can sit next to the page or float over it as a card. Each space has its own color — pick one for this space now, and change color, icon or gradient later by right-clicking its icon."
        case .browser: isDefault ? "Links from other apps already open in Sapfire — in a little window you can keep as a tab." : "Links from other apps will open in Sapfire — in a little window you can keep as a tab or let go. macOS will ask to confirm."
        case .ready: "⌘T opens anything — a site, a search, an open tab, a setting. Want a two-minute look at what Sapfire does differently? Every step can be skipped."
        }
    }

    // Строки браузеров — капсулы на том же отступе, что текстовый блок (радиус = угол карточки − поле)
    private var sources: some View {
        VStack(spacing: TourMetrics.pad / 2) {
            ForEach(SetupSource.all) { s in
                Button { s.run(); setup.next() } label: {
                    HStack(spacing: 8) {
                        Group {
                            if let i = s.icon { Image(nsImage: i).resizable().interpolation(.high) }
                            else { Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(TourMetrics.muted) }
                        }
                        .frame(width: 16, height: 16)
                        Text(s.name).font(.system(size: 12.5, weight: .medium))
                        Text(s.detail).font(.system(size: 11)).foregroundStyle(TourMetrics.muted).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, TourMetrics.innerRadius - 8)
                    .frame(height: TourMetrics.button)
                    .background(sidebarShade(hover == s.id ? Metrics.blockShade * 2 : Metrics.blockShade), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)            // с управлением с клавиатуры Return иначе нажимал первую строку, а не «Start Fresh»
                .onHover { hover = $0 ? s.id : (hover == s.id ? nil : hover) }
            }
        }
    }

    // Вид панели (меняется сразу) и цвет текущего пространства — кружки на одной сетке
    private var look: some View {
        let _ = tick
        let sp = model.currentSpace
        return VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $sidebarStyle) {
                Text("Floating").tag("floating")
                Text("Attached").tag("attached")
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            HStack(spacing: 8) {
                ForEach([-1.0] + Profile.hues, id: \.self) { h in
                    let on = h < 0 ? sp.colorless : (!sp.colorless && abs(sp.hue - h) < 0.001)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            sp.hue = h; sp.sat = Space.defaultSat; sp.bri = Space.defaultBri; sp.glow = nil
                        }
                        tick += 1
                        model.save()
                    } label: {
                        Circle()
                            .fill(h < 0 ? Color(nsColor: .windowBackgroundColor) : Color(hue: h, saturation: 0.35, brightness: 0.95))
                            .overlay(Circle().strokeBorder(h < 0 ? Color.primary.opacity(0.25) : Color(hue: h, saturation: 0.6, brightness: 0.8), lineWidth: 1))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: on ? 2 : 0).padding(-3))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: TourMetrics.pad) {
            switch page {
            case .from:
                Button("Skip Setup") { setup.finish(tour: false) }.buttonStyle(TourButton(prominent: false)).keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("Start Fresh") { setup.next() }.buttonStyle(TourButton(prominent: true)).keyboardShortcut(.defaultAction)
            case .look:
                Button("Back") { setup.back() }.buttonStyle(TourButton(prominent: false))
                Spacer(minLength: 0)
                Button("Next") { setup.next() }.buttonStyle(TourButton(prominent: true)).keyboardShortcut(.defaultAction)
            case .browser:
                Button("Back") { setup.back() }.buttonStyle(TourButton(prominent: false))
                Spacer(minLength: 0)
                if isDefault {
                    Button("Next") { setup.next() }.buttonStyle(TourButton(prominent: true)).keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") { setup.next() }.buttonStyle(TourButton(prominent: false))
                    Button("Make Default") {
                        // macOS сама спросит подтверждение; дальше — когда ответят
                        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { _ in
                            DispatchQueue.main.async { isDefault = WebEngine.isDefaultBrowser; setup.next() }
                        }
                    }
                    .buttonStyle(TourButton(prominent: true)).keyboardShortcut(.defaultAction)
                }
            case .ready:
                Button("Start Browsing") { setup.finish(tour: false) }.buttonStyle(TourButton(prominent: false)).keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("Take the Tour") { setup.finish(tour: true) }.buttonStyle(TourButton(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
    }
}
