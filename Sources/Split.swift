import AppKit
import SwiftUI

// MARK: - Область страниц: одна страница или сплит до четырёх панелей

/// Где на экране страницы (в координатах окна) — куда бросать вкладку, чтобы открыть её рядом
final class SplitDrop {
    /// Своё у каждого окна; `shared` — у окна, в котором сейчас работают
    static var shared: SplitDrop { BrowserModel.current.splitDrop }
    var area: CGRect = .zero
    var panes: [Int: CGRect] = [:]

    /// Куда встанет вкладка: новая панель (replace == nil) или вместо панели `replace`
    func zone(replace: Int?, count n: Int) -> CGRect? {
        if let r = replace { return panes[r] }
        let a = area
        guard a.width > 0 else { return nil }
        switch n {
        case 0, 1: return CGRect(x: a.midX, y: a.minY, width: a.width / 2, height: a.height)
        case 2: return CGRect(x: a.maxX - a.width / 3, y: a.minY, width: a.width / 3, height: a.height)
        default: return CGRect(x: a.midX, y: a.midY, width: a.width / 2, height: a.height / 2)   // четвёртая — справа внизу
        }
    }
}

struct WebArea: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        let sp = model.currentSpace
        let panes = sp.paneTabs
        Group {
            if panes.isEmpty { EmptyStart() }
            else if panes.count == 1 { WebPane(tab: panes[0], index: 0, split: false) }
            else if let g = sp.group(of: sp.selectedTabID) { SplitPanes(space: sp, group: g, panes: panes) }
        }
        .background(GeometryReader { g in
            let f = g.frame(in: .global)
            Color.clear.onAppear { model.splitDrop.area = f }.onChange(of: f) { model.splitDrop.area = f }
        })
    }
}

/// Панели сплита — карточки на общей подложке. Между ними — промежутки (без черт), за которые тянут размер;
/// с зажатым Ctrl (или если привязка включена правым кликом по промежутку) край встаёт на 1/12 ширины.
struct SplitPanes: View {
    @Environment(BrowserModel.self) private var model
    let space: Space
    let group: [UUID]
    let panes: [Tab]
    @AppStorage("splitSnap") private var snap = false
    @AppStorage("sidebarStyle") private var sidebarStyle = "attached"
    /// Доли на время перетаскивания промежутка (чтобы не писать в модель на каждый пиксель)
    @State private var live: [Double]?
    @State private var start: [Double]?

    static let gap = Metrics.inset
    static let minPane: CGFloat = 200

    var body: some View {
        GeometryReader { g in
            // Панель-карточка (Floating) уже отстоит от страниц на свой отступ — слева второй не добавляем:
            // от панели до первой страницы столько же, сколько между страницами
            let lead: CGFloat = model.sidebarVisible && sidebarStyle == "floating" ? 0 : Metrics.inset
            let area = CGRect(x: lead, y: Metrics.inset, width: g.size.width - lead - Metrics.inset, height: g.size.height - Metrics.inset * 2)
            let arrange = space.arrange(of: group)
            let sizes = live ?? space.sizes(of: group)
            let frames = Self.frames(arrange, sizes, panes.count, area)
            ZStack(alignment: .topLeading) {
                ForEach(Array(panes.enumerated()), id: \.element.id) { i, t in
                    if i < frames.count {
                        WebPane(tab: t, index: i, split: true)
                            .frame(width: frames[i].width, height: frames[i].height)
                            .position(x: frames[i].midX, y: frames[i].midY)
                    }
                }
                ForEach(handles(arrange, frames, area), id: \.id) { h in
                    GapHandle(vertical: h.vertical, menu: { gapMenu(arrange) })
                        .frame(width: h.rect.width, height: h.rect.height)
                        .position(x: h.rect.midX, y: h.rect.midY)
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                            .onChanged { v in drag(h, v.translation, arrange, area) }
                            .onEnded { _ in
                                if let l = live { space.setSizes(l, for: group) }
                                live = nil; start = nil
                            })
                }
            }
        }
        .onAppear { Tips.show(.split, model) }
    }

    // MARK: Раскладка

    /// Края панелей — по целым точкам: иначе край ложится между пикселями, и промежутки на глаз разные
    static func frames(_ a: Space.SplitArrange, _ s: [Double], _ n: Int, _ r: CGRect) -> [CGRect] {
        rawFrames(a, s, n, r).map { f in
            let x0 = f.minX.rounded(), y0 = f.minY.rounded()
            return CGRect(x: x0, y: y0, width: f.maxX.rounded() - x0, height: f.maxY.rounded() - y0)
        }
    }

    private static func rawFrames(_ a: Space.SplitArrange, _ s: [Double], _ n: Int, _ r: CGRect) -> [CGRect] {
        let gap = Self.gap
        switch a {
        case .columns, .rows:
            let horizontal = a == .columns
            let total = (horizontal ? r.width : r.height) - gap * CGFloat(n - 1)
            var pos = horizontal ? r.minX : r.minY
            return (0..<n).map { i in
                let len = total * CGFloat(i < s.count ? s[i] : 1 / Double(n))
                defer { pos += len + gap }
                return horizontal ? CGRect(x: pos, y: r.minY, width: len, height: r.height)
                                  : CGRect(x: r.minX, y: pos, width: r.width, height: len)
            }
        case .grid:
            let cw = (r.width - gap) * CGFloat(s[0]), rh = (r.height - gap) * CGFloat(s[1])
            let x2 = r.minX + cw + gap, y2 = r.minY + rh + gap
            let left = CGRect(x: r.minX, y: r.minY, width: cw, height: rh)
            let right = CGRect(x: x2, y: r.minY, width: r.maxX - x2, height: rh)
            let bl = CGRect(x: r.minX, y: y2, width: cw, height: r.maxY - y2)
            let br = CGRect(x: x2, y: y2, width: r.maxX - x2, height: r.maxY - y2)
            if n == 3 {
                // Три: первая — во всю высоту слева, две — друг над другом справа
                return [CGRect(x: r.minX, y: r.minY, width: cw, height: r.height), right, br]
            }
            return [left, right, bl, br]
        }
    }

    private struct Handle: Identifiable { let id: Int; let rect: CGRect; let vertical: Bool }

    /// Промежутки, за которые тянут: между соседними панелями (у сетки — вертикальный и горизонтальный)
    private func handles(_ a: Space.SplitArrange, _ f: [CGRect], _ r: CGRect) -> [Handle] {
        let w = Self.gap + 8
        switch a {
        case .columns:
            return (0..<max(0, f.count - 1)).map { i in Handle(id: i, rect: CGRect(x: f[i].maxX - 4, y: r.minY, width: w, height: r.height), vertical: true) }
        case .rows:
            return (0..<max(0, f.count - 1)).map { i in Handle(id: i, rect: CGRect(x: r.minX, y: f[i].maxY - 4, width: r.width, height: w), vertical: false) }
        case .grid:
            let v = Handle(id: 0, rect: CGRect(x: f[0].maxX - 4, y: r.minY, width: w, height: r.height), vertical: true)
            let y = f[1].maxY
            let x0 = f.count == 3 ? f[1].minX : r.minX
            let hz = Handle(id: 1, rect: CGRect(x: x0, y: y - 4, width: r.maxX - x0, height: w), vertical: false)
            return [v, hz]
        }
    }

    private func drag(_ h: Handle, _ t: CGSize, _ a: Space.SplitArrange, _ r: CGRect) {
        if start == nil { start = space.sizes(of: group) }
        guard var s = start else { return }
        let snapNow = snap || NSEvent.modifierFlags.contains(.control)
        switch a {
        case .columns, .rows:
            let total = (a == .columns ? r.width : r.height) - Self.gap * CGFloat(s.count - 1)
            guard total > 0 else { return }
            let i = h.id
            let pair = s[i] + s[i + 1]
            let before = s[..<i].reduce(0, +)
            var edge = before + s[i] + Double((a == .columns ? t.width : t.height) / total)
            // Привязка: край — на ближайшую 1/12 ширины (высоты) страницы
            if snapNow { edge = (edge * 12).rounded() / 12 }
            let minF = Double(Self.minPane / total)
            let left = min(max(edge - before, minF), pair - minF)
            s[i] = left; s[i + 1] = pair - left
        case .grid:
            let k = h.vertical ? 0 : 1
            let total = (h.vertical ? r.width : r.height) - Self.gap
            guard total > 0 else { return }
            var v = s[k] + Double((h.vertical ? t.width : t.height) / total)
            if snapNow { v = (v * 12).rounded() / 12 }
            let minF = Double(Self.minPane / total)
            s[k] = min(max(v, minF), 1 - minF)
        }
        live = s
    }

    // MARK: Правый клик по промежутку

    @ViewBuilder private func gapMenu(_ a: Space.SplitArrange) -> some View {
        Section("Arrange") {
            Button((a == .columns ? "✓ " : "    ") + "Side by Side") { set(.columns) }
            Button((a == .rows ? "✓ " : "    ") + "Stacked") { set(.rows) }
            if group.count >= 3 { Button((a == .grid ? "✓ " : "    ") + "Grid") { set(.grid) } }
        }
        Section("Size") {
            Button("Equal Sizes") { withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { for id in group { space.splitSizes[id] = nil } } }
            Toggle("Snap to 1/12 of the Page", isOn: $snap)
        }
    }

    private func set(_ a: Space.SplitArrange) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { space.setArrange(a, for: group) }
    }
}

/// Промежуток между панелями: пустой, курсор ↔ (или ↕), правый клик — раскладка и привязка
private struct GapHandle<Menu: View>: View {
    let vertical: Bool
    @ViewBuilder let menu: () -> Menu
    var body: some View {
        GapCursorArea(vertical: vertical)
            .contentShape(Rectangle())
            .contextMenu { menu() }
    }
}

private struct GapCursorArea: NSViewRepresentable {
    let vertical: Bool
    final class V: NSView {
        var cursor: NSCursor = .resizeLeftRight
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }      // жесты и меню — SwiftUI
        override func layout() { super.layout(); window?.invalidateCursorRects(for: self) }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.cursor = vertical ? .resizeLeftRight : .resizeUpDown; return v }
    func updateNSView(_ v: V, context: Context) { v.cursor = vertical ? .resizeLeftRight : .resizeUpDown; v.window?.invalidateCursorRects(for: v) }
}

struct WebPane: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab
    let index: Int
    let split: Bool
    /// Курсор у верхнего края панели — показываем капсулу с адресом
    @State private var nearTop = false
    @AppStorage(Prefs.paneChipCenter) private var chipCenter = true
    /// Чтобы полоса загрузки перерисовывалась, когда полосу над страницей прячут / возвращают
    @AppStorage(Prefs.toolbar) private var toolbarOn = true
    @AppStorage(Prefs.topBar) private var topBarOn = true
    static let chipZone: CGFloat = 48

    var body: some View {
        // Скругление концентрично углу окна (как у карточки панели)
        let radius: CGFloat = split ? Metrics.cardRadius : 0
        // Страница одна — если её сейчас показывает другое окно, здесь заглушка «Show Here»
        let elsewhere = BrowserModel.windows.contains { m in
            m !== model && m.window != nil && m.isVisible(tab) && (tab.hostID == m.id || (tab.hostID != model.id && tab.hostID == nil))
        }
        Group {
            if elsewhere { ElsewherePane(tab: tab) } else { WebViewHost(tab: tab) }
        }
            // Панель скрыта и сверху полоска капсулы — загрузку показывает она
            .overlay(alignment: .top) { LoadingBar(tab: tab, always: split) }
            .overlay { FindMarks(tab: tab) }
            .pageClip(RoundedRectangle(cornerRadius: radius, style: .circular))
            .overlay {
                // Край панели в сплите на 10% темнее того, что под ним: светлая страница не сливается с подложкой,
                // а на тёмной обводки не видно — промежутки везде выглядят одинаковыми
                if split {
                    RoundedRectangle(cornerRadius: radius, style: .circular)
                        .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            // В сплите: курсор подошёл к верхнему краю панели — сверху её сайт и ✕ (по центру или справа — в настройках)
            .overlay(alignment: chipCenter ? .top : .topTrailing) {
                if split && (nearTop || model.paneDrag?.tabID == tab.id) {
                    PaneChip(tab: tab) { model.closePane(index) }
                        .padding(8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onContinuousHover { phase in
                let near: Bool = { if case .active(let p) = phase { return p.y < Self.chipZone }; return false }()
                if near != nearTop { withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { nearTop = near } }
            }
            .background(GeometryReader { g in
                let f = g.frame(in: .global)
                Color.clear.onAppear { if split { model.splitDrop.panes[index] = f } }
                    .onChange(of: f) { if split { model.splitDrop.panes[index] = f } }
            })
    }
}

/// Страница открыта в другом окне
private struct ElsewherePane: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab
    var body: some View {
        VStack(spacing: 12) {
            Favicon(url: tab.url).frame(width: 32, height: 32)
            Text(tab.displayTitle).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text("This tab is open in another window").foregroundStyle(.secondary)
            Button("Show Here") { tab.hostID = model.id }
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Капсула на панели сплита: значок и сайт, ✕ — убрать панель (вкладка остаётся в списке).
/// Капсулу можно тащить: в панель вкладок — вынуть из сплита, на другую панель — поменять местами,
/// за пределы окна — страница уходит в отдельное окно.
private struct PaneChip: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab
    let close: () -> Void
    @State private var hoverClose = false
    var body: some View {
        let sp = model.currentSpace
        HStack(spacing: 6) {
            Favicon(url: tab.url).frame(width: 12, height: 12)
            Text(tab.url?.host?.replacingOccurrences(of: "www.", with: "") ?? tab.displayTitle)
                .font(.system(size: 11, weight: .medium)).lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Color.primary.opacity(hoverClose ? 0.15 : 0.07), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hoverClose = $0 }
            .help("Remove from split")
        }
        .padding(.leading, 8).padding(.trailing, 4)
        .frame(height: 24)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        .opacity(model.paneDrag?.tabID == tab.id ? 0.4 : 1)
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { v in model.paneDrag = PaneDrag(tabID: tab.id, point: v.location) }
            .onEnded { v in model.endPaneDrag(at: v.location) })
        .help("Drag to the sidebar, onto another pane or out of the window")
        .contextMenu {
            if let g = sp.group(of: tab.id) { SplitMenu(tab: tab, group: g) }
        }
    }
}

/// Капсулу панели тащат (в координатах окна)
struct PaneDrag: Equatable {
    let tabID: UUID
    let point: CGPoint
}

extension BrowserModel {
    /// Куда упадёт панель: другая панель (поменять местами), панель вкладок (вынуть), за окно (отдельное окно)
    enum PaneDrop: Equatable { case swap(Int), sidebar, outside, none }
    func paneDrop(at p: CGPoint) -> PaneDrop {
        guard let win = mainWindow, let c = win.contentView else { return .none }
        if !c.bounds.insetBy(dx: 2, dy: 2).contains(CGPoint(x: p.x, y: p.y)) { return .outside }
        if (sidebarVisible || sidebarPeek) && p.x < swipe.sidebarRect.maxX { return .sidebar }
        let panes = currentSpace.paneTabs
        for (i, f) in splitDrop.panes where i < panes.count && f.contains(p) && panes[i].id != paneDrag?.tabID { return .swap(i) }
        return .none
    }

    func endPaneDrag(at p: CGPoint) {
        defer { paneDrag = nil }
        guard let d = paneDrag, let t = allTabs.first(where: { $0.id == d.tabID }) else { return }
        // Отпустили за окном: курсор вне окна (координаты жеста за окном ненадёжны)
        if let win = mainWindow, !win.frame.contains(NSEvent.mouseLocation) { popOut(t); return }
        switch paneDrop(at: p) {
        case .swap(let i): swapPane(t, with: currentSpace.paneTabs[i])
        case .sidebar: moveOutOfSplit(t)
        case .outside: popOut(t)
        case .none: break
        }
    }

    /// Вынуть вкладку из сплита — она снова отдельной строкой на своём месте в списке
    func moveOutOfSplit(_ t: Tab) {
        guard let sp = space(of: t) ?? (currentSpace.pinned.contains { $0 === t } ? currentSpace : nil) else { return }
        checkpoint("Move Out of Split")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { sp.leavePanes(t.id) }
    }

    /// Переставить панель на соседнее место
    func movePane(_ t: Tab, by d: Int) {
        let sp = currentSpace
        guard let gi = sp.splitGroups.firstIndex(where: { $0.contains(t.id) }),
              let i = sp.splitGroups[gi].firstIndex(of: t.id), sp.splitGroups[gi].indices.contains(i + d) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { sp.splitGroups[gi].swapAt(i, i + d) }
    }

    func swapPane(_ a: Tab, with b: Tab) {
        let sp = currentSpace
        guard let gi = sp.splitGroups.firstIndex(where: { $0.contains(a.id) && $0.contains(b.id) }),
              let i = sp.splitGroups[gi].firstIndex(of: a.id), let j = sp.splitGroups[gi].firstIndex(of: b.id) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { sp.splitGroups[gi].swapAt(i, j) }
    }

    /// Страница уходит в отдельное (маленькое) окно — как есть, без перезагрузки; «Open in Sapfire» вернёт её вкладкой
    func popOut(_ t: Tab) {
        guard let sp = space(of: t), !t.isPinned, let wv = t.webView else { return }
        checkpoint("Open in Separate Window")
        let at = NSEvent.mouseLocation
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            let wasSelected = sp.selectedTabID == t.id
            if !sp.leavePanes(t.id), wasSelected { sp.selectedTabID = sp.tabs.first { $0 !== t && !$0.isPinned }?.id }
            sp.tabs.removeAll { $0 === t }
            sp.normalize()
        }
        t.detachWebView()
        wv.removeFromSuperview()
        LittleWindow.open(webView: wv, at: at)
    }
}

/// Тащишь вкладку из панели на страницу — подсвечено место, где она откроется рядом
struct SplitDropOverlay: View {
    @Environment(BrowserModel.self) private var model
    private var drag: TabDrag { model.drag }

    var body: some View {
        GeometryReader { g in
            let o = g.frame(in: .global).origin
            if drag.active, case .split(let r) = drag.target,
               let rect = model.splitDrop.zone(replace: r, count: model.currentSpace.paneTabs.count) {
                let sp = model.currentSpace
                let shape = RoundedRectangle(cornerRadius: 12, style: .circular)
                shape.fill(sp.tint.opacity(0.18))
                    .overlay(shape.strokeBorder(sp.dropLine, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                    .overlay {
                        Label(r == nil ? "Open in Split" : "Replace", systemImage: r == nil ? "rectangle.split.2x1" : "arrow.left.arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .frame(width: max(0, rect.width - 16), height: max(0, rect.height - 16))
                    .position(x: rect.midX - o.x, y: rect.midY - o.y)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: drag.target)
    }
}

extension TabDrag {
    /// Вкладку вынесли из панели на страницу — открыть рядом (или вместо панели, если их уже четыре)
    func splitTarget(_ p: CGPoint, model: BrowserModel) -> DropTarget? {
        guard folderDrag == nil, let first = ids.first else { return nil }
        let side = model.swipe.sidebarRect
        let w = CGPoint(x: p.x + side.minX, y: p.y + side.minY)          // в координатах окна
        let d = model.splitDrop
        guard d.area.contains(w) else { return nil }
        // Над выехавшей (или закреплённой) панелью — это ещё панель, не страница
        if (model.sidebarVisible || model.sidebarPeek) && w.x < side.maxX + 12 { return nil }
        let sp = model.currentSpace
        guard sp.selectedTab != nil, !sp.inPanes(first) else { return nil }
        let n = sp.paneTabs.count
        if n < Space.maxPanes { return .split(nil) }
        for (i, f) in d.panes where i < n && f.contains(w) { return .split(i) }
        return .split(model.activePane)
    }
}

// MARK: - Сплит в панели вкладок: одна строка, разделённая на части

/// Строка сплита: по части на вкладку (значок и название), между ними — черта.
/// Клик по части — эта вкладка активна (на экране весь сплит); ✕ — разделить на отдельные вкладки.
struct SplitRow: View {
    @Environment(BrowserModel.self) private var model
    let lead: Tab
    let group: [UUID]
    var indent: CGFloat = 0
    @State private var hover = false
    @State private var rowID = UUID()
    @Environment(\.rowCorner) private var rowCorner

    var body: some View {
        let sp = model.currentSpace
        let tabs = sp.groupTabs(group)
        let shown = tabs.contains { $0.id == sp.selectedTabID }
        let drop = model.drag.hoverTab == lead.id
        // Закреплённая панель: открытый сплит соединён со страницей, как обычная вкладка —
        // «мостиком» (Attached) или вырезом в карточке панели (Floating); своей подсветки у строки тогда нет
        let bridged = shown && model.sidebarVisible
        HStack(spacing: 2) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { i, t in
                if i > 0 { SplitDivider() }
                SplitSegment(tab: t, group: group, active: shown && t.id == sp.selectedTabID, iconOnly: tabs.count > 3)
            }
            if hover && !model.drag.active {
                Button { model.unsplit(group) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Separate tabs")
            }
        }
        .padding(.leading, 2 + indent).padding(.trailing, 4)
        .frame(height: 32)
        .background {
            Group {
                if drop { DropHint(space: sp) }
                else if shown && !bridged { ActiveFill(space: sp) }
                else if hover && !shown { RoundedRectangle(cornerRadius: rowCorner, style: .circular).fill(sidebarShade(0.05)) }
            }
            .padding(.horizontal, lead.folderID == nil ? -4 : 0)
        }
        .contentShape(Rectangle())
        .reportFrame { f in
            model.drag.rowFrames[lead.id] = f
            if shown, let a = model.activeTab { model.activeRow.set(a.id, f, compact: false, owner: rowID) }
        }
        .onChange(of: shown ? model.activeTab?.id : nil) { old, new in
            if let old { model.activeRow.clear(old, compact: false, owner: rowID) }
            if let new, let f = model.drag.rowFrames[lead.id] { model.activeRow.set(new, f, compact: false, owner: rowID) }
        }
        .onDisappear { if let a = model.activeTab { model.activeRow.clear(a.id, compact: false, owner: rowID) } }
        .onHover { hover = $0 }
        .contextMenu {
            SplitMenu(tab: sp.selectedTab.flatMap { t in tabs.contains { $0 === t } ? t : nil } ?? lead, group: group)
            Divider()
            ForEach(tabs) { t in Menu(t.displayTitle) { TabMenu(tab: t) } }
        }
    }
}

struct SplitDivider: View {
    var color: Color = Color.primary.opacity(0.2)
    var body: some View { Capsule().fill(color).frame(width: 1.5, height: 16) }
}

/// Значок и название части строки сплита (и в самой строке, и на «мостике» поверх неё)
struct SplitSegmentLabel: View {
    let tab: Tab
    var iconOnly = false
    var dim = false
    var color: Color? = nil
    var body: some View {
        HStack(spacing: 6) {
            Favicon(url: tab.url).frame(width: 16, height: 16).opacity(dim ? 0.55 : 1)
            if !iconOnly {
                Text(tab.displayTitle).font(.system(size: 13)).lineLimit(1)
                    .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(HierarchicalShapeStyle.primary))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
    }
}

/// Подпись сплита на «мостике»: те же части, что у строки под ним
struct SplitBridgeLabel: View {
    let tabs: [Tab]
    let activeID: UUID?
    let dark: Bool
    var indent: CGFloat = 0
    var body: some View {
        let ink = dark ? Color.white : Color.black.opacity(0.85)
        HStack(spacing: 2) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { i, t in
                if i > 0 { SplitDivider(color: ink.opacity(0.25)) }
                SplitSegmentLabel(tab: t, iconOnly: tabs.count > 3, color: ink)
                    .background { if t.id == activeID { Capsule().fill(ink.opacity(0.07)) } }
            }
        }
        .padding(.leading, 2 + indent).padding(.trailing, 4)
    }
}

private struct SplitSegment: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab
    let group: [UUID]
    let active: Bool
    var iconOnly = false
    @State private var hover = false
    var body: some View {
        SplitSegmentLabel(tab: tab, iconOnly: iconOnly, dim: tab.asleep && !model.isVisible(tab))
            .background {
                if active { Capsule().fill(sidebarShade(0.08)) }
                else if hover { Capsule().fill(sidebarShade(0.05)) }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.select(tab) }
            // Подсвеченную часть можно вытянуть из сплита — куда бросишь, там и будет вкладка
            .tabDrag(tab, model: model)
            .onHover { hover = $0 }
            .help(tab.displayTitle)
            .contextMenu {
                SplitMenu(tab: tab, group: group)
                Divider()
                TabMenu(tab: tab)
            }
    }
}

/// Раздел «Split View» в правом клике: вынуть из сплита, переставить, отдельное окно, разделить всё
struct SplitMenu: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab
    let group: [UUID]
    var body: some View {
        let i = group.firstIndex(of: tab.id) ?? 0
        Section("Split View") {
            Button("Move Out of Split") { model.moveOutOfSplit(tab) }
            if i > 0 { Button(group.count == 4 && i >= 2 ? "Move Earlier" : "Move Left") { model.movePane(tab, by: -1) } }
            if i < group.count - 1 { Button(group.count == 4 && i < 2 ? "Move Later" : "Move Right") { model.movePane(tab, by: 1) } }
            Button("Open in Separate Window") { model.popOut(tab) }
            let sp = model.currentSpace
            let arr = sp.arrange(of: group)
            Menu("Arrange") {
                Button((arr == .columns ? "✓ " : "    ") + "Side by Side") { withAnimation { sp.setArrange(.columns, for: group) } }
                Button((arr == .rows ? "✓ " : "    ") + "Stacked") { withAnimation { sp.setArrange(.rows, for: group) } }
                if group.count >= 3 { Button((arr == .grid ? "✓ " : "    ") + "Grid") { withAnimation { sp.setArrange(.grid, for: group) } } }
            }
            Button("Separate All Tabs") { model.unsplit(group) }
        }
    }
}

/// В узкой колонке — столбик значков в общей капсуле
struct CompactSplitCell: View {
    @Environment(BrowserModel.self) private var model
    let group: [UUID]
    var body: some View {
        let sp = model.currentSpace
        let tabs = sp.groupTabs(group)
        let shown = tabs.contains { $0.id == sp.selectedTabID }
        VStack(spacing: 0) {
            ForEach(tabs) { t in
                Favicon(url: t.url).frame(width: 16, height: 16)
                    .frame(width: CompactSidebar.cell, height: 26)
                    .background { if shown && t.id == sp.selectedTabID { Circle().fill(sidebarShade(0.1)).frame(width: 24, height: 24) } }
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(t) }
                    .help(t.displayTitle)
            }
        }
        .padding(.vertical, 3)
        .background(Capsule().fill(shown ? AnyShapeStyle(sp.tint.opacity(0.3)) : AnyShapeStyle(sidebarShade(0.05))))
        .contextMenu { Button("Separate Tabs") { model.unsplit(group) } }
        .frame(maxWidth: .infinity)
    }
}

/// Подсветка строки, на которую бросят вкладки (откроются с ней сплитом)
struct DropHint: View {
    let space: Space
    @Environment(\.rowCorner) private var corner
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .circular)
        shape.fill(space.tint.opacity(0.22))
            .overlay(shape.strokeBorder(space.dropLine, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
    }
}

/// Капсулу панели тащат: подсвечено, куда она упадёт, и что будет
struct PaneDragOverlay: View {
    @Environment(BrowserModel.self) private var model
    var body: some View {
        GeometryReader { g in
            let o = g.frame(in: .global).origin
            if let d = model.paneDrag {
                let drop = model.paneDrop(at: d.point)
                let sp = model.currentSpace
                if case .swap(let i) = drop, let f = model.splitDrop.panes[i] {
                    let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .circular)
                    shape.fill(sp.tint.opacity(0.16))
                        .overlay(shape.strokeBorder(sp.dropLine, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                        .frame(width: f.width, height: f.height)
                        .position(x: f.midX - o.x, y: f.midY - o.y)
                }
                let label: String = {
                    switch drop {
                    case .swap: return "Swap"
                    case .sidebar: return "Move Out of Split"
                    case .outside: return "Open in Separate Window"
                    case .none: return "Drag out of the window for a separate window"
                    }
                }()
                Label(label, systemImage: drop == .sidebar ? "sidebar.left" : drop == .outside ? "macwindow" : "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .fixedSize()
                    .position(x: d.point.x - o.x, y: d.point.y - o.y + 26)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: model.paneDrag == nil)
    }
}

extension NSColor {
    /// Темнее на долю (0.4 — на 40%)
    func darker(_ k: CGFloat) -> NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        return NSColor(srgbRed: c.redComponent * (1 - k), green: c.greenComponent * (1 - k), blue: c.blueComponent * (1 - k), alpha: 1)
    }
}
