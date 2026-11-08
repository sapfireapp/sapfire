import AppKit
import SwiftUI

// MARK: - Вся история (отдельное окно)

/// Вся история в окне: по дням, поиск, открыть (двойной клик / Return), удалить (Delete), очистить
final class HistoryWindow {
    private static var window: NSWindow?

    static func show() {
        BrowserModel.current.hideCommandBar()
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "History"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 480, height: 320)
        w.setFrameAutosaveName("SapfireHistory")
        w.contentView = NSHostingView(rootView: HistoryPage())
        if w.frame.origin == .zero { w.center() }
        w.makeKeyAndOrderFront(nil)
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in window = nil }
    }
}

private struct HistoryPage: View {
    @State private var store = HistoryStore.shared
    @State private var query = ""
    @State private var selection = Set<String>()

    private struct Day: Identifiable {
        var title: String
        var items: [HistoryStore.Entry]
        var id: String { title }
    }

    private func days(_ list: [HistoryStore.Entry]) -> [Day] {
        let cal = Calendar.current
        var out: [Day] = []
        var key: Date?
        for e in list {
            let d = cal.startOfDay(for: e.lastVisit)
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
        let q = query.trimmingCharacters(in: .whitespaces)
        // Поиск — по всей истории, но в порядке времени, чтобы дни не перемешивались
        let list = q.isEmpty ? store.entries
            : store.search(q, limit: 2000).sorted { $0.lastVisit > $1.lastVisit }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history", text: $query).textFieldStyle(.plain).font(.system(size: 14))
                Text("\(list.count) page\(list.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).frame(height: 40)
            Divider()
            List(selection: $selection) {
                ForEach(days(list)) { day in
                    Section(day.title) {
                        ForEach(day.items) { HistoryLine(entry: $0).tag($0.id) }
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Open") { open(ids) }
                Button("Open in Background") { open(ids, background: true) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ids.joined(separator: "\n"), forType: .string)
                }
                Divider()
                Button("Delete") { delete(ids) }
            } primaryAction: { open($0) }
            .onDeleteCommand { delete(selection) }
            .overlay { if list.isEmpty { Text(q.isEmpty ? "No history yet" : "Nothing found").foregroundStyle(.secondary) } }
            Divider()
            HStack {
                Button("Delete") { delete(selection) }.disabled(selection.isEmpty)
                Spacer()
                Button("Clear History…") { confirmClear() }.disabled(store.entries.isEmpty)
            }
            .padding(10)
        }
    }

    private func entries(_ ids: Set<String>) -> [HistoryStore.Entry] { store.entries.filter { ids.contains($0.id) } }

    private func open(_ ids: Set<String>, background: Bool = false) {
        let m = BrowserModel.current
        for e in entries(ids).reversed() { m.open(e.url, target: .newTab) }
        if !background { m.mainWindow?.makeKeyAndOrderFront(nil) }
    }

    private func delete(_ ids: Set<String>) {
        for e in entries(ids) { store.remove(e) }
        selection.subtract(ids)
    }

    private func confirmClear() {
        let a = NSAlert()
        a.messageText = "Clear all history?"
        a.informativeText = "All visited pages will be removed from history. Open tabs, pinned sites and website data stay."
        a.addButton(withTitle: "Clear History")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { store.clear(); selection = [] }
    }
}

private struct HistoryLine: View {
    let entry: HistoryStore.Entry
    var body: some View {
        HStack(spacing: 10) {
            Favicon(url: entry.url).frame(width: 16, height: 16)
            Text(entry.title.isEmpty ? entry.url.absoluteString : entry.title).lineLimit(1)
            Text(entry.url.host ?? "").foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            if entry.visits > 1 { Text("×\(entry.visits)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary) }
            Text(entry.lastVisit.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .padding(.vertical, 2)
        .help(entry.url.absoluteString)
    }
}
