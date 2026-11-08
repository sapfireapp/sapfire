import AppKit
import SwiftUI
import WebKit

// MARK: - Групповое выделение вкладок

/// ⌘-клик — добавить/убрать вкладку, ⇧-клик — диапазон, обычный клик — сбросить.
@Observable
final class TabSelection {
    /// Своё у каждого окна; `shared` — у окна, в котором сейчас работают
    static var shared: TabSelection { BrowserModel.current.selection }
    var ids: Set<UUID> = []
    @ObservationIgnored var anchor: UUID?

    func contains(_ t: Tab) -> Bool { ids.contains(t.id) }
    func clear() { if !ids.isEmpty { ids = [] } }

    /// Выделенные вкладки текущего пространства в порядке панели.
    func tabs(in model: BrowserModel) -> [Tab] {
        (model.favorites + model.currentSpace.ordered).filter { ids.contains($0.id) }
    }

    func click(_ tab: Tab, model: BrowserModel) {
        let flags = (NSApp.currentEvent?.modifierFlags ?? []).intersection(.deviceIndependentFlagsMask)
        let list = model.currentSpace.ordered
        if flags.contains(.command) {
            if ids.isEmpty, let cur = model.currentSpace.selectedTabID, cur != tab.id { ids.insert(cur) }
            if ids.contains(tab.id) { ids.remove(tab.id) } else { ids.insert(tab.id) }
            anchor = tab.id
        } else if flags.contains(.shift) {
            let from = anchor ?? model.currentSpace.selectedTabID
            guard let a = list.firstIndex(where: { $0.id == from }),
                  let b = list.firstIndex(where: { $0.id == tab.id }) else { return click(plain: tab, model: model) }
            ids = Set(list[min(a, b)...max(a, b)].map(\.id))
        } else {
            click(plain: tab, model: model)
        }
    }

    private func click(plain tab: Tab, model: BrowserModel) {
        clear()
        anchor = tab.id
        model.select(tab)
    }
}

// MARK: - Перетаскивание

enum DropTarget: Equatable {
    case list(Int)        // позиция среди незакреплённых
    case pinned(Int)      // позиция среди закреплённых
    case space(UUID)      // в другое пространство
    case favorites(Int)   // позиция в «Избранном» (общем для всех пространств)
    case folder(UUID, Int) // позиция внутри папки
    case split(Int?)       // на страницу: новой панелью сплита (или вместо панели с этим номером)
    case nest(UUID)        // папку — внутрь другой папки (на её шапку)
    case splitWith(UUID)   // вкладки — на середину строки вкладки: сплит с ней
}

@Observable
final class TabDrag {
    /// Своё у каждого окна; `shared` — у окна, в котором сейчас работают
    static var shared: TabDrag { BrowserModel.current.drag }
    static let space = "sidebar"

    var ids: [UUID] = []
    var location: CGPoint?
    var target: DropTarget?
    var active: Bool { location != nil }
    /// Край панели, у которого держат вкладку: -1 — левый (предыдущее пространство), +1 — правый (следующее)
    var edge: Int = 0
    /// Папка, на шапку которой сейчас наведены вкладки (бросок — в конец папки)
    var hoverFolder: UUID?
    /// Вкладка, на середину которой наведены вкладки (бросок — сплит с ней)
    var hoverTab: UUID? { if case .splitWith(let id) = target { return id }; return nil }
    /// Разделитель «сохранённое / временное» и где над ним курсор: бросил выше — вкладка сохранена
    @ObservationIgnored var dividerFrame: CGRect = .zero
    @ObservationIgnored var aboveDivider = false
    /// Перетаскивается папка целиком (а не вкладки)
    var folderDrag: UUID?

    // Рамки элементов панели в её системе координат (без перерисовки)
    @ObservationIgnored var rowFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var pinnedFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var pinnedZone: CGRect = .zero
    @ObservationIgnored var pillZone: CGRect = .zero
    @ObservationIgnored var favFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var headerFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var favZone: CGRect = .zero
    @ObservationIgnored var navZone: CGRect = .zero
    @ObservationIgnored var listZone: CGRect = .zero
    @ObservationIgnored var spaceFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var bounds: CGRect = .zero
    @ObservationIgnored private var edgeWork: DispatchWorkItem?
    static let edgeWidth: CGFloat = 18

    @ObservationIgnored private var upMonitor: Any?
    @ObservationIgnored private var moveMonitor: Any?

    /// Жест вкладки только начинает перетаскивание — дальше следим за мышью сами:
    /// при переключении пространства исходная вкладка исчезает из панели, и её жест замирает.
    func changed(_ tab: Tab, at p: CGPoint, model: BrowserModel) {
        guard location == nil else { return }
        let sel = model.selection
        ids = sel.contains(tab) ? sel.tabs(in: model).map(\.id) : [tab.id]
        begin(at: p, model: model)
    }

    /// Папку тащат за шапку — её можно поставить между вкладками и другими папками.
    func changedFolder(_ f: Folder, at p: CGPoint, model: BrowserModel) {
        guard location == nil else { return }
        ids = []
        folderDrag = f.id
        model.folderPeek.close(now: true)
        begin(at: p, model: model)
    }

    /// Строки верхнего уровня без тех, что сейчас тащат.
    func visibleEntries(_ sp: Space) -> [Space.Entry] {
        sp.entries.filter { e in
            switch e {
            case .tab(let t): return !ids.contains(t.id)
            case .folder(let f): return f.id != folderDrag
            }
        }
    }

    private func begin(at p: CGPoint, model: BrowserModel) {
        NSCursor.closedHand.push()
        upMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] e in
            DispatchQueue.main.async { self?.ended(model: model) }
            return e
        }
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] e in
            if let self, let win = e.window, let content = win.contentView {
                let rect = model.swipe.sidebarRect
                let q = CGPoint(x: e.locationInWindow.x - rect.minX,
                                y: content.bounds.height - e.locationInWindow.y - rect.minY)
                self.update(q, model: model)
            }
            return e
        }
        update(p, model: model)
    }

    private func update(_ p: CGPoint, model: BrowserModel) {
        location = p
        updateEdge(p, model: model)
        var header: UUID?
        let t = computeTarget(p, model: model, header: &header)
        if header != hoverFolder { hoverFolder = header }
        if t != target { target = t; if t != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) } }
    }

    func ended(model: BrowserModel) {
        guard location != nil else { return }
        if let m = upMonitor { NSEvent.removeMonitor(m); upMonitor = nil }
        if let m = moveMonitor { NSEvent.removeMonitor(m); moveMonitor = nil }
        if let fid = folderDrag, case .nest(let pid) = target {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.nest(fid, into: pid) }
        } else if let fid = folderDrag, case .list(let i) = target {
            let saved = aboveDivider
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.moveFolder(fid, to: i, saved: saved) }
        } else if let fid = folderDrag, case .space(let sid) = target,
                  let f = model.currentSpace.folders.first(where: { $0.id == fid }),
                  let dest = model.spaces.first(where: { $0.id == sid }) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.move(folder: f, to: dest) }
        } else if case .split(let r) = target, let t = model.allTabs.first(where: { $0.id == ids.first }) {
            model.openInSplit(t, replacing: r)
        } else if case .splitWith(let tid) = target, let t = model.allTabs.first(where: { $0.id == tid }) {
            model.split(ids, with: t)
        } else if let target, !ids.isEmpty {
            let saved = aboveDivider
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.moveTabs(ids, to: target, saved: saved) }
        }
        NSCursor.pop()
        edgeWork?.cancel(); edgeWork = nil
        location = nil; target = nil; ids = []; edge = 0; hoverFolder = nil; folderDrag = nil
        pillZone = .zero     // заглушка «закрепить» исчезла — её место больше не цель
    }

    /// Соседнее пространство в сторону края (или nil, если его нет).
    func neighbor(_ dir: Int, model: BrowserModel) -> Space? {
        guard dir != 0, let i = model.spaces.firstIndex(where: { $0.id == model.currentSpaceID }) else { return nil }
        return model.neighborSpace(from: i, dir).map { model.spaces[$0] }
    }

    /// Держишь вкладку у края панели — через полсекунды панель переключается на соседнее пространство.
    private func updateEdge(_ p: CGPoint, model: BrowserModel) {
        var dir = 0
        guard folderDrag == nil else { return }
        if bounds.width > 0 {
            if p.x < bounds.minX + Self.edgeWidth { dir = -1 }
            else if p.x > bounds.maxX - Self.edgeWidth { dir = 1 }
        }
        if neighbor(dir, model: model) == nil { dir = 0 }
        guard dir != edge else { return }
        edge = dir
        edgeWork?.cancel(); edgeWork = nil
        guard dir != 0 else { return }
        armEdge(model: model)
    }

    private func armEdge(model: BrowserModel) {
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.active, let dest = self.neighbor(self.edge, model: model),
                  let i = model.spaces.firstIndex(where: { $0.id == dest.id }) else { return }
            model.swipe.switchTo(i, model: model)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            // Всё ещё у края — дальше листаем, пока есть куда
            if self.neighbor(self.edge, model: model) != nil { self.armEdge(model: model) } else { self.edge = 0 }
        }
        edgeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: w)
    }

    private func computeTarget(_ p: CGPoint, model: BrowserModel, header: inout UUID?) -> DropTarget? {
        let sp = model.currentSpace
        if let s = splitTarget(p, model: model) { return s }
        if folderDrag != nil {
            // Папка — в список (между строками верхнего уровня) или на значок другого пространства
            for (id, f) in spaceFrames where id != sp.id && f.insetBy(dx: -2, dy: -4).contains(p) {
                if model.spaces.first(where: { $0.id == id })?.isIncognito != sp.isIncognito { return nil }
                return .space(id)
            }
            return listTarget(p, sp: sp, header: &header)
        }
        if edge != 0, let n = neighbor(edge, model: model) { return .space(n.id) }
        // «Избранное»: если пусто — бросать на верхний ряд панели
        let favs = model.favorites.filter { !ids.contains($0.id) }
        if !favs.isEmpty, favZone.insetBy(dx: 0, dy: -4).contains(p) {
            for (i, c) in favs.enumerated() {
                guard let f = favFrames[c.id] else { continue }
                if p.y < f.minY - 3 || (p.y <= f.maxY + 3 && p.x < f.midX) { return .favorites(i) }
            }
            return .favorites(favs.count)
        }
        for (id, f) in spaceFrames where id != sp.id && f.insetBy(dx: -2, dy: -4).contains(p) {
            // В инкогнито и из него не бросаем
            if model.spaces.first(where: { $0.id == id })?.isIncognito != sp.isIncognito { return nil }
            return .space(id)
        }
        if sp.pinned.allSatisfy({ ids.contains($0.id) }), pillZone.insetBy(dx: 0, dy: -4).contains(p) {
            return .pinned(0)
        }
        if !sp.pinned.isEmpty, pinnedZone.insetBy(dx: 0, dy: -4).contains(p) {
            let cells = sp.pinned.filter { !ids.contains($0.id) }
            for (i, c) in cells.enumerated() {
                guard let f = pinnedFrames[c.id] else { continue }
                if p.y < f.minY - 3 || (p.y <= f.maxY + 3 && p.x < f.midX) { return .pinned(i) }
            }
            return .pinned(cells.count)
        }
        return listTarget(p, sp: sp, header: &header)
    }

    private func listTarget(_ p: CGPoint, sp: Space, header: inout UUID?) -> DropTarget? {
        // Сам разделитель — тоже место броска: верхние ⅔ — в конец сохранённого (под последнюю папку),
        // нижняя треть — в начало временных. Иначе между папкой и разделителем щель в пару точек
        aboveDivider = dividerFrame != .zero && p.y < dividerFrame.minY + dividerFrame.height * 0.66
        if dividerFrame != .zero, dividerFrame.insetBy(dx: 0, dy: -2).contains(p) {
            let saved = visibleEntries(sp).filter { !$0.isTemp }.count
            return .list(saved)
        }
        if listZone.insetBy(dx: 0, dy: -8).contains(p) {
            // Папку — на шапку другой папки: внутрь (если позволяет глубина)
            if let fid = folderDrag, let f = sp.folders.first(where: { $0.id == fid }),
               let into = folderUnder(p, sp: sp, dragging: f) {
                header = into.id
                return .nest(into.id)
            }
            let top = visibleEntries(sp)
            for (k, e) in top.enumerated() {
                switch e {
                case .tab(let t):
                    if sp.hiddenInSplit(t) { continue }          // часть сплита — её строку рисует сплит
                    guard let r = rowFrames[t.id] else { continue }
                    if folderDrag == nil, let s = splitZone(t, r, p, sp) { return s }
                    if p.y < r.midY { return .list(k) }
                case .folder(let f):
                    guard let h = headerFrames[f.id] else { continue }
                    if folderDrag != nil {
                        // Папку в список — только между строками верхнего уровня
                        if p.y < (h.minY + blockBottom(f, sp)) / 2 { return .list(k) }
                        continue
                    }
                    if p.y < h.minY + 7 { return .list(k) }                     // над папкой
                    if let t = inside(f, p, sp: sp, header: &header) { return t }
                }
            }
            return .list(top.count)
        }
        return nil
    }

    private func left(_ f: Folder, _ sp: Space) -> [Tab] { sp.tabs(in: f).filter { !ids.contains($0.id) } }

    /// Вкладки над папкой `f` (курсор ниже верха её шапки): на шапку — в конец папки, между строками —
    /// на это место, во вложенную — туда. nil — курсор ниже всей папки.
    private func inside(_ f: Folder, _ p: CGPoint, sp: Space, header: inout UUID?) -> DropTarget? {
        guard let h = headerFrames[f.id] else { return nil }
        if p.y <= h.maxY - 7 { header = f.id; return .folder(f.id, left(f, sp).count) }
        guard f.expanded else { return nil }
        for sub in sp.subfolders(of: f) {
            guard let sh = headerFrames[sub.id] else { continue }
            if p.y < sh.minY + 7 { return .folder(f.id, 0) }            // над вложенной — в начало этой папки
            if let t = inside(sub, p, sp: sp, header: &header) { return t }
        }
        let tabs = left(f, sp).filter { !sp.hiddenInSplit($0) }
        for (j, t) in tabs.enumerated() {
            guard let r = rowFrames[t.id], p.y < r.maxY else { continue }
            if let s = splitZone(t, r, p, sp) { return s }
            return .folder(f.id, p.y < r.midY ? j : j + 1)              // между вкладками внутри
        }
        return nil
    }

    /// Середина строки вкладки (не края) — сюда бросают, чтобы открыть рядом сплитом
    private func splitZone(_ t: Tab, _ r: CGRect, _ p: CGPoint, _ sp: Space) -> DropTarget? {
        guard r.insetBy(dx: 0, dy: 9).contains(p), !ids.contains(t.id) else { return nil }
        let room = Space.maxPanes - (sp.group(of: t.id)?.count ?? 1)
        return room > 0 ? .splitWith(t.id) : nil
    }

    /// Нижний край папки со всем вложенным (что сейчас видно)
    func blockBottom(_ f: Folder, _ sp: Space) -> CGFloat {
        var y = headerFrames[f.id]?.maxY ?? 0
        guard f.expanded else { return y }
        for sub in sp.subfolders(of: f) { y = max(y, blockBottom(sub, sp)) }
        for r in left(f, sp).compactMap({ rowFrames[$0.id] }) { y = max(y, r.maxY) }
        return y
    }

    /// Шапка папки под курсором, в которую можно вложить `dragging`
    private func folderUnder(_ p: CGPoint, sp: Space, dragging: Folder) -> Folder? {
        for f in sp.folders where f !== dragging {
            guard let h = headerFrames[f.id], h.insetBy(dx: 0, dy: 7).contains(p) else { continue }
            // Шапка может быть от свёрнутой (невидимой) вложенной — проверяем, что все родители раскрыты
            var up = sp.parent(of: f), shown = true
            while let u = up { if !u.expanded { shown = false }; up = sp.parent(of: u) }
            guard shown else { continue }
            return BrowserModel.shared.canNest(dragging, into: f) ? f : nil
        }
        return nil
    }

    /// Где рисовать линию вставки (в координатах панели).
    func indicator(model: BrowserModel) -> (CGRect, Bool)? {
        let sp = model.currentSpace
        switch target {
        case .list(let i):
            let top = visibleEntries(sp)
            func topY(_ e: Space.Entry) -> CGFloat? {
                switch e {
                case .tab(let t): return rowFrames[t.id]?.minY
                case .folder(let f): return headerFrames[f.id].map { $0.minY - (f.expanded ? 3 : 0) }
                }
            }
            func bottomY(_ e: Space.Entry) -> CGFloat? {
                switch e {
                case .tab(let t): return rowFrames[t.id]?.maxY
                case .folder(let f):
                    guard headerFrames[f.id] != nil else { return nil }
                    let b = blockBottom(f, sp)
                    return f.expanded ? b + 3 : b
                }
            }
            let y: CGFloat
            let savedCount = top.filter { !$0.isTemp }.count
            if i == savedCount, dividerFrame != .zero {
                // На стыке сохранённого и временных линия — над разделителем (сохранить) или под ним
                y = aboveDivider ? dividerFrame.minY + 1 : dividerFrame.maxY - 1
            } else if i < top.count, let t = topY(top[i]) { y = t - 1 }
            else if let last = top.last, let b = bottomY(last) { y = b + 1 }
            else { y = listZone.minY + 2 }
            return (CGRect(x: listZone.minX + 4, y: y - 1, width: listZone.width - 8, height: 2), false)
        case .folder(let fid, let i):
            // Шапка подсвечивается сама; линию рисуем только внутри раскрытой папки
            guard hoverFolder == nil, let f = sp.folders.first(where: { $0.id == fid }), f.expanded else { return nil }
            let rows = sp.tabs(in: f).filter { !ids.contains($0.id) }.compactMap { rowFrames[$0.id] }
            let subs = sp.subfolders(of: f)
            let y: CGFloat
            if i < rows.count { y = rows[i].minY - 1 }
            else if let last = rows.last { y = last.maxY + 1 }
            else if let lastSub = subs.last, headerFrames[lastSub.id] != nil { y = blockBottom(lastSub, sp) + 3 }
            else if let h = headerFrames[fid] { y = h.maxY + 1 } else { return nil }
            let x = listZone.minX + 16 + CGFloat(sp.depth(of: f)) * 4
            return (CGRect(x: x, y: y - 1, width: listZone.maxX - 4 - x, height: 2), false)
        case .pinned(let i):
            let cells = sp.pinned.filter { !ids.contains($0.id) }.compactMap { pinnedFrames[$0.id] }
            if cells.isEmpty { return nil }      // пустую область подсвечивает сама заглушка (PinDropPlaceholder)
            let f = i < cells.count ? cells[i] : cells[cells.count - 1]
            let x = i < cells.count ? f.minX - 3 : f.maxX + 3
            return (CGRect(x: x - 1, y: f.minY + 4, width: 2, height: f.height - 8), false)
        case .favorites(let i):
            let cells = model.favorites.filter { !ids.contains($0.id) }.compactMap { favFrames[$0.id] }
            if cells.isEmpty { return (navZone, true) }
            let f = i < cells.count ? cells[i] : cells[cells.count - 1]
            let x = i < cells.count ? f.minX - 4 : f.maxX + 4
            return (CGRect(x: x - 1, y: f.minY + 8, width: 2, height: f.height - 16), false)
        default:
            return nil
        }
    }
}

extension BrowserModel {
    /// Переставить папку на место `i` среди строк верхнего уровня.
    func moveFolder(_ fid: UUID, to i: Int, saved: Bool = true) {
        checkpoint("Move Folder")
        let sp = currentSpace
        // Вложенная папка, брошенная в общий список, выходит на верхний уровень;
        // над чертой «Temp» — сохранённая, под ней — временная (уйдёт в архив целиком)
        if let f = sp.folders.first(where: { $0.id == fid }) {
            f.parentID = nil
            if f.isTemp == saved { f.isTemp = !saved; f.touched = Date() }
            for d in sp.descendants(of: f) { d.isTemp = false }
        }
        sp.normalize()
        var layout = sp.layout.filter { $0 != fid }
        layout.insert(fid, at: min(i, layout.count))
        sp.layout = layout
        sp.normalize()
    }

    /// Переставляет вкладки (сохраняя их порядок) в список, закреплённые или другое пространство.
    /// `saved` — для списка: встают над разделителем (сохранённые) или под ним (временные)
    func moveTabs(_ ids: [UUID], to target: DropTarget, saved: Bool = false) {
        checkpoint(ids.count > 1 ? "Move Tabs" : "Move Tab")
        // Перетащил сам — значит, вкладка уже не случайная веточка
        defer { for id in ids { allTabs.first { $0.id == id }?.isBranch = false } }
        let sp = currentSpace
        // Инкогнито — плоский список: без закреплённых, «Избранного», папок и сохранённого (всё равно сотрётся)
        var saved = saved
        if sp.isIncognito {
            switch target {
            case .pinned, .favorites, .folder, .nest: showToast("Incognito keeps a plain list — nothing to pin or file"); return
            default: saved = false
            }
        }
        // Вкладки могут быть и из другого пространства или из «Избранного» (панель переключили прямо во время перетаскивания)
        // Между инкогнито и обычными пространствами вкладки не переносятся
        let moving = ids.compactMap { id in allTabs.first { $0.id == id } }
            .filter { t in (space(of: t)?.isIncognito ?? false) == sp.isIncognito || { if case .space = target { return true }; return false }() }
        guard !moving.isEmpty else { return }
        // Вкладку вытянули из сплита (в список, папку, закреплённые, другое пространство) — из группы она уходит
        switch target {
        case .split, .splitWith, .nest: break
        default: for t in moving { (space(of: t) ?? sp).leavePanes(t.id) }
        }
        switch target {
        case .split(let r):
            if let t = moving.first { openInSplit(t, replacing: r) }
        case .nest:
            break
        case .splitWith(let tid):
            if let t = allTabs.first(where: { $0.id == tid }) { split(ids, with: t) }
        case .folder(let fid, let i):
            for t in moving where space(of: t) !== sp { move(t, to: sp) }
            var inFolder = sp.tabs.filter { $0.folderID == fid && !ids.contains($0.id) }
            for t in moving { t.isPinned = false; t.folderID = fid }
            inFolder.insert(contentsOf: moving, at: min(i, inFolder.count))
            sp.tabs = sp.tabs.filter { $0.folderID != fid } + inFolder
            sp.normalize()
        case .favorites(let i):
            // Из пространства в «Избранное»: открытая вкладка так и остаётся открытой
            for t in moving {
                t.folderID = nil
                if let from = space(of: t) { from.tabs.removeAll { $0 === t } }
                t.isPinned = false
            }
            var favs = favorites.filter { !ids.contains($0.id) }
            favs.insert(contentsOf: moving, at: min(i, favs.count))
            favorites = favs
        case .space(let sid):
            guard let dest = spaces.first(where: { $0.id == sid }) else { return }
            // На значок инкогнито — те же адреса новыми вкладками инкогнито; из инкогнито в обычное — нельзя
            let cross = moving.filter { (space(of: $0)?.isIncognito ?? false) != dest.isIncognito }
            if !cross.isEmpty {
                if dest.isIncognito { openInIncognito(cross) }
                else { showToast("Incognito tabs stay in incognito") }
                return
            }
            for t in moving.reversed() { move(t, to: dest) }
            selection.clear()
            showToast(moving.count == 1 ? "Tab moved to “\(dest.name)”" : "\(moving.count) tabs moved to “\(dest.name)”")
        case .list(let i), .pinned(let i):
            let toPinned: Bool = { if case .pinned = target { return true }; return false }()
            // Закреплённые живут у «хозяина» набора (если пространство берёт их у другого)
            let home = toPinned ? sp.pinOwner : sp
            let keepSelected = moving.filter { sp.selectedTabID == $0.id }.map(\.id)
            for t in moving where space(of: t) !== home { move(t, to: home) }
            home.normalize()
            var pinned = home.ownPinned.filter { !ids.contains($0.id) }
            let rest = home.tabs.filter { !$0.isPinned && !ids.contains($0.id) }
            for t in moving {
                // Закрепил — запомнить адрес, куда он будет возвращаться
                if toPinned && !t.isPinned { t.pinnedURL = t.url; TidyTitles.pinned(t) }
                t.isPinned = toPinned; t.folderID = nil; t.isSaved = !toPinned && saved
            }
            // Верхний уровень списка: вкладки встают между папками и вкладками по индексу
            var layout = home.layout.filter { !ids.contains($0) }
            if toPinned { pinned.insert(contentsOf: moving, at: min(i, pinned.count)) }
            else { layout.insert(contentsOf: moving.map(\.id), at: min(i, layout.count)) }
            home.tabs = pinned + rest + (toPinned ? [] : moving)
            home.layout = layout
            home.normalize()
            if home !== sp { sp.normalize() }
            // Закрепил открытую вкладку — она остаётся открытой здесь
            if let id = keepSelected.first { sp.selectedTabID = id }
        }
    }

    // Групповые команды

    /// ⌘D: несколько выделенных — дублировать все (с вопросом), иначе — активную вкладку.
    func duplicateSelectionOrActive() {
        let sel = selection.tabs(in: self)
        if sel.count > 1 {
            let a = NSAlert()
            a.messageText = "Duplicate \(sel.count) tabs?"
            a.informativeText = "Each selected tab will be opened once more, right next to the original."
            a.addButton(withTitle: "Duplicate")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { duplicate(sel) }
        } else if let t = sel.first ?? activeTab {
            duplicate([t], select: true)
        }
    }

    /// Копия вкладки встаёт сразу после оригинала (копия избранного — в начало списка пространства).
    func duplicate(_ tabs: [Tab], select: Bool = false) {
        checkpoint("Duplicate")
        let sp = currentSpace
        var last: Tab?
        for t in tabs {
            guard let url = t.url else { continue }
            let copy = Tab(url: url, title: t.title, isPinned: false)
            copy.browser = self
            copy.customTitle = t.customTitle
            if t.isPinned || isFavorite(t) {
                // Копия закреплённого (или из «Избранного») — обычная временная вкладка, сверху временных
                sp.tabs.insert(copy, at: 0)
                sp.normalize()
            } else {
                copy.folderID = t.folderID
                let home = space(of: t) ?? sp
                if let i = home.tabs.firstIndex(where: { $0 === t }) { home.tabs.insert(copy, at: i + 1) }
                else { home.tabs.insert(copy, at: 0) }
            }
            last = copy
        }
        if select, let last { self.select(last) }
        let what = tabs.count > 1 ? "Duplicated \(tabs.count) tabs" : "Tab duplicated"
        if !select, let last { notify(what, icon: "plus.square.on.square", action: "Show") { [weak self, weak last] in if let last { self?.select(last) } } }
        else { notify(what, icon: "plus.square.on.square") }
    }
    func reload(_ tabs: [Tab]) { tabs.forEach { $0.reload() } }
    func close(_ tabs: [Tab]) { checkpoint("Close \(tabs.count) Tabs"); tabs.forEach { close($0) }; selection.clear() }
    func sleep(_ tabs: [Tab]) { tabs.filter { !isVisible($0) }.forEach { $0.sleep() } }
    func setPinned(_ tabs: [Tab], _ on: Bool) {
        moveTabs(tabs.map(\.id), to: on ? .pinned(currentSpace.pinned.count) : .list(0))
    }
}

// MARK: - Меню для группы

struct GroupMenu: View {
    @Environment(BrowserModel.self) private var model
    var body: some View {
        let tabs = model.selection.tabs(in: model)
        let n = tabs.count
        Button("Reload (\(n))") { model.reload(tabs) }
        Button("Duplicate (\(n))") { model.duplicate(tabs) }
        if !model.currentSpace.isIncognito {
            Button("New Folder with \(n) Tabs…") { model.newFolder(with: tabs) }
            MoveToFolderMenu(tabs: tabs)
            if tabs.contains(where: { !$0.isPinned }) {
                Button("Pin (\(n))") { model.setPinned(tabs, true) }
            } else {
                Button("Unpin (\(n))") { model.setPinned(tabs, false) }
            }
        }
        Button("Copy Links") {
            let s = tabs.compactMap { $0.url?.absoluteString }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            model.showToast("Copied \(n) links")
        }
        let incog = model.currentSpace.isIncognito
        let others = model.spaces.filter { $0.id != model.currentSpaceID && $0.isIncognito == incog }
        if !others.isEmpty {
            Menu("Move to Space") {
                ForEach(others) { s in
                    Button { model.moveTabs(tabs.map(\.id), to: .space(s.id)) } label: { Label(s.name, systemImage: Symbols.open(s.icon)) }
                }
            }
        }
        if !incog {
            Button("Open in Incognito (\(n))") { model.openInIncognito(tabs) }
        }
        Button("Sleep (\(n))") { model.sleep(tabs) }
        Divider()
        Menu("Sort By") {
            ForEach(TabOrder.allCases, id: \.self) { o in Button(o.title) { model.sort(tabs, by: o) } }
        }
        if tabs.contains(where: { !$0.isPinned }), !model.currentSpace.isIncognito {
            Menu("Group By") {
                ForEach(TabOrder.allCases, id: \.self) { o in Button(o.groupTitle) { model.group(tabs, by: o) } }
            }
        }
        Divider()
        Button("Close (\(n))") { model.close(tabs) }
    }
}

// MARK: - Вспомогательное

extension View {
    /// Сообщает рамку вида в системе координат панели.
    func reportFrame(_ store: @escaping (CGRect) -> Void) -> some View {
        background(GeometryReader { g in
            let f = g.frame(in: .named(TabDrag.space))
            Color.clear
                .onAppear { store(f) }
                .onChange(of: f) { store(f) }
        })
    }

    /// Жест перетаскивания вкладки.
    func tabDrag(_ tab: Tab, model: BrowserModel) -> some View {
        gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named(TabDrag.space))
            .onChanged { model.drag.changed(tab, at: $0.location, model: model) }
            .onEnded { _ in model.drag.ended(model: model) })
    }
}

/// Карточка, которая едет под курсором при перетаскивании.
struct DragGhost: View {
    @Environment(BrowserModel.self) private var model
    private var drag: TabDrag { model.drag }

    var body: some View {
        if let p = drag.location, let fid = drag.folderDrag, let f = model.currentSpace.folders.first(where: { $0.id == fid }) {
            HStack(spacing: 8) {
                Image(systemName: f.icon + (f.icon == "folder" ? ".fill" : "")).foregroundStyle(f.color)
                Text(f.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(model.currentSpace.allTabs(in: f).count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(width: 200, height: 32, alignment: .leading)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3))
            .rotationEffect(.degrees(-1.5))
            .position(x: p.x + 60, y: p.y + 6)
            .allowsHitTesting(false)
        } else if let p = drag.location, let first = model.allTabs.first(where: { $0.id == drag.ids.first }) {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    Favicon(url: first.url).frame(width: 16, height: 16)
                    Text(first.displayTitle).font(.system(size: 13)).lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(width: 200, height: 32, alignment: .leading)
                .background {
                    // Несколько вкладок — «стопка» карточек
                    ZStack {
                        if drag.ids.count > 1 {
                            Capsule().fill(Color(nsColor: .controlBackgroundColor))
                                .offset(x: 4, y: 4).opacity(0.7)
                        }
                        Capsule().fill(Color(nsColor: .controlBackgroundColor))
                    }
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                }
                if drag.ids.count > 1 {
                    Text("\(drag.ids.count)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 6, y: -8)
                }
            }
            .rotationEffect(.degrees(-1.5))
            .position(x: p.x + 60, y: p.y + 6)
            .allowsHitTesting(false)
        }
    }
}

/// Линия (или подсвеченная зона), куда упадут вкладки.
struct DropIndicator: View {
    @Environment(BrowserModel.self) private var model
    private var drag: TabDrag { model.drag }

    var body: some View {
        if drag.active, let (r, zone) = drag.indicator(model: model) {
            if zone {
                Capsule().fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(Capsule().fill(model.currentSpace.tint.opacity(0.25)))
                    .overlay(Capsule().stroke(model.currentSpace.dropLine, lineWidth: 1.5))
                    .overlay(Label(drag.target == .favorites(0) ? "Favorite" : "Pin",
                                   systemImage: drag.target == .favorites(0) ? "star.fill" : "pin.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.currentSpace.iconColor))
                    .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
            } else {
                Capsule().fill(model.currentSpace.dropLine)
                    .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                    .animation(.easeOut(duration: 0.12), value: r)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Подсказка у края панели: цвет и значок пространства, куда уедет вкладка.
struct EdgeHint: View {
    @Environment(BrowserModel.self) private var model
    private var drag: TabDrag { model.drag }

    var body: some View {
        if drag.active, drag.edge != 0, let n = drag.neighbor(drag.edge, model: model), let p = drag.location {
            let left = drag.edge < 0
            let b = drag.bounds
            // Кружок со значком соседнего пространства у кромки, чуть выше перетаскиваемых вкладок
            Image(systemName: n.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(n.iconColor)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(n.dropLine, lineWidth: 2))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                .position(x: left ? b.minX + 17 : b.maxX - 17,
                          y: min(max(p.y - 34, b.minY + 30), b.maxY - 30))
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Свайп по панели — листать пространства

@Observable
final class SpaceSwipe {
    /// Своё у каждого окна; `shared` — у окна, в котором сейчас работают
    static var shared: SpaceSwipe { BrowserModel.current.swipe }
    var offset: CGFloat = 0
    var progress: CGFloat = 0                 // 0…1 — насколько свайп продвинулся к соседу
    @ObservationIgnored var neighborID: UUID?
    var direction = 1                         // куда едет новое пространство: +1 — следующее
    /// Сдвиг списка в момент переключения (свайп отпустили не с нуля)
    @ObservationIgnored var releaseOffset: CGFloat = 0
    /// Текущий жест двумя пальцами — над страницей
    @ObservationIgnored private var onPage = false
    @ObservationIgnored var sidebarRect: CGRect = .zero   // в координатах окна (сверху вниз)
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var acc = CGSize.zero
    @ObservationIgnored private var tracking: Bool?      // nil — ещё не понятно, горизонтальный ли жест
    @ObservationIgnored private var swallowMomentum = false
    @ObservationIgnored private var movingWindow = false
    @ObservationIgnored private var watchdog: DispatchWorkItem?
    static let threshold: CGFloat = 60
    /// Полоса у верхнего края окна, где свайп двумя пальцами двигает окно
    static let topBand: CGFloat = 40

    func switchTo(_ i: Int, model: BrowserModel, direction dir: Int? = nil) {
        guard let cur = model.spaces.firstIndex(where: { $0.id == model.currentSpaceID }), cur != i,
              model.spaces.indices.contains(i), !model.focusOwner(of: model.spaces[i]) else { return }
        direction = dir ?? (i > cur ? 1 : -1)
        releaseOffset = offset          // откуда уезжает старое (где его отпустили пальцы)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            offset = 0
            progress = 0
            model.switchSpace(i)
        }
    }

    /// Цвет пространства с плавным переходом к соседу по ходу свайпа.
    /// Цвет панели; во время свайпа — плавно между двумя пространствами
    func panel(_ model: BrowserModel) -> Color {
        let base = model.currentSpace.panel
        guard progress > 0, let n = model.spaces.first(where: { $0.id == neighborID }) else { return Color(nsColor: base) }
        let a = base.usingColorSpace(.sRGB) ?? .gray
        let b = n.panel.usingColorSpace(.sRGB) ?? .gray
        return Color(nsColor: a.blended(withFraction: progress, of: b) ?? a)
    }

    func tint(_ model: BrowserModel) -> Color {
        let base = model.currentSpace.tint
        guard progress > 0, let n = model.spaces.first(where: { $0.id == neighborID }) else { return base }
        let a = NSColor(base).usingColorSpace(.sRGB) ?? .gray
        let b = NSColor(n.tint).usingColorSpace(.sRGB) ?? .gray
        return Color(nsColor: a.blended(withFraction: progress, of: b) ?? a)
    }

    func start(model: BrowserModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak model] e in
            guard let self, let model, e.window != nil, e.window === model.mainWindow else { return e }   // только своё окно
            return self.handle(e, model: model) ? nil : e
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    /// true — событие съедено панелью.
    private func handle(_ e: NSEvent, model: BrowserModel) -> Bool {
        // Открытая командная строка: свайп по ней двигает её саму (с инерцией)
        if model.commandBar != nil, e.hasPreciseScrollingDeltas, let win = e.window, let content = win.contentView {
            let p = CGPoint(x: e.locationInWindow.x, y: content.bounds.height - e.locationInWindow.y)
            if model.commandPos.scroll(e, at: p, window: win) { return true }
        }
        // Шла прокрутка пальцами — касание тремя пальцами не тап (инерция после — не в счёт: пальцы уже не двигаются)
        if e.momentumPhase.isEmpty { ThreeFingerGestures.lastScroll = Date() }
        if !e.momentumPhase.isEmpty { return swallowMomentum }
        guard e.hasPreciseScrollingDeltas, let win = e.window, let content = win.contentView,
              !model.drag.active else { return false }
        let p = CGPoint(x: e.locationInWindow.x, y: content.bounds.height - e.locationInWindow.y)

        // Два пальца у верхнего края — тащим окно, как за заголовок
        if e.phase.contains(.began) {
            swallowMomentum = false
            movingWindow = Gestures.window && p.y < Self.topBand && !win.styleMask.contains(.fullScreen)
        }
        if movingWindow {
            let s: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
            let dx = e.scrollingDeltaX * s, dy = -e.scrollingDeltaY * s
            var o = win.frame.origin
            o.x += dx; o.y += dy
            win.setFrameOrigin(o)
            // Курсор едет вместе с окном — будто держишь окно за точку под пальцами
            let m = NSEvent.mouseLocation
            let screenH = NSScreen.screens.first?.frame.height ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: m.x + dx, y: screenH - (m.y + dy)))
            CGAssociateMouseAndMouseCursorPosition(1)
            if e.phase.contains(.ended) || e.phase.contains(.cancelled) { movingWindow = false; swallowMomentum = true }
            return true
        }

        // Жест начался над страницей (не над панелью) — это «назад / вперёд» по странице
        if e.phase.contains(.began) || e.phase.contains(.mayBegin) {
            onPage = !((model.sidebarVisible || model.sidebarPeek) && sidebarRect.contains(p))
        }
        if onPage {
            guard win === model.mainWindow, Gestures.pages else { return false }
            // Листаем страницу — её вертикальная прокрутка стоит (и инерция после жеста тоже)
            let used = PageSwipe.shared.handle(e, at: p, model: model)
            if used, e.phase.contains(.ended) || e.phase.contains(.cancelled) { swallowMomentum = true }
            return used
        }

        guard Gestures.spaces, model.sidebarVisible || model.sidebarPeek else { return false }
        // Касание начинается с «может начаться» (mayBegin) — сбрасываем накопленное уже тогда:
        // иначе первое событие жеста берёт сдвиг прошлого свайпа, и всё прыгает вбок
        if e.phase.contains(.began) || e.phase.contains(.mayBegin) {
            acc = .zero; tracking = nil; swallowMomentum = false
            guard sidebarRect.contains(p) else { tracking = false; return false }
        }
        guard tracking != false else { return false }

        // Пальцы вправо — предыдущее пространство, влево — следующее (как у страниц)
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        acc.width += e.scrollingDeltaX * sign
        acc.height += e.scrollingDeltaY

        if tracking == nil {
            if abs(acc.width) > 8, abs(acc.width) > abs(acc.height) * 1.5 { tracking = true }
            else if abs(acc.height) > 8 { tracking = false; return false }
            // Пока не ясно, куда жест: горизонтальные события не отдаём списку — иначе он сам
            // на кадр сдвигается вбок (пружинит), и при свайпе содержимое дёргается
            else if !e.phase.contains(.ended) { return abs(acc.width) >= abs(acc.height) }
        }
        guard tracking == true else { return false }

        let cur = model.spaces.firstIndex { $0.id == model.currentSpaceID } ?? 0
        let dir = acc.width < 0 ? 1 : -1
        // Сосед — ближайшее пространство, не открытое в другом окне
        let next = model.neighborSpace(from: cur, dir)
        let hasNeighbor = next != nil

        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            tracking = nil
            swallowMomentum = true
            defer { acc = .zero }
            if hasNeighbor, abs(acc.width) > Self.threshold, !e.phase.contains(.cancelled) {
                switchTo(next!, model: model)
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0; progress = 0 }
            }
            return true
        }
        // Едет за пальцами; если соседа нет — пружинит
        offset = hasNeighbor ? acc.width * 0.6 : acc.width * 0.15
        // Страховка: если конец жеста потерялся — список всё равно вернётся на место
        watchdog?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.offset != 0 else { return }
            self.tracking = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { self.offset = 0; self.progress = 0 }
        }
        watchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        neighborID = next.map { model.spaces[$0].id }
        progress = hasNeighbor ? min(1, abs(acc.width) / (Self.threshold * 3)) : 0
        return true
    }
}

// MARK: - Два пальца по странице: назад / вперёд

/// Как в Safari: страница — карточка с тенью, едет за пальцами, а под ней видна предыдущая (или следующая)
/// страница — её снимок, сделанный, когда с неё уходили. Отпустил дальше порога — карточка уезжает,
/// и открывается та страница; не дотянул — возвращается.
/// Если под пальцами то, что само листается вбок (карусель, карта, таблица), — жест не мешает.
final class PageSwipe {
    static let shared = PageSwipe()
    private var acc: CGSize = .zero
    private var tracking: Bool?         // nil — ещё не ясно, true — наш жест, false — не наш
    private var blocked = false         // под пальцами прокручиваемое вбок
    private var tab: Tab?
    private var peek: CALayer?          // снимок страницы под карточкой
    private var peekBack: Bool?         // для какой стороны сейчас снимок
    private var shadow: CALayer?        // тень карточки
    private var finishing = false

    /// Снимки страниц истории: уходишь со страницы — запоминаем, как она выглядела.
    /// Храним уменьшенными (обычное, не Retina-разрешение) и сжатыми в JPEG — ~100–200 КБ на снимок
    /// вместо ~15 МБ; раскрываем только на время жеста.
    private var snapshots: [String: Data] = [:]
    private var order: [String] = []
    /// Ключ снимка — адрес страницы (записи истории движок пересоздаёт, по ним снимок мог «уехать» к другой странице)
    private func key(_ item: WKBackForwardListItem) -> String { item.url.absoluteString }
    private static let keep = 30

    /// Закрыли инкогнито — снимки страниц забываем
    func forgetAll() { snapshots = [:]; order = [] }

    func remember(_ wv: WKWebView) {
        guard let item = wv.backForwardList.currentItem, wv.bounds.width > 10 else { return }
        let key = key(item)
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = false
        cfg.snapshotWidth = NSNumber(value: Double(wv.bounds.width))    // 1 пиксель на точку
        wv.takeSnapshot(with: cfg) { [weak self] img, _ in
            guard let self, let img else { return }
            // Сжимаем в фоне
            DispatchQueue.global(qos: .utility).async {
                guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { return }
                DispatchQueue.main.async {
                    self.snapshots[key] = jpg
                    self.order.removeAll { $0 == key }
                    self.order.append(key)
                    if self.order.count > Self.keep { self.snapshots.removeValue(forKey: self.order.removeFirst()) }
                }
            }
        }
    }

    /// false — событие не трогаем (страница получает его как обычно)
    func handle(_ e: NSEvent, at p: CGPoint, model: BrowserModel) -> Bool {
        guard !finishing else { return false }
        if e.phase.contains(.began) || e.phase.contains(.mayBegin) {
            acc = .zero; tracking = nil; blocked = false
            tab = model.activeTab
            if let wv = tab?.webView {
                // Что под пальцами: прокручивается ли вбок (тогда жест — странице)
                let pt = wv.convert(e.locationInWindow, from: nil)
                let y = wv.isFlipped ? pt.y : wv.bounds.height - pt.y
                wv.evaluateJavaScript("""
                (function(x,y){var e=document.elementFromPoint(x,y);while(e&&e!==document.documentElement){
                  if(e.scrollWidth>e.clientWidth+2){var s=getComputedStyle(e).overflowX;if(s==='auto'||s==='scroll')return true;}
                  e=e.parentElement;}return document.documentElement.scrollWidth>innerWidth+2;})(\(Int(pt.x)),\(Int(y)))
                """) { [weak self] r, _ in if (r as? Bool) == true { self?.blocked = true; self?.cancel() } }
            }
        }
        guard let t = tab, let wv = t.webView, tracking != false else { return false }
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        acc.width += e.scrollingDeltaX * sign        // > 0 — пальцы вправо — назад
        acc.height += e.scrollingDeltaY
        if tracking == nil {
            if abs(acc.width) > 10, abs(acc.width) > abs(acc.height) * 1.8 { tracking = true }
            else if abs(acc.height) > 8 { tracking = false; return false }
        }
        guard tracking == true, !blocked else { return false }
        let back = acc.width > 0
        let item = back ? wv.backForwardList.backItem : wv.backForwardList.forwardItem
        let w = wv.bounds.width
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            tracking = nil
            if item != nil, abs(acc.width) > max(90, w * 0.22), !e.phase.contains(.cancelled) {
                go(back, wv)
            } else {
                cancel()
            }
            return true
        }
        showPeek(back, item, wv)
        // Карточка едет за пальцами; если идти некуда — лишь чуть пружинит
        let shift = item != nil ? max(-w, min(w, acc.width)) : max(-24, min(24, acc.width * 0.1))
        move(wv, shift, animated: false)
        return true          // жест наш — страница вертикально не прокручивается
    }

    /// Снимок нужной стороны — под карточкой; у карточки — тень
    private func showPeek(_ back: Bool, _ item: WKBackForwardListItem?, _ wv: WKWebView) {
        guard let host = wv.superview?.layer, let card = wv.layer else { return }
        if peek == nil {
            let l = CALayer()
            l.frame = host.bounds
            l.contentsGravity = .resize          // снимок хранится в обычном разрешении — растягиваем на всю страницу
            l.backgroundColor = (BrowserModel.shared.activeTab?.pageColor ?? .windowBackgroundColor).cgColor
            // Углы — как у окна
            let r = Metrics.windowRadius
            l.cornerRadius = r
            l.masksToBounds = true
            host.insertSublayer(l, below: card)
            peek = l
            // Тень карточки — отдельным слоем под ней (сама карточка обрезана по скруглённым углам)
            let sh = CALayer()
            sh.frame = card.frame
            sh.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: card.bounds.size), cornerWidth: r, cornerHeight: r, transform: nil)
            sh.shadowColor = NSColor.black.cgColor
            sh.shadowOpacity = 0.2         // на 30% прозрачней прежней (0.28)
            sh.shadowRadius = 18
            sh.shadowOffset = .zero
            host.insertSublayer(sh, below: card)
            shadow = sh
            // Карточка непрозрачная (в цвет сайта): у страниц с прозрачным фоном сквозь неё просвечивал бы снимок
            card.backgroundColor = (BrowserModel.shared.activeTab?.pageColor ?? .white).cgColor
            card.cornerRadius = r
            card.masksToBounds = true
        }
        if peekBack != back {
            peekBack = back
            CATransaction.begin(); CATransaction.setDisableActions(true)
            peek?.contents = item.flatMap { snapshots[key($0)] }.flatMap { NSImage(data: $0) }
            CATransaction.commit()
        }
    }

    private func move(_ wv: WKWebView, _ x: CGFloat, animated: Bool, duration: Double = 0.25, done: (() -> Void)? = nil) {
        guard let card = wv.layer else { done?(); return }
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1))
            CATransaction.setCompletionBlock { done?() }
        } else {
            CATransaction.setDisableActions(true)
        }
        card.setAffineTransform(CGAffineTransform(translationX: x, y: 0))
        shadow?.setAffineTransform(CGAffineTransform(translationX: x, y: 0))
        // Под карточкой снимок чуть приглушён и выезжает навстречу (как в Safari)
        if let peek {
            let w = max(1, wv.bounds.width), f = min(1, abs(x) / w)
            peek.opacity = Float(0.75 + 0.25 * f)
            peek.setAffineTransform(CGAffineTransform(translationX: (x > 0 ? -1 : 1) * w * 0.12 * (1 - f), y: 0))
        }
        CATransaction.commit()
        if !animated { done?() }
    }

    private func go(_ back: Bool, _ wv: WKWebView) {
        finishing = true
        let w = wv.bounds.width
        move(wv, back ? w : -w, animated: true, duration: 0.22) {
            // Карточку возвращаем на место (под снимок) — до того, как снимок встанет поверх:
            // move() приглушает и сдвигает снимок, поверх он должен лежать ровно и непрозрачно
            CATransaction.begin(); CATransaction.setDisableActions(true)      // всё — одним кадром
            self.move(wv, 0, animated: false)
            self.restoreCard(wv)
            // Снимок — поверх, пока открывается страница.
            // Снимка этой страницы нет (сайт меняет страницу без загрузки) — пустую подложку не держим
            if let peek = self.peek {
                if peek.contents == nil {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    peek.removeFromSuperlayer()
                    CATransaction.commit()
                    self.peek = nil
                } else {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    peek.zPosition = 10; peek.opacity = 1; peek.setAffineTransform(.identity); peek.cornerRadius = 0
                    CATransaction.commit()
                }
            }
            CATransaction.commit()
            let target = (back ? wv.backForwardList.backItem : wv.backForwardList.forwardItem)?.url
            self.waitForPage(wv, target: target) { if back { wv.goBack() } else { wv.goForward() } }
        }
    }

    /// Ждём, пока движок покажет новую страницу, — до этого снимок лежит поверх
    private weak var waiting: WKWebView?
    private var urlWatch: NSKeyValueObservation?
    private var loadWatch: NSKeyValueObservation?
    /// Куда идём: снимок растворяется, только когда движок уже показывает эту страницу (иначе проступит прежняя)
    private var target: URL?

    /// Новая страница открылась (из делегата: didCommit / didFinish)
    func navigated(_ wv: WKWebView) {
        // Уже та страница и догрузилась (иначе движок ещё показывает прежнюю — она проступила бы сквозь растворение)
        guard waiting === wv, target == nil || wv.url == target, !wv.isLoading else { return }
        waiting = nil
        urlWatch = nil
        loadWatch = nil
        target = nil
        // Дождаться, пока она реально нарисуется на экране (снимок «после обновления экрана»), и тогда убрать свой
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = true
        cfg.snapshotWidth = 1
        wv.takeSnapshot(with: cfg) { _, _ in
            // Первая отрисовка ещё не на экране окна — небольшой запас
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.reveal(wv) }
        }
    }

    /// Живая страница нарисована — снимок прошлой растворяется в неё
    private func reveal(_ wv: WKWebView) {
        waiting = nil
        urlWatch = nil
        loadWatch = nil
        target = nil
        if let p = peek {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            CATransaction.setCompletionBlock { p.removeFromSuperlayer() }
            p.opacity = 0
            CATransaction.commit()
        }
        peek = nil; peekBack = nil
        finishing = false
    }

    /// Назад / вперёд кнопкой или клавишами: снимок нынешней страницы лежит поверх, пока открывается новая,
    /// и растворяется в неё
    func step(_ wv: WKWebView?, back: Bool) {
        guard let wv, back ? wv.canGoBack : wv.canGoForward else { return }
        func go() { if back { wv.goBack() } else { wv.goForward() } }
        guard !finishing, peek == nil, let host = wv.superview?.layer, wv.window != nil, wv.bounds.width > 10 else { go(); return }
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = false
        finishing = true
        wv.takeSnapshot(with: cfg) { [weak self] img, _ in
            guard let self else { return }
            guard let img else { self.finishing = false; go(); return }
            let l = CALayer()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            l.frame = host.bounds
            l.contents = img
            l.contentsGravity = .resize
            l.zPosition = 10
            l.backgroundColor = (BrowserModel.shared.activeTab?.pageColor ?? .windowBackgroundColor).cgColor
            host.addSublayer(l)
            CATransaction.commit()
            self.peek = l
            self.waitForPage(wv, target: (back ? wv.backForwardList.backItem : wv.backForwardList.forwardItem)?.url, go)
        }
    }

    /// Перейти и дождаться, пока новая страница нарисуется; тогда снимок растворяется
    private func waitForPage(_ wv: WKWebView, target: URL?, _ go: () -> Void) {
        waiting = wv
        self.target = target
        // Переход внутри страницы (без новой загрузки, как на YouTube) или из памяти браузера — делегат о нём
        // может промолчать; ловим смену адреса и конец загрузки
        urlWatch = wv.observe(\.url, options: [.new]) { [weak self] w, _ in
            DispatchQueue.main.async { if !w.isLoading { self?.navigated(w) } }
        }
        loadWatch = wv.observe(\.isLoading, options: [.new]) { [weak self] w, _ in
            DispatchQueue.main.async { if !w.isLoading { self?.navigated(w) } }
        }
        go()
        // Запасной выход: страница так и не сообщила о себе
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if self.waiting === wv { self.reveal(wv) } }
    }

    /// Карточка снова обычная страница: без тени, скруглений и подложки
    private func restoreCard(_ wv: WKWebView) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shadow?.removeFromSuperlayer(); shadow = nil
        wv.layer?.backgroundColor = nil
        wv.layer?.cornerRadius = 0
        CATransaction.commit()
    }

    private func cancel() {
        guard let wv = tab?.webView else { return }
        move(wv, 0, animated: true, duration: 0.22) {
            self.peek?.removeFromSuperlayer(); self.peek = nil; self.peekBack = nil
            self.restoreCard(wv)
        }
    }
}

// MARK: - Сортировка и группировка выделенных вкладок

enum TabOrder: CaseIterable {
    case name, lastUsed, opened

    var title: String {
        switch self {
        case .name: "Name"
        case .lastUsed: "Last Used"
        case .opened: "Date Opened"
        }
    }
    var groupTitle: String {
        switch self {
        case .name: "Site"
        case .lastUsed: "Last Used"
        case .opened: "Date Opened"
        }
    }

    /// По имени — по алфавиту; по датам — сначала новые (дата открытия неизвестна — в конец)
    func sorted(_ tabs: [Tab]) -> [Tab] {
        switch self {
        case .name: tabs.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        case .lastUsed: tabs.sorted { $0.lastActive > $1.lastActive }
        case .opened: tabs.sorted { ($0.opened ?? .distantPast) > ($1.opened ?? .distantPast) }
        }
    }

    static func site(_ t: Tab) -> String {
        guard var h = t.url?.host else { return "Other" }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// Промежуток времени: сегодня, вчера, на этой неделе…
    static func period(_ d: Date?) -> (rank: Int, name: String) {
        guard let d else { return (5, "Earlier") }
        let cal = Calendar.current, now = Date()
        if cal.isDateInToday(d) { return (0, "Today") }
        if cal.isDateInYesterday(d) { return (1, "Yesterday") }
        if now.timeIntervalSince(d) < 7 * 86400 { return (2, "This Week") }
        if now.timeIntervalSince(d) < 30 * 86400 { return (3, "This Month") }
        return (4, "Earlier")
    }
}

extension BrowserModel {
    /// Отсортировать выделенные: каждая вкладка остаётся в своём месте (закреплённые, папка, список),
    /// меняется лишь порядок среди тех мест, что занимали выделенные
    func sort(_ tabs: [Tab], by order: TabOrder) {
        let sp = currentSpace
        let mine = tabs.filter { t in sp.tabs.contains { $0 === t } && !t.isBranch }
        guard mine.count > 1 else { return }
        checkpoint("Sort Tabs")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            sp.normalize()
            // Вкладки вне папок — порядок в `layout` (сохранённые и временные — отдельно)
            let loose = mine.filter { !$0.isPinned && $0.folderID == nil }
            for part in [loose.filter(\.isSaved), loose.filter { !$0.isSaved }] {
                let slots = part.compactMap { t in sp.layout.firstIndex(of: t.id) }.sorted()
                for (slot, t) in zip(slots, order.sorted(part)) { sp.layout[slot] = t.id }
            }
            // Закреплённые и вкладки папок — порядок в самом массиве вкладок
            let inPlace = Dictionary(grouping: mine.filter { $0.isPinned || $0.folderID != nil }) { $0.isPinned ? nil : $0.folderID }
            for part in inPlace.values where part.count > 1 {
                let slots = part.compactMap { t in sp.tabs.firstIndex { $0 === t } }.sorted()
                for (slot, t) in zip(slots, order.sorted(part)) { sp.tabs[slot] = t }
            }
            sp.normalize()
        }
        selection.clear()
    }

    /// Разложить выделенные по новым папкам: по сайту, по дню последнего использования или открытия.
    /// Закреплённые не трогаем. Сайты с одной вкладкой — вместе в «Other Sites».
    func group(_ tabs: [Tab], by order: TabOrder) {
        let sp = currentSpace
        let mine = tabs.filter { t in sp.tabs.contains { $0 === t } && !t.isPinned }
        guard !mine.isEmpty else { return }
        checkpoint("Group Tabs")
        // Группы: имя папки и порядок папок
        var groups: [(rank: Int, name: String, tabs: [Tab])] = []
        switch order {
        case .name:
            let bySite = Dictionary(grouping: mine, by: TabOrder.site)
            let single = bySite.values.filter { $0.count == 1 }.flatMap { $0 }
            for (site, list) in bySite where list.count > 1 { groups.append((0, site, list)) }
            groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if !single.isEmpty { groups.append((1, groups.isEmpty ? "Sites" : "Other Sites", single)) }
        case .lastUsed, .opened:
            let prefix = order == .lastUsed ? "Used" : "Opened"
            let byPeriod = Dictionary(grouping: mine) { TabOrder.period(order == .lastUsed ? $0.lastActive : $0.opened).rank }
            for (_, list) in byPeriod {
                let p = TabOrder.period(order == .lastUsed ? list[0].lastActive : list[0].opened)
                groups.append((p.rank, "\(prefix) \(p.name)", list))
            }
            groups.sort { $0.rank < $1.rank }
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            sp.normalize()
            // Папки встают на место первой из выделенных (в списке верхнего уровня)
            let at = mine.lazy.compactMap { t in
                sp.layout.firstIndex(of: t.id) ?? t.folderID.flatMap { id in sp.folders.first { $0.id == id } }.flatMap { sp.layout.firstIndex(of: sp.topAncestor(of: $0).id) }
            }.min() ?? 0
            var moving: [Tab] = []
            // Разложил одни временные — папки тоже временные
            let temp = mine.allSatisfy { sp.isTemp($0) }
            for (i, g) in groups.enumerated() {
                let f = Folder(name: g.name, hue: sp.colorless ? -1 : sp.hue)
                f.isTemp = temp
                sp.folders.append(f)
                sp.layout.insert(f.id, at: min(at + i, sp.layout.count))
                for t in order.sorted(g.tabs) {
                    _ = sp.leavePanes(t.id)
                    t.folderID = f.id; t.isBranch = false; t.isSaved = false
                    moving.append(t)
                }
            }
            // Порядок внутри папок — как отсортировали
            sp.tabs = sp.tabs.filter { t in !moving.contains { $0 === t } } + moving
            sp.normalize()
        }
        selection.clear()
        showToast(groups.count == 1 ? "Grouped into 1 folder" : "Grouped into \(groups.count) folders")
    }
}
