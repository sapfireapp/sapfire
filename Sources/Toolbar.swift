import AppKit
import SwiftUI

// MARK: - Полоса над страницей (как в Safari и Orion)

/// Назад / вперёд / обновить, адрес по центру (с шестерёнкой настроек сайта), справа — кнопки расширений
/// и действий. Полоса — верх самой страницы, в цвет сайта. Выключается в Settings → Tabs:
/// тогда адрес снова внизу сайдбара.
struct PageToolbar: View {
    @Environment(BrowserModel.self) private var model
    /// Центр ряда кнопок — в центре скругления верхних углов окна (там же светофор в сайдбаре)
    static let height: CGFloat = Metrics.windowRadius * 2
    /// «⋯»: точки и поля вокруг них (правая точка — в центре скругления правого верхнего угла)
    static let dot: CGFloat = 3.5, dotGap: CGFloat = 3.5, menuPad: CGFloat = 7

    static var enabled: Bool { UserDefaults.standard.object(forKey: Prefs.toolbar) as? Bool ?? true }

    /// Спрятать полосу (адрес — внизу сайдбара) или вернуть
    static func toggle() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            UserDefaults.standard.set(!enabled, forKey: Prefs.toolbar)
        }
    }

    var body: some View {
        let t = model.activeTab
        // Вкладки нет (пустое пространство) — цвет пустой страницы, а не прошлого сайта
        let bg = t == nil ? NSColor.windowBackgroundColor : t?.pageColor ?? model.lastPageColor ?? .windowBackgroundColor
        let dark = isDark(bg)
        HStack(spacing: 4) {
            // Сайдбар скрыт — светофор и кнопка сайдбара здесь
            if !model.sidebarVisible {
                TrafficLights()
                    .padding(.leading, Metrics.windowRadius - TrafficLights.size / 2)     // первый кружок — в центре скругления
                    .padding(.trailing, 6)
                ToolbarButton(icon: "sidebar.left", help: "Show sidebar — \(Shortcuts.shared.text(.sidebar))") { model.sidebarVisible = true }
            }
            BarRow(capsule: false, dark: dark)
            PageMenu()
        }
        .padding(.leading, model.sidebarVisible ? 10 : 0)
        .padding(.trailing, Metrics.windowRadius - Self.dot / 2 - Self.menuPad)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(WindowDragArea())              // за пустое место полосы окно тащится
        .environment(\.colorScheme, dark ? .dark : .light)
        .background(Color(nsColor: bg))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(dark ? 0.12 : 0.08)).frame(height: 0.5)
        }
    }
}

/// Адрес по центру: шестерёнка — настройки сайта, клик — правка адреса (командная строка)
struct AddressField: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab?
    let dark: Bool
    @State private var siteCenter = false
    @State private var hover = false
    @State private var hoverCopy = false
    @AppStorage(Prefs.fullAddress) private var fullAddress = false

    var body: some View {
        let url = tab?.url
        HStack(spacing: 6) {
            if let t = tab, url?.host != nil {
                Button { siteCenter.toggle() } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 11))
                        .foregroundStyle(url?.scheme == "https" ? Color.secondary : Color.orange)
                        .frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Site settings and privacy")
                .popover(isPresented: $siteCenter, arrowEdge: .bottom) { SiteCenter(tab: t).environment(model).windowScheme() }
                // Пока открыты настройки сайта, капсула сверху не сворачивается
                .onChange(of: siteCenter) { _, open in model.topBarHold = open }
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 18)
            }
            Text(url.map { fullAddress ? $0.absoluteString : Self.short($0) } ?? "Search or enter address")
                .font(.system(size: 13))
                .foregroundStyle(url == nil ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            // Страница переведена — значок; клик возвращает оригинал
            if let t = tab, t.translated {
                Button { PageTranslator.shared.toggle(t) } label: {
                    Image(systemName: "translate").font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Translated — click to show the original")
            }
            // Страница расширения в магазине — поставить одним нажатием
            if ExtensionStore.storeItem(url) != nil {
                Button { Ext.addFromStore(url) } label: {
                    Label("Add to Sapfire", systemImage: "puzzlepiece.extension")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Install this extension in Sapfire")
            }
            // Автообновление включено — значок; по клику — то же меню
            if Module.autoReload.isOn, let t = tab, let s = t.autoReload {
                Button {
                    guard let e = NSApp.currentEvent, let v = e.window?.contentView else { return }
                    AutoReload.menu(for: t).popUp(positioning: nil, at: v.convert(e.locationInWindow, from: nil), in: v)
                } label: {
                    Image(systemName: "timer").font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Auto reload \(AutoReload.label(s))")
            }
            // Скопировать ссылку — в правом краю адреса
            if url != nil {
                Button { model.copyURL() } label: {
                    Image(systemName: "link").font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(hoverCopy ? 0.12 : 0), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .onHover { hoverCopy = $0 }
                .help("Copy link — \(Shortcuts.shared.text(.copyLink))")
            }
        }
        .padding(.leading, 8).padding(.trailing, 3)
        .frame(height: 28)
        .frame(minWidth: 200)
        .background(Color.primary.opacity(hover ? 0.1 : 0.06), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { model.showCommandBar(.current) }
        .onHover { hover = $0 }
        .help("Edit address — \(Shortcuts.shared.text(.openLocation))")
    }

    static func short(_ u: URL) -> String {
        var host = u.host ?? u.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = u.path == "/" ? "" : u.path
        return host + path
    }
}

struct ToolbarButton: View {
    let icon: String
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .offset(SymbolOptics.offset(icon))       // значки — на одной оси (по видимой части, а не по рамке)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(hover && enabled ? 0.1 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// «⋯» — действия со страницей. Своя кнопка (точки рисуем сами — правая точка точно в центре скругления угла),
/// по клику — обычное меню
struct PageMenu: View {
    @Environment(BrowserModel.self) private var model
    @State private var hover = false

    var body: some View {
        Button { show() } label: {
            HStack(spacing: PageToolbar.dotGap) {
                ForEach(0..<3, id: \.self) { _ in Circle().frame(width: PageToolbar.dot, height: PageToolbar.dot) }
            }
            .padding(.horizontal, PageToolbar.menuPad)
            .frame(height: 28)
            .background(Color.primary.opacity(hover ? 0.1 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("More")
    }

    private func show() {
        let m = model
        let t = m.activeTab
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) { menu.addItem(ClosureMenuItem(title, action)) }
        // Страница расширения в Chrome Web Store / Firefox Add-ons — поставить в Sapfire
        if ExtensionStore.storeItem(t?.url) != nil {
            add("Add Extension to Sapfire") { Ext.addFromStore(t?.url) }
            menu.addItem(.separator())
        }
        if Module.summarize.isOn { add("Summarize Page") { Summarizer.shared.start(m) } }
        if Module.capture.isOn { add("Capture Image") { ImageCapture.shared.pick(m) } }
        add("Find on Page") { Shortcuts.run(.find, m) }
        add("Translate Page") { Shortcuts.run(.translate, m) }
        add("Reader") { Shortcuts.run(.reader, m) }
        menu.addItem(.separator())
        add("Zoom In") { Shortcuts.run(.zoomIn, m) }
        add("Zoom Out") { Shortcuts.run(.zoomOut, m) }
        add("Actual Size") { Shortcuts.run(.actualSize, m) }
        menu.addItem(.separator())
        add("Copy Link") { m.copyURL() }
        add("Copy Link as Markdown") { m.copyMarkdown() }
        add("Copy as Quote") { m.copyQuote() }
        add("Share…") { m.share() }
        if let t {
            add(t.isPinned ? "Unpin Tab" : "Pin Tab") { m.togglePin(t) }
            add(t.muted ? "Unmute Tab" : "Mute Tab") { t.muted.toggle() }
            if Module.autoReload.isOn {
                let ar = NSMenuItem(title: "Auto Reload", action: nil, keyEquivalent: "")
                ar.submenu = AutoReload.menu(for: t)
                menu.addItem(ar)
            }
        }
        add("Split with New Tab") { Shortcuts.run(.splitNew, m) }
        menu.addItem(.separator())
        add("Save Page As…") { m.savePage() }
        add("Print…") { m.printPage() }
        menu.addItem(.separator())
        add("Clear Cookies and Reload") { m.clearCookiesAndReload() }
        add("Web Inspector") { m.showInspector() }
        menu.addItem(.separator())
        add(PageToolbar.enabled ? "Hide Toolbar" : "Show Toolbar") { PageToolbar.toggle() }
        let tb = NSMenuItem(title: "Toolbar Buttons", action: nil, keyEquivalent: "")
        tb.submenu = BarLayout.shared.menu()
        menu.addItem(tb)
        // У курсора; пока меню открыто, капсула сверху не сворачивается
        guard let e = NSApp.currentEvent, let v = e.window?.contentView else { return }
        let p = v.convert(e.locationInWindow, from: nil)
        m.topBarHold = true
        menu.popUp(positioning: nil, at: p, in: v)
        m.topBarHold = false
    }
}

/// Пункт меню с действием-замыканием
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

// MARK: - Общий ряд кнопок: полоса над страницей и капсула сверху

/// Кнопки адресной полосы. Порядок общий у полосы над страницей и капсулы сверху;
/// меняется перетаскиванием (как значки пространств). «⋯» всегда справа.
enum BarItem: String, CaseIterable, Identifiable {
    case back, forward, reload, address, extensions, reader, share, bookmark, downloads
    var id: String { rawValue }
}

@Observable
final class BarLayout {
    static let shared = BarLayout()
    static let standard: [BarItem] = [.back, .forward, .reload, .address, .extensions, .reader, .share, .bookmark, .downloads]
    private static let key = "barItems"

    var items: [BarItem] {
        didSet { UserDefaults.standard.set(items.map(\.rawValue).joined(separator: ","), forKey: Self.key) }
    }
    /// Спрятанные кнопки (правый клик по кнопке → Hide, или «⋯» → Toolbar Buttons). Адрес не прячется.
    var hidden: Set<BarItem> {
        didSet { UserDefaults.standard.set(hidden.map(\.rawValue), forKey: Self.key + "Hidden") }
    }
    var visible: [BarItem] { items.filter { !hidden.contains($0) } }

    func toggle(_ i: BarItem) {
        guard i != .address else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if hidden.contains(i) { hidden.remove(i) } else { hidden.insert(i) }
        }
    }
    func reset() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { items = Self.standard; hidden = [] }
    }
    var isStandard: Bool { items == Self.standard && hidden.isEmpty }

    /// Подписи в меню
    static func title(_ i: BarItem) -> String {
        switch i {
        case .back: "Back"; case .forward: "Forward"; case .reload: "Reload"; case .address: "Address"
        case .extensions: "Extensions"; case .reader: "Reader"; case .share: "Share"; case .bookmark: "Save Tab"
        case .downloads: "Downloads"
        }
    }

    /// «Toolbar Buttons» для меню «⋯»: галочки у видимых, внизу — сброс
    func menu() -> NSMenu {
        let m = NSMenu()
        for i in Self.standard where i != .address {
            let it = ClosureMenuItem(Self.title(i)) { [weak self] in self?.toggle(i) }
            it.state = hidden.contains(i) ? .off : .on
            m.addItem(it)
        }
        m.addItem(.separator())
        let r = ClosureMenuItem("Reset Toolbar") { [weak self] in self?.reset() }
        r.isEnabled = !isStandard
        m.addItem(r)
        return m
    }

    init() {
        var list: [BarItem] = []
        for part in (UserDefaults.standard.string(forKey: Self.key) ?? "").split(separator: ",") {
            if let i = BarItem(rawValue: String(part)), !list.contains(i) { list.append(i) }
        }
        // Новые кнопки (появились в обновлении) — в конец
        for i in Self.standard where !list.contains(i) { list.append(i) }
        items = list
        hidden = Set((UserDefaults.standard.stringArray(forKey: Self.key + "Hidden") ?? []).compactMap(BarItem.init(rawValue:)))
    }
}

/// Ряд кнопок и адрес — в том порядке, что задан в BarLayout. Кнопку можно утащить на новое место:
/// за курсором едет её копия, остальные расступаются.
struct BarRow: View {
    @Environment(BrowserModel.self) private var model
    /// Капсула сверху (компактно, без растяжек) или полоса над страницей
    let capsule: Bool
    let dark: Bool
    @State private var layout = BarLayout.shared
    @State private var frames: [BarItem: CGRect] = [:]
    @State private var dragItem: BarItem?
    @State private var dragStart: CGFloat = 0
    @State private var dragX: CGFloat = 0
    private let space = "barRow"

    var body: some View {
        HStack(spacing: capsule ? 2 : 4) {
            ForEach(layout.visible) { item in
                if item == .address {
                    if !capsule { Spacer(minLength: 12) }
                    AddressField(tab: model.activeTab, dark: dark)
                        .frame(minWidth: capsule ? 240 : 200, maxWidth: capsule ? 360 : 560)
                        .layoutPriority(1)
                        .background(reader(item))
                    if !capsule { Spacer(minLength: 12) }
                } else {
                    cell(item)
                        .opacity(dragItem == item ? 0 : 1)
                        .background(reader(item))
                        .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
                            .onChanged { move(item, $0) }
                            .onEnded { _ in end() })
                        .contextMenu {
                            Button("Hide “\(BarLayout.title(item))”") { layout.toggle(item) }
                            Menu("Toolbar Buttons") {
                                ForEach(BarLayout.standard.filter { $0 != .address }) { i in
                                    Button((layout.hidden.contains(i) ? "    " : "✓ ") + BarLayout.title(i)) { layout.toggle(i) }
                                }
                                Divider()
                                Button("Reset Toolbar") { layout.reset() }.disabled(layout.isStandard)
                            }
                        }
                }
            }
        }
        .coordinateSpace(name: space)
        // Копия утаскиваемой кнопки — под курсором
        .overlay(alignment: .topLeading) {
            if let d = dragItem, let f = frames[d] {
                cell(d)
                    .scaleEffect(1.12)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                    .position(x: dragX, y: f.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func reader(_ item: BarItem) -> some View {
        GeometryReader { g in
            let f = g.frame(in: .named(space))
            Color.clear
                .onAppear { frames[item] = f }
                .onChange(of: f) { frames[item] = f }
        }
    }

    @ViewBuilder private func cell(_ item: BarItem) -> some View {
        let t = model.activeTab
        switch item {
        case .back:
            ToolbarButton(icon: "chevron.left", help: "Back", enabled: t?.canGoBack ?? false) { PageSwipe.shared.step(t?.webView, back: true) }
        case .forward:
            ToolbarButton(icon: "chevron.right", help: "Forward", enabled: t?.canGoForward ?? false) { PageSwipe.shared.step(t?.webView, back: false) }
        case .reload:
            ToolbarButton(icon: t?.isLoading == true ? "xmark" : "arrow.clockwise",
                          help: t?.isLoading == true ? "Stop" : "Reload") {
                if t?.isLoading == true { t?.webView?.stopLoading() } else { t?.reload() }
            }
        case .extensions:
            if Ext.active { HStack(spacing: capsule ? 2 : 4) { ExtensionButtons() } }
        case .reader:
            ToolbarButton(icon: "doc.plaintext", help: "Reader — \(Shortcuts.shared.text(.reader))", enabled: t?.url != nil) { model.toggleReader() }
        case .share:
            ToolbarButton(icon: "square.and.arrow.up", help: "Share", enabled: t?.url != nil) { model.share() }
        case .bookmark:
            // В инкогнито сохранить нечего — всё сотрётся; место под кнопку остаётся, чтобы адрес не съезжал
            if model.currentSpace.isIncognito {
                Color.clear.frame(width: 28, height: 28)
            } else {
                let saved = t.map(model.isBookmarked) == true
                ToolbarButton(icon: saved ? "star.fill" : "star", help: saved ? "Saved" : "Save tab — keep it above the line",
                              enabled: t?.url != nil) { if let t { model.toggleBookmark(t) } }
            }
        case .downloads:
            DownloadsBarButton()
        case .address:
            EmptyView()
        }
    }

    private func move(_ item: BarItem, _ v: DragGesture.Value) {
        if dragItem != item {
            dragStart = frames[item]?.midX ?? v.startLocation.x
            dragItem = item
            model.topBarHold = true
        }
        let x = dragStart + v.translation.width
        dragX = x
        // Место — среди остальных по их центрам (адрес тоже считается: перетащил за него — кнопка на другой стороне)
        var list = layout.visible.filter { $0 != item }
        let to = list.filter { (frames[$0]?.midX ?? 0) < x }.count
        list.insert(item, at: min(to, list.count))
        // Спрятанные — в конец: покажешь снова — появятся справа
        let full = list + layout.items.filter { layout.hidden.contains($0) }
        if full != layout.items {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { layout.items = full }
        }
    }

    private func end() {
        dragItem = nil
        model.topBarHold = false
    }
}

/// Оптическая поправка значков: SF Symbols центрируются по своей рамке, а видимая часть в ней бывает смещена
/// (у «Поделиться» — ниже). Меряем один раз по картинке и сдвигаем так, чтобы центр рисунка был на оси.
enum SymbolOptics {
    private static var cache: [String: CGSize] = [:]

    static func offset(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .medium) -> CGSize {
        let key = "\(name)|\(size)|\(weight.rawValue)"
        if let c = cache[key] { return c }
        var r = CGSize.zero
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)) {
            let sc: CGFloat = 4, s = img.size
            let w = Int(s.width * sc), h = Int(s.height * sc)
            if w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                img.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
                NSGraphicsContext.restoreGraphicsState()
                var x0 = w, x1 = -1, y0 = h, y1 = -1
                if let data = rep.bitmapData {
                    let row = rep.bytesPerRow
                    for y in 0..<h { for x in 0..<w where data[y * row + x * 4 + 3] > 80 {
                        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                    } }
                }
                if x1 >= 0 {
                    // Сдвиг к центру, округлённый до полупункта (чёткость на Retina)
                    let dx = (CGFloat(w) / 2 - CGFloat(x0 + x1 + 1) / 2) / sc
                    let dy = (CGFloat(h) / 2 - CGFloat(y0 + y1 + 1) / 2) / sc
                    r = CGSize(width: (dx * 2).rounded() / 2, height: (dy * 2).rounded() / 2)
                }
            }
        }
        cache[key] = r
        return r
    }
}

extension View {
    /// Окно попапа — в той же теме, что и его содержимое. Полоса над страницей берёт тему сайта
    /// (`colorScheme` по цвету страницы), а окно попапа из попапа брало тему системы: белый текст на светлом
    func windowScheme() -> some View { modifier(WindowScheme()) }
}

private struct WindowScheme: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background(SchemeProbe(dark: scheme == .dark))
    }
}

private struct SchemeProbe: NSViewRepresentable {
    let dark: Bool
    final class Probe: NSView {
        var dark = false { didSet { apply() } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            // Только окно попапа или плавающей панели; окно браузера — никогда
            guard let w = window, !BrowserModel.windows.contains(where: { $0.window === w }) else { return }
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) { v.dark = dark }
}
