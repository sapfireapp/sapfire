import AppKit

/// Иконка в Dock обновляется на лету: tools/icon.sh кладёт новую иконку (AppIcon.icns, Assets.car) в программу — Sapfire его подхватывает
/// (без перезапуска Dock и самой программы)
@MainActor
enum IconWatcher {
    private static var source: DispatchSourceFileSystemObject?
    private static var lastStamp: Date?

    static func start() {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return }
        lastStamp = modified(url)
        watch(url.deletingLastPathComponent())
    }

    /// Следим за папкой Resources: cp заменяет файл, за самим файлом слежка бы потерялась
    private static func watch(_ dir: URL) {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: .main)
        s.setEventHandler {
            MainActor.assumeIsolated {
                // Дать скрипту дописать файл
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { reload() }
            }
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    private static func reload() {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let m = modified(url), m != lastStamp, let img = NSImage(contentsOf: url) else { return }
        lastStamp = m
        NSApp.applicationIconImage = img
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
