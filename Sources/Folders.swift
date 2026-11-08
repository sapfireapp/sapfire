import AppKit
import SwiftUI

// MARK: - Папки в боковой панели

@Observable
final class Folder: Identifiable {
    let id: UUID
    var name: String
    var icon: String
    var hue: Double            // < 0 — без цвета
    var sat: Double = 0.7      // насыщенность и яркость (HSV)
    var bri: Double = 0.8
    var expanded: Bool
    /// Папка, внутри которой лежит эта (nil — верхний уровень)
    var parentID: UUID?
    /// Временная папка (под «Temp»): уходит в архив целиком, как временные вкладки
    var isTemp = false
    /// Когда папку последний раз трогали (для архива пустой временной папки)
    var touched = Date() { didSet { touchedMark = ActiveClock.shared.now } }
    var touchedMark = ActiveClock.shared.now

    init(id: UUID = UUID(), name: String, icon: String = "folder", hue: Double = -1, expanded: Bool = true) {
        self.id = id
        self.name = name
        self.icon = icon
        self.hue = hue
        self.expanded = expanded
    }

    var color: Color { hue < 0 ? Color.secondary : Color(hue: hue, saturation: sat, brightness: bri) }

    static let icons = ["folder", "star", "briefcase", "book", "cart", "music.note", "film", "gamecontroller",
                        "paintbrush", "hammer", "heart", "leaf", "graduationcap", "newspaper", "bolt", "globe"]
    /// Сколько последних вкладок показывать в попапе папки (потом — в настройках)
    static var peekCount: Int {
        let n = UserDefaults.standard.integer(forKey: "folderPeekCount")
        return n > 0 ? n : 5
    }
}

extension BrowserModel {
    func folder(_ id: UUID?) -> Folder? {
        guard let id else { return nil }
        return currentSpace.folders.first { $0.id == id }
    }

    /// Новая папка (сразу с вкладками, если переданы) — имя спрашиваем сразу. `parent` — создать внутри папки.
    @discardableResult
    func newFolder(with tabs: [Tab] = [], inside parent: Folder? = nil, temp: Bool = false) -> Folder? {
        let sp = currentSpace
        guard !sp.isIncognito else { showToast("Incognito keeps a plain list — no folders"); return nil }
        guard let name = promptText("New folder", initial: "Folder \(sp.folders.count + 1)"), !name.isEmpty else { return nil }
        checkpoint("New Folder")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Tips.show(.folder, self) }
        let f = Folder(name: name, hue: parent?.hue ?? (sp.colorless ? -1 : sp.hue))
        if let parent { f.sat = parent.sat; f.bri = parent.bri }
        // Из одних временных вкладок — папка тоже временная (встаёт под «Temp»)
        f.isTemp = parent == nil && (temp || (!tabs.isEmpty && tabs.allSatisfy { sp.isTemp($0) }))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            sp.normalize()
            if let parent {
                f.parentID = parent.id
                parent.expanded = true
                sp.folders.append(f)
            } else {
                // Папка встаёт на место первой из переданных вкладок (или наверх списка)
                let at = tabs.first.flatMap { t in sp.layout.firstIndex(of: t.id) ?? sp.layout.firstIndex(of: t.folderID ?? UUID()) } ?? 0
                sp.folders.append(f)
                sp.layout.insert(f.id, at: at)
            }
            if !tabs.isEmpty { moveTabs(tabs.map(\.id), to: .folder(f.id, 0)) }
            sp.normalize()
        }
        selection.clear()
        return f
    }

    /// Можно ли положить папку `f` внутрь `into`: не в саму себя и не глубже трёх уровней
    func canNest(_ f: Folder, into: Folder) -> Bool {
        let sp = currentSpace
        guard f !== into, !sp.isInside(into, f), f.parentID != into.id else { return false }
        // Во временную папку — только вкладки (временное — в один уровень)
        if sp.topAncestor(of: into).isTemp { return false }
        return sp.depth(of: into) + 1 + sp.height(of: f) <= Space.maxFolderDepth
    }

    /// Положить папку внутрь другой (в конец её вложенных папок)
    func nest(_ fid: UUID, into pid: UUID) {
        let sp = currentSpace
        guard let f = sp.folders.first(where: { $0.id == fid }), let p = sp.folders.first(where: { $0.id == pid }),
              canNest(f, into: p) else { return }
        checkpoint("Move Folder")
        f.parentID = p.id
        f.isTemp = false
        p.expanded = true
        sp.layout.removeAll { $0 == fid }
        sp.folders = sp.folders.filter { $0 !== f } + [f]
        sp.normalize()
    }

    /// Вынуть папку на уровень выше (из верхней вложенной — в общий список, сразу под родителем)
    func moveOut(_ f: Folder) {
        let sp = currentSpace
        guard let p = sp.parent(of: f) else { return }
        checkpoint("Move Folder")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            f.parentID = p.parentID
            if f.parentID == nil {
                sp.normalize()
                let at = sp.layout.firstIndex(of: sp.topAncestor(of: p).id).map { $0 + 1 } ?? 0
                sp.layout.insert(f.id, at: at)
            }
            sp.normalize()
        }
    }

    func renameFolder(_ f: Folder) {
        if let name = promptText("Folder name", initial: f.name), !name.isEmpty { checkpoint("Rename Folder"); f.name = name }
    }

    /// Расформировать: вкладки и вложенные папки встают на место папки (в родительскую папку или в список).
    func ungroup(_ f: Folder) {
        checkpoint("Ungroup")
        let sp = currentSpace
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            let kids = sp.tabs(in: f)
            let subs = sp.subfolders(of: f)
            for s in subs { s.parentID = f.parentID }
            if let pid = f.parentID {
                for t in kids { t.folderID = pid; t.isSaved = false }
            } else {
                // Вкладки встают на место папки — в сохранённое (над разделителем) или во временные
                let at = sp.layout.firstIndex(of: f.id) ?? 0
                for t in kids { t.folderID = nil; t.isSaved = !f.isTemp }
                for s in subs { s.isTemp = f.isTemp }
                sp.layout.removeAll { $0 == f.id }
                sp.layout.insert(contentsOf: subs.map(\.id) + kids.map(\.id), at: min(at, sp.layout.count))
            }
            sp.folders.removeAll { $0 === f }
            sp.normalize()
        }
    }

    /// Удалить папку вместе с вкладками (с подтверждением).
    func deleteFolder(_ f: Folder) {
        let sp = currentSpace
        let tabs = sp.allTabs(in: f)
        let inner = sp.descendants(of: f)
        if !tabs.isEmpty {
            let a = NSAlert()
            a.messageText = "Delete “\(f.name)”?"
            a.informativeText = "\(tabs.count) tab\(tabs.count == 1 ? "" : "s") in this folder will be closed."
            a.addButton(withTitle: "Delete")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        checkpoint("Delete Folder")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            tabs.forEach { close($0) }
            sp.folders.removeAll { x in x === f || inner.contains { $0 === x } }
            sp.normalize()
        }
    }

    func closeTabs(in f: Folder) { checkpoint("Close Folder Tabs"); currentSpace.allTabs(in: f).forEach { close($0) } }
    func sleepTabs(in f: Folder) { sleep(currentSpace.allTabs(in: f)) }
}

// MARK: - Шапка папки

struct FolderHeader: View {
    @Environment(BrowserModel.self) private var model
    let folder: Folder
    var compact = false
    @State private var hover = false
    @State private var picker = false
    @Environment(\.rowCorner) private var rowCorner
    private var corner: CGFloat { compact ? 16 : rowCorner }
    @State private var globalFrame: CGRect = .zero

    var body: some View {
        let sp = model.currentSpace
        let count = sp.allTabs(in: folder).count
        let dropHere = model.drag.hoverFolder == folder.id
        HStack(spacing: 8) {
            if compact {
                // Узкий режим: контурный значок папки в её цвет и число вкладок — не спутать с сайтом
                Image(systemName: folder.expanded ? Symbols.open(folder.icon) : Symbols.filled(folder.icon))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(folder.hue < 0 ? Color.secondary : folder.color)
                    .frame(width: 32, height: 32)
                    .overlay(alignment: .bottomTrailing) {
                        if !folder.expanded && count > 0 {
                            Text("\(count)").font(.system(size: 8, weight: .bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 3).frame(minWidth: 12, minHeight: 12)
                                .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                                .offset(x: 2, y: 2)
                        }
                    }
                    .frame(maxWidth: .infinity)
            } else {
            // Без стрелки: раскрытую папку видно по подложке. Значок — по одной линии с фавиконами вкладок
            // Раскрыта — контурный значок, свёрнута — залитый (у любого значка, не только у папки)
            Image(systemName: folder.expanded ? Symbols.open(folder.icon) : Symbols.filled(folder.icon))
                .font(.system(size: 13))
                .foregroundStyle(folder.color)
                .frame(width: 16)
                .overlay(alignment: .topTrailing) {
                    if folder.isTemp, BrowserModel.archiveAfter > 0 {
                        ArchiveDot { BrowserModel.archiveLeft(folder: folder, in: sp, now: $0) }
                    }
                }
            Text(folder.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            if !folder.expanded && count > 0 {
                Text("\(count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            }
        }
        .padding(.leading, compact ? 0 : 8).padding(.trailing, compact ? 0 : 8)
        .frame(height: 32)
        .background {
            let shape = RoundedRectangle(cornerRadius: corner, style: .circular)
            if dropHere {
                shape.fill(sp.tint.opacity(0.25))
                    .overlay(shape.strokeBorder(sp.dropLine, lineWidth: 1.5))
            } else if hover {
                shape.fill(sidebarShade(0.05))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.folderPeek.close(now: true)
            ListMotion.animate { folder.expanded.toggle() }
        }
        .reportFrame { model.drag.headerFrames[folder.id] = $0 }
        // Папку можно перетаскивать за шапку
        .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named(TabDrag.space))
            .onChanged { model.drag.changedFolder(folder, at: $0.location, model: model) }
            .onEnded { _ in model.drag.ended(model: model) })
        .background(GeometryReader { g in
            let f = g.frame(in: .global)
            Color.clear.onAppear { globalFrame = f }.onChange(of: f) { globalFrame = f }
        })
        // Наведение на свёрнутую папку — попап с поиском и последними вкладками (рисуется в окне)
        .onHover { inside in
            hover = inside
            let st = model.folderPeek
            if inside {
                guard !folder.expanded, !model.drag.active, count > 0 else { return }
                st.headerEntered(folder.id, anchor: globalFrame)
            } else {
                st.headerExited()
            }
        }
        .contextMenu { FolderMenu(folder: folder) { picker = true } }
        .popover(isPresented: $picker, arrowEdge: .trailing) {
            IconColorPicker(icon: Binding(get: { folder.icon }, set: { folder.icon = $0 }),
                            hue: Binding(get: { folder.hue }, set: { folder.hue = $0 }),
                            sat: Binding(get: { folder.sat }, set: { folder.sat = $0 }),
                            bri: Binding(get: { folder.bri }, set: { folder.bri = $0 }),
                            willChange: { model.checkpoint("Folder Look") })
        }
    }
}

// MARK: - Состояние попапа папки

@Observable
final class FolderPeekState {
    /// Своё у каждого окна; `shared` — у окна, в котором сейчас работают
    static var shared: FolderPeekState { BrowserModel.current.folderPeek }
    var folderID: UUID?
    var anchor: CGRect = .zero                 // шапка папки в координатах окна
    @ObservationIgnored private var overHeader = false
    @ObservationIgnored private var overPopup = false
    @ObservationIgnored private var work: DispatchWorkItem?

    func headerEntered(_ id: UUID, anchor a: CGRect) {
        overHeader = true
        work?.cancel()
        if folderID == id { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.overHeader else { return }
            self.anchor = a
            withAnimation(.easeOut(duration: 0.14)) { self.folderID = id }
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (folderID == nil ? 0.35 : 0.1), execute: w)
    }

    func headerExited() { overHeader = false; scheduleClose() }
    func popup(_ inside: Bool) { overPopup = inside; if inside { work?.cancel() } else { scheduleClose() } }

    func close(now: Bool = false) {
        work?.cancel()
        if now { withAnimation(.easeOut(duration: 0.1)) { folderID = nil }; return }
        scheduleClose()
    }

    private func scheduleClose() {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.overHeader, !self.overPopup else { return }
            withAnimation(.easeOut(duration: 0.12)) { self.folderID = nil }
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }
}

/// Пузырь с острым кончиком слева, указывающим на папку — один непрерывный контур, без шва.
struct PeekBubble: Shape {
    var tipY: CGFloat
    static let tip: CGFloat = 9
    func path(in r: CGRect) -> Path {
        let t = Self.tip, rad: CGFloat = 10, half: CGFloat = 6   // кончик влезает точно в центр строки высотой 32
        let x0 = r.minX + t, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
        let y = min(max(tipY, y0 + rad + half), y1 - rad - half)
        var p = Path()
        p.move(to: CGPoint(x: x0 + rad, y: y0))
        p.addLine(to: CGPoint(x: x1 - rad, y: y0))
        p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y0 + rad), radius: rad)
        p.addLine(to: CGPoint(x: x1, y: y1 - rad))
        p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x1 - rad, y: y1), radius: rad)
        p.addLine(to: CGPoint(x: x0 + rad, y: y1))
        p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - rad), radius: rad)
        p.addLine(to: CGPoint(x: x0, y: y + half))
        p.addLine(to: CGPoint(x: r.minX, y: y))            // острый кончик
        p.addLine(to: CGPoint(x: x0, y: y - half))
        p.addLine(to: CGPoint(x: x0, y: y0 + rad))
        p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + rad, y: y0), radius: rad)
        p.closeSubpath()
        return p
    }
}

/// Попап рядом с папкой (слой поверх окна).
struct FolderPeekOverlay: View {
    @Environment(BrowserModel.self) private var model
    private var st: FolderPeekState { model.folderPeek }

    var body: some View {
        GeometryReader { g in
            let origin = g.frame(in: .global).origin
            if let id = st.folderID, let f = model.currentSpace.folders.first(where: { $0.id == id }), !f.expanded {
                let a = st.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
                // Строка поиска (высотой во вкладку) — на одной линии с шапкой папки
                let row = FolderPeek.searchHeight
                let top = max(8, min(a.midY - row / 2, g.size.height - 260))
                FolderPeek(folder: f) { st.close(now: true) }
                    .padding(.leading, PeekBubble.tip)
                    .background {
                        PeekBubble(tipY: a.midY - top)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .overlay(PeekBubble(tipY: a.midY - top).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
                    }
                    .onHover { st.popup($0) }
                    .offset(x: a.maxX + 6, y: top)
                    .transition(.opacity.combined(with: .offset(x: -6)))
                    .id(id)
            }
        }
        .onChange(of: model.currentSpaceID) { st.close(now: true) }
    }
}

// MARK: - Попап папки

struct FolderPeek: View {
    static let searchHeight: CGFloat = 32   // как строка вкладки
    static let inset: CGFloat = 6
    @Environment(BrowserModel.self) private var model
    let folder: Folder
    let done: () -> Void
    @State private var query = ""
    @State private var hoverID: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        let all = model.currentSpace.allTabs(in: folder)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list: [Tab] = q.isEmpty
            ? Array(all.sorted { $0.lastActive > $1.lastActive }.prefix(Folder.peekCount))
            : all.filter { $0.displayTitle.lowercased().contains(q) || ($0.url?.absoluteString.lowercased().contains(q) ?? false) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Search in \(folder.name)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { if let t = list.first { open(t) } }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.searchHeight)
            .padding(.horizontal, Self.inset)
            Divider()
            if list.isEmpty {
                Text(q.isEmpty ? "No tabs" : "Nothing found")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            } else {
                VStack(spacing: 2) {
                    ForEach(list) { t in
                        HStack(spacing: 8) {
                            Favicon(url: t.url).frame(width: 16, height: 16)
                            Text(t.displayTitle).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(hoverID == t.id ? sidebarShade(0.07) : .clear, in: Capsule())
                        .contentShape(Rectangle())
                        .onHover { hoverID = $0 ? t.id : (hoverID == t.id ? nil : hoverID) }
                        .onTapGesture { open(t) }
                    }
                }
                .padding(6)
            }
            if q.isEmpty && all.count > list.count {
                Text("\(all.count - list.count) more — type to search")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
        .frame(width: 270)
        // Курсор сразу в поиске; когда попап закрылся — клавиатура снова у страницы
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onDisappear { model.focusWebView() }
    }

    private func open(_ t: Tab) {
        done()
        model.select(t)
    }
}

// MARK: - Меню папки

struct FolderMenu: View {
    @Environment(BrowserModel.self) private var model
    let folder: Folder
    /// Открыть окно «значок и цвет» (оно висит на шапке папки)
    var showPicker: () -> Void = {}

    var body: some View {
        Button("Rename…") { model.renameFolder(folder) }
        Button("Icon & Color…") { showPicker() }
        Divider()
        Button(folder.expanded ? "Collapse" : "Expand") {
            ListMotion.animate { folder.expanded.toggle() }
        }
        Button("Sleep All Tabs") { model.sleepTabs(in: folder) }
        Button("Close All Tabs") { model.closeTabs(in: folder) }
        Divider()
        if model.currentSpace.depth(of: folder) < Space.maxFolderDepth, !model.currentSpace.topAncestor(of: folder).isTemp {
            Button("New Folder Inside…") { model.newFolder(inside: folder) }
        }
        if folder.parentID != nil {
            Button("Move Out of Folder") { model.moveOut(folder) }
        } else {
            // Временная — над чертой «Pinned» (не уйдёт в архив); сохранённая — под «Temp»
            Button(folder.isTemp ? "Keep Folder" : "Make Folder Temporary") {
                let sp = model.currentSpace
                let i = folder.isTemp ? sp.savedEntries.count : sp.savedEntries.count - 1
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.moveFolder(folder.id, to: max(0, i), saved: folder.isTemp) }
            }
        }
        let others = model.spaces.filter { $0.id != model.currentSpaceID && $0.isIncognito == model.currentSpace.isIncognito }
        if !others.isEmpty {
            Menu("Move to Space") {
                ForEach(others) { s in Button { model.move(folder: folder, to: s) } label: { Label(s.name, systemImage: Symbols.open(s.icon)) } }
            }
        }
        Divider()
        Button("Delete Folder") { model.ungroup(folder) }
        Button("Delete Folder and Tabs") { model.deleteFolder(folder) }
    }
}

/// Подменю «Move to Folder» для вкладки или группы.
struct MoveToFolderMenu: View {
    @Environment(BrowserModel.self) private var model
    let tabs: [Tab]

    var body: some View {
        let sp = model.currentSpace
        // Папки деревом: вложенные — с отступом под своими
        let folders = sp.folders.filter { $0.parentID == nil }.flatMap { [$0] + sp.descendants(of: $0) }
        Menu("Move to Folder") {
            ForEach(folders) { f in
                Button(String(repeating: "    ", count: sp.depth(of: f)) + f.name) {
                    model.moveTabs(tabs.map(\.id), to: .folder(f.id, model.currentSpace.tabs(in: f).count))
                }
            }
            if !folders.isEmpty { Divider() }
            Button("New Folder…") { model.newFolder(with: tabs) }
        }
        if tabs.contains(where: { $0.folderID != nil }) {
            Button("Remove from Folder") { model.moveTabs(tabs.map(\.id), to: .list(0)) }
        }
    }
}
