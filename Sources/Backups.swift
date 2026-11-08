import AppKit
import SwiftUI

// MARK: - Резервные копии панели

/// Копии state.json (пространства, вкладки, папки, профили) — в `backups/` рядом с ним: при запуске и не чаще раза
/// в 30 минут при сохранении, одинаковые подряд не дублируются. Хранятся 10 последних, за сутки — по одной в час,
/// за 30 дней — по одной в день (раньше только 10 последних — это 5 часов: пропажу, замеченную назавтра, было не вернуть). File → Restore Sidebar from
/// Backup… — выбрать копию: текущее состояние перед этим уходит в копию, Sapfire перезапускается с выбранной.
enum StateBackups {
    static let keep = 10
    static let minInterval: TimeInterval = 30 * 60
    private static var last: Date?
    /// Идёт восстановление: текущее состояние больше не сохранять (иначе при выходе оно затёрло бы выбранную копию)
    static var restoring = false

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sapfire/backups", isDirectory: true)
    }
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    struct Entry: Identifiable {
        let url: URL, date: Date, spaces: Int, tabs: Int
        var id: URL { url }
    }
    private struct Peek: Decodable {
        struct S: Decodable { struct T: Decodable {}; let tabs: [T] }
        let spaces: [S]
    }

    /// Перед записью нового state.json — отложить прежний. `force` — без оглядки на 30 минут (при запуске)
    static func snapshot(of file: URL, force: Bool = false) {
        if !force, let l = last, Date().timeIntervalSince(l) < minInterval { return }
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return }
        last = Date()
        let had = list()
        if let newest = had.first, let d = try? Data(contentsOf: newest.url), d == data { return }   // ничего не менялось
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("state-" + stamp.string(from: Date()) + ".json"), options: .atomic)
        prune()
    }

    /// Прореживание: 10 последних + самая новая за каждый час последних суток + самая новая за каждый день 30 дней
    private static func prune() {
        let all = list(), now = Date()
        var keepURLs = Set(all.prefix(keep).map(\.url))
        var hours = Set<String>(), days = Set<String>()
        let h = DateFormatter(); h.dateFormat = "yyyyMMddHH"; h.locale = Locale(identifier: "en_US_POSIX")
        for e in all {
            let age = now.timeIntervalSince(e.date)
            let hk = h.string(from: e.date), dk = String(hk.prefix(8))
            if age < 86400, hours.insert(hk).inserted { keepURLs.insert(e.url) }
            if age < 30 * 86400, days.insert(dk).inserted { keepURLs.insert(e.url) }
        }
        for e in all where !keepURLs.contains(e.url) { try? FileManager.default.removeItem(at: e.url) }
    }

    /// Копии, новые первыми
    static func list() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { u -> Entry? in
            guard let d = try? Data(contentsOf: u), let p = try? JSONDecoder().decode(Peek.self, from: d) else { return nil }
            let name = u.deletingPathExtension().lastPathComponent.dropFirst("state-".count)
            let date = stamp.date(from: String(name)) ?? ((try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            return Entry(url: u, date: date, spaces: p.spaces.count, tabs: p.spaces.reduce(0) { $0 + $1.tabs.count })
        }.sorted { $0.date > $1.date }
    }

    /// Восстановить: текущее — в копию, выбранную — на место state.json, перезапуск
    static func restore(_ e: Entry) {
        let a = NSAlert()
        a.messageText = "Restore the sidebar from \(e.date.formatted(date: .abbreviated, time: .shortened))?"
        a.informativeText = "\(e.spaces) spaces, \(e.tabs) tabs. Sapfire will quit and reopen with that sidebar. The sidebar as it is now is kept as a backup too, so you can come back."
        a.addButton(withTitle: "Restore and Relaunch")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        snapshot(of: BrowserModel.stateURL, force: true)
        guard let data = try? Data(contentsOf: e.url), (try? data.write(to: BrowserModel.stateURL, options: .atomic)) != nil else {
            BrowserModel.current.showToast("Couldn’t read that backup"); return
        }
        restoring = true
        relaunch()
    }

    /// Выйти и открыться заново (open ждёт, пока прежний процесс закончится)
    private static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"\(Bundle.main.bundlePath)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Окно

final class BackupsWindow {
    private static var window: NSWindow?

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Sidebar Backups"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 360, height: 260)
        w.contentView = NSHostingView(rootView: BackupsView { w.close() })
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in window = nil }
    }
}

private struct BackupsView: View {
    let close: () -> Void
    @State private var items: [StateBackups.Entry] = StateBackups.list()
    @State private var selection: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sapfire backs up the sidebar — spaces, tabs and folders — at launch and every half hour it changes, and keeps one copy per hour for a day and one per day for a month. Restoring one quits and reopens Sapfire.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(items, selection: $selection) { e in
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 13))
                    Text("\(e.spaces) spaces · \(e.tabs) tabs").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .tag(e.url)
            }
            .overlay { if items.isEmpty { Text("No backups yet").foregroundStyle(.secondary) } }
            HStack {
                Button("Back Up Now") {
                    BrowserModel.current.save()
                    StateBackups.snapshot(of: BrowserModel.stateURL, force: true)
                    items = StateBackups.list()
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([StateBackups.dir]) }
                Spacer()
                Button("Restore…") { if let e = items.first(where: { $0.url == selection }) { StateBackups.restore(e) } }
                    .disabled(selection == nil)
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 260)
    }
}
