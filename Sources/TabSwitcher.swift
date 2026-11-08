import AppKit
import SwiftUI
import WebKit

// MARK: - Превью страниц

extension Tab {
    /// Маленький снимок страницы для переключателя и обзора вкладок.
    func capturePreview() {
        guard !Perf.off("thumbs"), let wv = webView, wv.window != nil, wv.bounds.width > 10 else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = 480
        cfg.afterScreenUpdates = false
        wv.takeSnapshot(with: cfg) { [weak self] img, _ in
            guard let self, let img else { return }
            self.preview = img
            if !self.isIncognito { ThumbnailStore.shared.save(img, for: self.id) }
        }
    }
}

/// Карточка вкладки: снимок страницы (или крупный значок, если снимка нет) + заголовок.
struct TabPreviewCard: View {
    let tab: Tab
    let highlighted: Bool
    var width: CGFloat = 200
    var onClose: (() -> Void)?
    /// Серая рамка под курсором; в ⌃Tab её нет — там наведение само выбирает карточку (синяя рамка)
    var hoverRing = true
    @State private var hover = false

    var body: some View {
        let h = width * 0.62
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let img = tab.preview {
                    Image(nsImage: img).resizable().interpolation(.high)
                        .scaledToFill()
                        .frame(width: width, height: h, alignment: .top)
                        .clipped()
                } else {
                    Favicon(url: tab.url).frame(width: 36, height: 36).opacity(0.8)
                }
            }
            .frame(width: width, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .circular))
            .overlay(alignment: .bottomLeading) {
                // Играет звук или видео
                if tab.playing {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .padding(8)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .circular).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                if let onClose, hover {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            }
            .padding(4)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .circular)
                    .strokeBorder(highlighted ? Color.accentColor : (hover && hoverRing ? Color.primary.opacity(0.15) : .clear),
                                  lineWidth: highlighted ? 3 : 1.5)
            }
            HStack(spacing: 6) {
                Favicon(url: tab.url).frame(width: 14, height: 14)
                Text(tab.displayTitle).font(.system(size: 12, weight: highlighted ? .semibold : .regular)).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .onHover { hover = $0 }
        .onAppear { ThumbnailStore.shared.loadCached(tab) }
        .onDisappear { hover = false }      // ушла с экрана под курсором — в следующий раз без подсветки
    }
}

// MARK: - ⌃Tab: переключатель последних вкладок

@Observable
final class TabSwitcher {
    /// Своё у каждого окна; `shared` — у окна, в котором сейчас работают
    static var shared: TabSwitcher { BrowserModel.current.switcher }
    var items: [UUID] = []
    var index = 0
    /// Где был курсор, когда переключатель открылся: наведение считается, только если мышь сдвинули
    @ObservationIgnored var mouseAtOpen: NSPoint = .zero
    var visible: Bool { !items.isEmpty }
    /// Попап на экране. Быстрое ⌃Tab (нажал и отпустил) переключает на соседнюю без попапа:
    /// он появляется, только если ⌃ держат дольше мгновения или жмут Tab ещё раз
    var shown = false
    @ObservationIgnored private var run = 0
    static let count = 5

    /// Недавние вкладки текущего пространства (и открытое избранное) — свежие первыми.
    private func recent(_ model: BrowserModel) -> [Tab] {
        let sp = model.currentSpace
        let pool = sp.tabs + model.favorites
        return Array(pool.sorted { $0.lastActive > $1.lastActive }.prefix(Self.count))
    }

    func step(_ d: Int, model: BrowserModel) {
        if !visible {
            model.activeTab?.capturePreview()
            let list = recent(model)
            guard list.count > 1 else { return }
            if let a = model.activeTab, let i = list.firstIndex(where: { $0 === a }), i != 0 {
                // активная должна стоять первой
                var l = list; l.remove(at: i); l.insert(a, at: 0)
                items = l.map(\.id)
            } else {
                items = list.map(\.id)
            }
            index = d > 0 ? 1 : items.count - 1
            ThumbnailStore.shared.request(list)
            mouseAtOpen = NSEvent.mouseLocation
            run += 1
            let r = run
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self, self.run == r, self.visible else { return }
                withAnimation(.easeOut(duration: 0.12)) { self.shown = true }
            }
        } else {
            index = (index + d + items.count) % items.count
            if !shown { withAnimation(.easeOut(duration: 0.12)) { shown = true } }
        }
    }

    func commit(model: BrowserModel) {
        guard visible else { return }
        let id = items[index]
        items = []
        shown = false
        if let t = model.allTabs.first(where: { $0.id == id }) { model.select(t) }
    }

    func cancel() { items = []; shown = false }
}

struct TabSwitcherView: View {
    @Environment(BrowserModel.self) private var model
    private var sw: TabSwitcher { model.switcher }

    var body: some View {
        if sw.visible && sw.shown {
            let tabs = sw.items.compactMap { id in model.allTabs.first { $0.id == id } }
            HStack(spacing: 14) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { i, t in
                    TabPreviewCard(tab: t, highlighted: i == sw.index, width: 180, hoverRing: false)
                        .onTapGesture { sw.index = i; sw.commit(model: model) }
                        // Навёл мышь — выбрана эта (отпустил ⌃ — открылась); карточка, оказавшаяся под курсором
                        // при открытии, не в счёт, пока мышь не сдвинули
                        .onHover { on in
                            guard on, NSEvent.mouseLocation != sw.mouseAtOpen else { return }
                            withAnimation(.easeOut(duration: 0.1)) { sw.index = i }
                        }
                }
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .circular))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .circular).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }
}

// MARK: - Тап тремя пальцами: обзор всех вкладок

@Observable
final class TabOverview {
    /// Своё у каждого окна; `shared` — у окна, в котором сейчас работают
    static var shared: TabOverview { BrowserModel.current.overview }
    var visible = false

    func toggle(model: BrowserModel) {
        if !visible {
            model.activeTab?.capturePreview()
            ThumbnailStore.shared.request(model.favorites + model.currentSpace.ordered)
        } else {
            ThumbnailStore.shared.stop()
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { visible.toggle() }
    }
    func close() { ThumbnailStore.shared.stop(); withAnimation(.easeOut(duration: 0.2)) { visible = false } }
}

struct TabOverviewView: View {
    @Environment(BrowserModel.self) private var model
    private var ov: TabOverview { model.overview }
    @State private var query = ""
    @AppStorage("overview.showAll") private var showAll = false
    @AppStorage("overview.sort") private var sort = "sidebar"      // sidebar | recent | title | site
    @AppStorage("overview.group") private var group = "state"      // none | state | site | folder
    @FocusState private var searchFocused: Bool

    private struct Group: Identifiable { let id: String; let title: String?; let tabs: [Tab] }

    var body: some View {
        if ov.visible {
            let sp = model.currentSpace
            let groups = makeGroups(sp)
            let count = groups.reduce(0) { $0 + $1.tabs.count }
            ZStack {
                Rectangle().fill(.thickMaterial)
                    .overlay(Color.black.opacity(0.12))
                    .ignoresSafeArea()
                    .onTapGesture { ov.close() }
                VStack(spacing: 18) {
                    header(sp, count: count)
                    GeometryReader { g in
                        let size = cardSize(count: count, groups: groups.count, in: g.size)
                        let cols = max(1, Int((g.size.width + 20) / (size.width + 20)))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(groups) { gr in
                                    if let t = gr.title {
                                        Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                    }
                                    // Ряды по центру: колонок не больше, чем карточек в группе
                                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(size.width), spacing: 20),
                                                             count: min(cols, max(1, gr.tabs.count))),
                                              alignment: .center, spacing: 20) {
                                        ForEach(gr.tabs) { t in
                                            TabPreviewCard(tab: t, highlighted: model.isVisible(t), width: size.width) {
                                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.close(t) }
                                            }
                                            .onTapGesture { ov.close(); model.select(t) }
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(4)
                        }
                        .scrollDisabled(size.width > Self.minCard)
                    }
                }
                .padding(40)
            }
            .transition(.opacity.combined(with: .scale(scale: 1.03)))
            .onAppear { query = ""; refreshPlaying(sp) }
            .task(id: ov.visible) {
                // Пока обзор открыт — раз в пару секунд смотрим, где играет звук
                while ov.visible && !Task.isCancelled {
                    refreshPlaying(model.currentSpace)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    // Шапка: пространство слева, поиск по центру, переключатель и сортировка справа
    private func header(_ sp: Space, count: Int) -> some View {
        ZStack {
            HStack(spacing: 8) {
                // Переключатель пространств: открытое — значок с названием, остальные — значки
                spacePicker(sp)
                Text("\(count) tab\(count == 1 ? "" : "s")").foregroundStyle(.secondary)
                Spacer()
                Toggle("Show all", isOn: $showAll).toggleStyle(.switch).controlSize(.small)
                    .help("Also show tabs that are asleep (not loaded)")
                Menu {
                    Picker("Sort", selection: $sort) {
                        Text("Sidebar order").tag("sidebar")
                        Text("Recently used").tag("recent")
                        Text("Title").tag("title")
                        Text("Site").tag("site")
                    }
                    Picker("Group", selection: $group) {
                        Text("None").tag("none")
                        Text("Open / Asleep").tag("state")
                        Text("Site").tag("site")
                        Text("Folder").tag("folder")
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tabs", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let t = makeGroups(sp).first?.tabs.first { ov.close(); model.select(t) } }
            }
            .padding(.horizontal, 12)
            .frame(width: 320, height: 32)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    /// Пространства рядком: клик — обзор (и окно) переходит в него; ⌥⌘← / ⌥⌘→ — соседнее
    private func spacePicker(_ sp: Space) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(model.spaces.enumerated()), id: \.element.id) { i, s in
                let on = s.id == sp.id
                // Открыто в другом окне — там и смотреть
                let elsewhere = BrowserModel.window(showing: s).map { $0 !== model } ?? false
                Button {
                    guard !on else { return }
                    query = ""
                    model.swipe.switchTo(i, model: model)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: on ? Symbols.filled(s.icon) : s.icon)
                            .font(.system(size: on ? 15 : 14))
                            .foregroundStyle(on ? AnyShapeStyle(s.iconColor) : AnyShapeStyle(.secondary))
                        if on { Text(s.name).font(.system(size: 17, weight: .semibold)).lineLimit(1) }
                    }
                    .padding(.horizontal, on ? 12 : 8)
                    .frame(height: 32)
                    .background(on ? Color.primary.opacity(0.1) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(elsewhere ? 0.4 : 1)
                .help(elsewhere ? "\(s.name) — open in another window" : s.name)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: sp.id)
        .onChange(of: sp.id) {
            // Другое пространство — его превью и звук
            ThumbnailStore.shared.request(model.favorites + model.currentSpace.ordered)
            refreshPlaying(model.currentSpace)
        }
    }

    // MARK: Отбор, сортировка, группы

    private func makeGroups(_ sp: Space) -> [Group] {
        var tabs = model.favorites + sp.ordered
        if !showAll { tabs = tabs.filter { !$0.asleep || model.isVisible($0) } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            tabs = tabs.filter { $0.displayTitle.lowercased().contains(q) || ($0.url?.absoluteString.lowercased().contains(q) ?? false) }
        }
        switch sort {
        case "recent": tabs.sort { $0.lastActive > $1.lastActive }
        case "title": tabs.sort { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case "site": tabs.sort { ($0.url?.host ?? "") < ($1.url?.host ?? "") }
        default: break
        }
        func host(_ t: Tab) -> String { (t.url?.host ?? "Other").replacingOccurrences(of: "www.", with: "") }
        switch group {
        case "state" where showAll:
            let open = tabs.filter { !$0.asleep || model.isVisible($0) }
            let asleep = tabs.filter { $0.asleep && !model.isVisible($0) }
            return [Group(id: "open", title: "Open", tabs: open), Group(id: "asleep", title: "Asleep", tabs: asleep)]
                .filter { !$0.tabs.isEmpty }
        case "site":
            var order: [String] = [], map: [String: [Tab]] = [:]
            for t in tabs { let h = host(t); if map[h] == nil { order.append(h) }; map[h, default: []].append(t) }
            return order.map { Group(id: "s:" + $0, title: $0, tabs: map[$0]!) }
        case "folder":
            var out: [Group] = []
            let pinned = tabs.filter { $0.isPinned }
            if !pinned.isEmpty { out.append(Group(id: "pinned", title: "Pinned", tabs: pinned)) }
            for f in sp.folders {
                let ts = tabs.filter { $0.folderID == f.id }
                if !ts.isEmpty { out.append(Group(id: f.id.uuidString, title: f.name, tabs: ts)) }
            }
            let rest = tabs.filter { !$0.isPinned && $0.folderID == nil }
            if !rest.isEmpty { out.append(Group(id: "rest", title: out.isEmpty ? nil : "Tabs", tabs: rest)) }
            return out
        default:
            return [Group(id: "all", title: nil, tabs: tabs)]
        }
    }

    // MARK: Размер карточек: меньше вкладок — крупнее

    static let minCard: CGFloat = 200
    private func cardSize(count: Int, groups: Int, in area: CGSize) -> CGSize {
        guard count > 0 else { return CGSize(width: 300, height: 0) }
        let gap: CGFloat = 20, title: CGFloat = 26, headers = CGFloat(max(0, groups - 1)) * 34 + (groups > 1 ? 34 : 0)
        var best: CGFloat = Self.minCard
        for cols in 1...count {
            let rows = CGFloat((count + cols - 1) / cols)
            let w = (area.width - gap * CGFloat(cols - 1) - 8) / CGFloat(cols)
            let hAvail = (area.height - headers - gap * (rows - 1) - 8) / rows - title - 14
            let fitted = min(w, hAvail / 0.62)
            best = max(best, fitted)
        }
        return CGSize(width: min(best, 900), height: 0)
    }

    private func refreshPlaying(_ sp: Space) {
        for t in model.favorites + sp.tabs {
            guard let wv = t.webView else { if t.playing { t.playing = false }; continue }
            wv.requestMediaPlaybackState { state in
                let p = state == .playing
                if t.playing != p { t.playing = p }
            }
        }
    }
}

// MARK: - Миниатюры: хранятся на диске, недостающие дорисовываются в невидимом окне

final class ThumbnailStore: NSObject, WKNavigationDelegate {
    static let shared = ThumbnailStore()

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sapfire/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func file(_ id: UUID) -> URL { Self.dir.appendingPathComponent(id.uuidString + ".jpg") }

    /// Сохранить свежий снимок (в фоне).
    func save(_ img: NSImage, for id: UUID) {
        DispatchQueue.global(qos: .utility).async {
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return }
            try? jpg.write(to: self.file(id), options: .atomic)
        }
    }

    /// Подтянуть снимок с диска, если в памяти его нет.
    func loadCached(_ tab: Tab) {
        guard tab.preview == nil else { return }
        let url = file(tab.id)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let img = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async { if tab.preview == nil { tab.preview = img } }
        }
    }

    /// Удалить снимки закрытых вкладок.
    func cleanup(keeping ids: Set<UUID>) {
        DispatchQueue.global(qos: .background).async {
            let files = (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where !ids.contains(UUID(uuidString: f.deletingPathExtension().lastPathComponent) ?? UUID()) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    // Невидимый рендер: по одной вкладке, пока открыт обзор или переключатель
    private var queue: [Tab] = []
    private var current: Tab?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var timeout: DispatchWorkItem?

    func request(_ tabs: [Tab]) {
        for t in tabs {
            loadCached(t)
            guard t.url != nil, !t.isIncognito, !queue.contains(where: { $0 === t }), current !== t else { continue }
            // Даём диску ответить: если снимок найдётся, рендер не понадобится
            queue.append(t)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.next() }
    }

    func stop() { queue.removeAll() }

    private func next() {
        guard current == nil else { return }
        queue.removeAll { $0.preview != nil }
        guard !queue.isEmpty else { tearDown(); return }
        let t = queue.removeFirst()
        current = t
        let wv = ensureWebView()
        wv.load(URLRequest(url: t.url!))
        let w = DispatchWorkItem { [weak self] in self?.shoot() }
        timeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timeout?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.shoot() }
        timeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }

    private func shoot() {
        if Perf.off("thumbs") { current = nil; return }
        guard let t = current, let wv = webView else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = 480
        wv.takeSnapshot(with: cfg) { [weak self] img, _ in
            if let img, t.preview == nil { t.preview = img; self?.save(img, for: t.id) }
            self?.current = nil
            self?.next()
        }
    }

    private func ensureWebView() -> WKWebView {
        if let wv = webView { return wv }
        let cfg = BrowserModel.makeConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = .all      // никакого звука из невидимого окна
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 800),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.alphaValue = 0.01
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: cfg)
        wv.navigationDelegate = self
        w.contentView = wv
        w.orderFrontRegardless()
        window = w; webView = wv
        return wv
    }

    private func tearDown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        webView = nil; window = nil
    }
}

// MARK: - Превью вкладки при наведении (как в Orion)

/// Задержался курсором на вкладке в панели — справа всплывает карточка: снимок страницы, заголовок, адрес.
/// Пока карточка видна, соседние вкладки показываются сразу, без задержки.
@Observable
final class HoverPreview {
    /// Своё у каждого окна; `shared` — у окна, в котором сейчас работают
    static var shared: HoverPreview { BrowserModel.current.hoverPreview }
    private(set) var tab: Tab?
    private(set) var anchor: CGRect = .zero
    @ObservationIgnored private var work: DispatchWorkItem?

    func hover(_ t: Tab, frame: CGRect, on: Bool, model: BrowserModel) {
        work?.cancel()
        if !on {
            let w = DispatchWorkItem { [weak self] in
                withAnimation(.easeOut(duration: 0.12)) { self?.tab = nil }
            }
            work = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
            return
        }
        // Открытую вкладку и так видно; во время перетаскивания — не мешаем
        guard !model.isVisible(t), !model.drag.active else { hide(); return }
        ThumbnailStore.shared.loadCached(t)
        let show = { [weak self] in
            guard let self else { return }
            self.anchor = frame
            withAnimation(.easeOut(duration: 0.14)) { self.tab = t }
        }
        if tab != nil { show(); return }         // уже показываем — соседнюю сразу
        let w = DispatchWorkItem(block: show)
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func hide() {
        work?.cancel(); work = nil
        if tab != nil { withAnimation(.easeOut(duration: 0.1)) { tab = nil } }
    }
}

struct HoverPreviewOverlay: View {
    @Environment(BrowserModel.self) private var model
    private var hp: HoverPreview { model.hoverPreview }
    static let width: CGFloat = 280

    var body: some View {
        GeometryReader { g in
            let origin = g.frame(in: .global).origin
            if let t = hp.tab {
                let a = hp.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
                let h = Self.width * 0.62 + 64
                let top = max(8, min(a.midY - h / 2, g.size.height - h - 8))
                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        Color(nsColor: .controlBackgroundColor)
                        if let img = t.preview {
                            Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
                                .frame(width: Self.width, height: Self.width * 0.62, alignment: .top)
                                .clipped()
                        } else {
                            Favicon(url: t.url).frame(width: 36, height: 36).opacity(0.8)
                        }
                    }
                    .frame(width: Self.width, height: Self.width * 0.62)
                    .clipped()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text(t.url?.host ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(width: Self.width, alignment: .leading)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .circular))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .circular).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 16, y: 5)
                .offset(x: a.maxX + 12, y: top)
                .transition(.opacity.combined(with: .offset(x: -6)))
                .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
        // Сменили пространство, спрятали панель, начали тащить — карточку убираем
        .onChange(of: model.currentSpaceID) { hp.hide() }
        .onChange(of: model.sidebarVisible) { hp.hide() }
        .onChange(of: model.sidebarPeek) { hp.hide() }
        .onChange(of: model.drag.active) { hp.hide() }
        .onChange(of: model.activeTab?.id) { hp.hide() }
    }
}
