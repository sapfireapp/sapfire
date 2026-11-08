import AppKit
import SwiftUI

// MARK: - Кружок загрузок (справа внизу окна)

/// Пока что-то качается (и ещё немного после) — кружок справа внизу: по кругу заполняется полоска общего хода,
/// внутри — сколько загрузок идёт. Навёл — небольшая карточка с последними; клик — карточка со всеми загрузками.
struct DownloadsBadge: View {
    @Environment(BrowserModel.self) private var model
    @State private var store = DownloadStore.shared
    @State private var hover = false
    @State private var open = false
    /// Только что закончилось — кружок ещё виден несколько секунд
    @State private var linger = false
    @State private var lingerWork: DispatchWorkItem?

    static let size: CGFloat = 34
    /// Отступ кружка от края страницы сверх общего inset
    static let margin: CGFloat = 10
    /// Место снизу справа под кружок (с его отступом) — уведомления встают выше
    static var reserve: CGFloat { size + margin + Metrics.inset }

    var body: some View {
        let active = store.active
        let shown = !active.isEmpty || linger || open
        VStack(alignment: .trailing, spacing: 8) {
            if shown && (open || hover) {
                DownloadsCard(full: open) { open = false }
                    .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
            }
            if shown {
                circle(active)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: shown)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: open)
        .onChange(of: store.lastFinished) {
            lingerWork?.cancel()
            linger = true
            let w = DispatchWorkItem { withAnimation { linger = false } }
            lingerWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
        }
    }

    private func circle(_ active: [DownloadStore.Item]) -> some View {
        // Общий ход: среднее известных; неизвестен ни один — крутится дуга
        let known = active.compactMap { store.progress[$0.id] }.filter { $0 >= 0 }
        let total: Double? = active.isEmpty ? 1 : known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
        return Button { open.toggle() } label: {
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3).padding(3)
                if let t = total {
                    Circle().trim(from: 0, to: max(0.02, t))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(3)
                        .animation(.easeOut(duration: 0.25), value: t)
                } else {
                    SpinningArc().padding(3)
                }
                if active.isEmpty {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.accentColor)
                } else {
                    Text("\(active.count)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
            }
            .frame(width: Self.size, height: Self.size)
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(active.isEmpty ? "Downloads" : "Downloading \(active.count) file\(active.count == 1 ? "" : "s")")
    }
}

/// Дуга, что крутится, пока размер загрузки неизвестен
private struct SpinningArc: View {
    @State private var spin = false
    var body: some View {
        Circle().trim(from: 0, to: 0.25)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

/// Карточка загрузок: при наведении — последние несколько, по клику — все
private struct DownloadsCard: View {
    @State private var store = DownloadStore.shared
    let full: Bool
    let close: () -> Void

    var body: some View {
        let list = full ? store.items : Array(store.items.prefix(3))
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                Spacer()
                if full {
                    Button("Clear") { store.clear() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                        .disabled(!store.items.contains { $0.done || $0.failed })
                    Button { close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 6)
                }
            }
            .padding(.horizontal, 12).frame(height: 34)
            Divider()
            if list.isEmpty {
                Text("No downloads").font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 2) { ForEach(list) { DownloadRow(item: $0) } }.padding(6)
                }
                .frame(maxHeight: full ? 360 : 3 * 40 + 12)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: full ? 320 : 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .circular))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .circular).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 4)
    }
}

private struct DownloadRow: View {
    @State private var store = DownloadStore.shared
    let item: DownloadStore.Item
    @State private var hover = false

    var body: some View {
        let p = store.progress[item.id]
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.file.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.file.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                if !item.done && !item.failed {
                    if let p, p >= 0 {
                        ProgressView(value: p).progressViewStyle(.linear).controlSize(.small)
                    } else {
                        Text("Downloading…").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                } else {
                    Text(item.cancelled == true ? "Cancelled" : item.failed ? "Failed" : item.started.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10.5))
                        .foregroundStyle(item.failed && item.cancelled != true ? AnyShapeStyle(Color.red.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 0)
            if !item.done && !item.failed {
                // Остановить загрузку
                Button { store.cancel(item.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Cancel download")
            }
            if item.done {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary).opacity(hover ? 1 : 0)
            }
        }
        .padding(.horizontal, 6).frame(height: 40)
        .background(Color.primary.opacity(hover ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 10, style: .circular))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if item.done { NSWorkspace.shared.activateFileViewerSelecting([item.file]) } }
        .help(item.done ? "Show in Finder" : item.file.lastPathComponent)
    }
}

// MARK: - Все загрузки (отдельное окно)

/// Все загрузки в окне: по дням, поиск, открыть файл (двойной клик / Return), показать в Finder, убрать из списка
final class DownloadsWindow {
    private static var window: NSWindow?

    static func show() {
        BrowserModel.current.hideCommandBar()
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Downloads"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 420, height: 300)
        w.setFrameAutosaveName("SapfireDownloads")
        w.contentView = NSHostingView(rootView: DownloadsPage())
        if w.frame.origin == .zero { w.center() }
        w.makeKeyAndOrderFront(nil)
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in window = nil }
    }
}

private struct DownloadsPage: View {
    @State private var store = DownloadStore.shared
    @State private var query = ""
    @State private var selection = Set<UUID>()

    private struct Day: Identifiable {
        var title: String
        var items: [DownloadStore.Item]
        var id: String { title }
    }

    private func days(_ list: [DownloadStore.Item]) -> [Day] {
        let cal = Calendar.current
        var out: [Day] = []
        var key: Date?
        for e in list {
            let d = cal.startOfDay(for: e.started)
            if d != key {
                key = d
                let t = cal.isDateInToday(d) ? "Today" : cal.isDateInYesterday(d) ? "Yesterday"
                    : d.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
                out.append(Day(title: t, items: []))
            }
            out[out.count - 1].items.append(e)
        }
        return out
    }

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? store.items : store.items.filter { $0.file.lastPathComponent.lowercased().contains(q) }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search downloads", text: $query).textFieldStyle(.plain).font(.system(size: 14))
                Text("\(list.count) file\(list.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).frame(height: 40)
            Divider()
            List(selection: $selection) {
                ForEach(days(list)) { day in
                    Section(day.title) {
                        ForEach(day.items) { DownloadLine(item: $0).tag($0.id) }
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Open") { open(ids) }
                Button("Show in Finder") { reveal(ids) }
                Button("Copy File Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(items(ids).map(\.file.path).joined(separator: "\n"), forType: .string)
                }
                Divider()
                if items(ids).contains(where: { !$0.done && !$0.failed }) {
                    Button("Cancel Download") { for it in items(ids) { store.cancel(it.id) } }
                }
                Button("Remove from List") { remove(ids) }
            } primaryAction: { open($0) }
            .onDeleteCommand { remove(selection) }
            .overlay { if list.isEmpty { Text(q.isEmpty ? "No downloads yet" : "Nothing found").foregroundStyle(.secondary) } }
            Divider()
            HStack {
                Button("Show in Finder") { reveal(selection) }.disabled(selection.isEmpty)
                Button("Remove") { remove(selection) }.disabled(selection.isEmpty)
                Spacer()
                Button("Open Downloads Folder") {
                    if let d = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                        NSWorkspace.shared.open(store.items.first?.file.deletingLastPathComponent() ?? d)
                    }
                }
                Button("Clear List") { store.clear(); selection = [] }
                    .disabled(!store.items.contains { $0.done || $0.failed })
            }
            .padding(10)
        }
    }

    private func items(_ ids: Set<UUID>) -> [DownloadStore.Item] { store.items.filter { ids.contains($0.id) } }

    private func open(_ ids: Set<UUID>) {
        for it in items(ids) where it.done { NSWorkspace.shared.open(it.file) }
    }

    private func reveal(_ ids: Set<UUID>) {
        let files = items(ids).map(\.file).filter { FileManager.default.fileExists(atPath: $0.path) }
        if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
    }

    private func remove(_ ids: Set<UUID>) {
        store.remove(ids)
        selection.subtract(ids)
    }
}

private struct DownloadLine: View {
    @State private var store = DownloadStore.shared
    let item: DownloadStore.Item

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: item.file.path)
        let p = store.progress[item.id]
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.file.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Group {
                    if !item.done && !item.failed {
                        if let p, p >= 0 { ProgressView(value: p).progressViewStyle(.linear).controlSize(.small) }
                        else { Text("Downloading…") }
                    } else if item.cancelled == true {
                        Text("Cancelled")
                    } else if item.failed {
                        Text("Failed").foregroundStyle(Color.red.opacity(0.8))
                    } else if !exists {
                        Text("Moved or deleted")
                    } else {
                        Text(Self.size(item.file))
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(item.started.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .opacity(item.done && !exists ? 0.55 : 1)
        .padding(.vertical, 2)
        .help(item.file.path)
    }

    private static func size(_ url: URL) -> String {
        let n = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

/// Кнопка «Загрузки» в полосе: пока качается — вокруг значка кольцо хода; клик — список (как ⌘⇧J)
struct DownloadsBarButton: View {
    @Environment(BrowserModel.self) private var model
    @State private var store = DownloadStore.shared

    var body: some View {
        let active = store.active
        let known = active.compactMap { store.progress[$0.id] }.filter { $0 >= 0 }
        let total = known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
        ToolbarButton(icon: "arrow.down.circle", help: "Downloads — \(Shortcuts.shared.text(.downloads))") {
            model.showCommandBar(.downloads)
        }
        .overlay {
            if !active.isEmpty {
                Circle().trim(from: 0, to: max(0.03, total ?? 0.25))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 22, height: 22)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.25), value: total)
            }
        }
    }
}
