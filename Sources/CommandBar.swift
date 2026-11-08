import AppKit
import SwiftUI
import WebKit

// MARK: - Положение командной строки (⌘T / ⌘L / ⌘E)

/// Строку можно двигать двумя пальцами; булавка фиксирует её место (и запоминает),
/// снятие булавки возвращает строку в центр.
@Observable
final class CommandBarPosition {
    /// Своё у каждого окна; `shared` — у окна, в котором сейчас работают
    static var shared: CommandBarPosition { BrowserModel.current.commandPos }

    var offset: CGSize = .zero
    var pinned: Bool = UserDefaults.standard.bool(forKey: "cmdbar.pinned")
    @ObservationIgnored var frame: CGRect = .zero          // в координатах окна (сверху вниз)
    @ObservationIgnored private var clickMonitor: Any?

    init() {
        if pinned {
            let d = UserDefaults.standard
            offset = CGSize(width: d.double(forKey: "cmdbar.x"), height: d.double(forKey: "cmdbar.y"))
        }
    }

    func togglePin() {
        pinned.toggle()
        UserDefaults.standard.set(pinned, forKey: "cmdbar.pinned")
        if pinned { save() } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { offset = .zero }
        }
    }

    private func save() {
        UserDefaults.standard.set(Double(offset.width), forKey: "cmdbar.x")
        UserDefaults.standard.set(Double(offset.height), forKey: "cmdbar.y")
    }

    /// Двигаем строку на величину свайпа (если не приколота). true — событие съедено.
    /// Тянуть можно только за верхнюю часть (строку ввода) — как окно за заголовок.
    static let handleHeight: CGFloat = 54

    /// Жест начался на строке — ведём её до конца жеста, даже когда она уехала из-под курсора
    /// (при свайпе двумя пальцами курсор стоит на месте, а строка движется).
    @ObservationIgnored private var dragging = false
    /// Жест закончился — строка ещё немного скользит по инерции
    @ObservationIgnored private var gliding = false

    func scroll(_ e: NSEvent, at p: CGPoint, window: NSWindow) -> Bool {
        if e.momentumPhase != [] {
            guard gliding else { return frame.contains(p) }
            move(by: e, window: window)
            if e.momentumPhase == .ended || e.momentumPhase == .cancelled { gliding = false }
            return true
        }
        if e.phase == .began || e.phase == .mayBegin {
            gliding = false
            dragging = !pinned && frame.contains(p) && p.y < frame.minY + Self.handleHeight
        }
        if dragging {
            move(by: e, window: window)
            if e.phase == .ended || e.phase == .cancelled { dragging = false; gliding = true }
            return true
        }
        // Колёсико мыши (без фаз) — как раньше: только над верхней частью строки
        guard frame.contains(p) else { return false }
        if e.phase == [], !pinned, p.y < frame.minY + Self.handleHeight { move(by: e, window: window) }
        return true
    }

    private func move(by e: NSEvent, window: NSWindow) {
        let sg: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        var dx = e.scrollingDeltaX * sg, dy = e.scrollingDeltaY * sg
        // Не выпускаем строку за пределы окна (frame — где она сейчас)
        if let c = window.contentView?.bounds {
            dx = min(max(dx, 8 - frame.minX), c.width - 8 - frame.maxX)
            dy = min(max(dy, 8 - frame.minY), c.height - 8 - frame.maxY)
        }
        var o = offset
        o.width += dx; o.height += dy
        offset = o
        // Курсор едет вместе со строкой — будто держишь её за точку под пальцами
        // (у экрана y растёт вверх, у строки — вниз)
        guard dx != 0 || dy != 0 else { return }
        let m = NSEvent.mouseLocation
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: m.x + dx, y: screenH - (m.y - dy)))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    func opened(model: BrowserModel) {
        if !pinned { offset = .zero }
        // Клик мимо строки закрывает её (а сам клик уходит странице)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            if let self, let content = e.window?.contentView {
                let p = CGPoint(x: e.locationInWindow.x, y: content.bounds.height - e.locationInWindow.y)
                if !self.frame.contains(p) { DispatchQueue.main.async { model.hideCommandBar() } }
            }
            return e
        }
    }

    func closed() {
        dragging = false; gliding = false
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }
}

/// Точка-фиксатор в углу строки: пустая — строка свободна, залитая — закреплена на месте.
struct PinDot: View {
    static let hit: CGFloat = 20
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(on ? Color.accentColor : Color.clear)
                .overlay(Circle().strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: 1.5))
                .frame(width: hover ? 10 : 8, height: hover ? 10 : 8)
                .frame(width: Self.hit, height: Self.hit)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hover = $0 }
        .help(on ? "Unpin — back to center" : "Pin here")
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: on)
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}


// MARK: - Действия из командной строки

/// Набрал в командной строке «копировать ссылку», «дублировать», «сплит»… — выполнилось
struct CommandAction {
    let title: String
    let icon: String
    let keys: String           // сочетание клавиш — показать рядом
    let words: [String]        // по каким словам искать (англ. и рус.)
    let run: () -> Void
    var strong = false         // набранное совпало с началом названия

    static func all(_ m: BrowserModel) -> [CommandAction] {
        let t = m.activeTab
        var a: [CommandAction] = [
            .init(title: "Copy Link", icon: "link", keys: Shortcuts.shared.text(.copyLink), words: ["copy", "link", "url", "копировать", "ссылка", "адрес"]) { m.copyURL() },
            .init(title: "Copy Link as Markdown", icon: "text.badge.checkmark", keys: Shortcuts.shared.text(.copyMarkdown), words: ["copy", "markdown", "md", "копировать", "маркдаун"]) { m.copyMarkdown() },
            .init(title: "Copy as Quote", icon: "text.quote", keys: Shortcuts.shared.text(.copyQuote), words: ["copy", "quote", "цитата", "копировать"]) { m.copyQuote() },
            .init(title: "Summarize Page", icon: "sparkles", keys: Shortcuts.shared.text(.summarize), words: ["summarize", "summary", "tldr", "пересказ", "кратко", "суть"]) { Summarizer.shared.start(m) },
            .init(title: "Share…", icon: "square.and.arrow.up", keys: Shortcuts.shared.text(.share), words: ["share", "airdrop", "send", "поделиться", "отправить"]) { m.share() },
            .init(title: "Print…", icon: "printer", keys: Shortcuts.shared.text(.print), words: ["print", "pdf", "печать", "распечатать"]) { m.printPage() },
            .init(title: "Save Page As…", icon: "square.and.arrow.down", keys: Shortcuts.shared.text(.savePage), words: ["save", "page", "archive", "pdf", "сохранить", "страница"]) { m.savePage() },
            .init(title: "Clear Cookies and Reload", icon: "arrow.clockwise.circle", keys: Shortcuts.shared.text(.clearCookies), words: ["cookies", "clear", "reload", "куки", "очистить"]) { m.clearCookiesAndReload() },
            .init(title: "Reveal Tab in Sidebar", icon: "sidebar.left", keys: Shortcuts.shared.text(.revealTab), words: ["reveal", "show", "sidebar", "find tab", "показать", "найти вкладку"]) { m.revealActiveTab() },
            .init(title: "Reset Pinned Tabs", icon: "pin.circle", keys: Shortcuts.shared.text(.resetPinned), words: ["reset", "pinned", "сбросить", "закреплённые"]) { m.resetPinned() },
            .init(title: "Rename Space", icon: "pencil", keys: Shortcuts.shared.text(.renameSpace), words: ["rename", "space", "переименовать", "пространство"]) { m.rename(m.currentSpace) },
            .init(title: "Space Icon & Color", icon: "paintpalette", keys: Shortcuts.shared.text(.spaceLook), words: ["theme", "color", "icon", "space", "тема", "цвет", "значок"]) { m.editSpaceLook() },
            .init(title: "Duplicate Tab", icon: "plus.square.on.square", keys: Shortcuts.shared.text(.duplicate), words: ["duplicate", "дублировать", "копия"]) { m.duplicateSelectionOrActive() },
            .init(title: t?.isPinned == true ? "Unpin Tab" : "Pin Tab", icon: "pin", keys: Shortcuts.shared.text(.pin), words: ["pin", "unpin", "закрепить", "открепить"]) { if let t { m.togglePin(t) } },
            .init(title: "Split View with New Tab", icon: "rectangle.split.2x1", keys: Shortcuts.shared.text(.splitNew), words: ["split", "сплит", "разделить"]) { m.showCommandBar(.split) },
            .init(title: "Close Split", icon: "rectangle", keys: Shortcuts.shared.text(.closeSplit), words: ["close split", "закрыть сплит"]) { m.closeSplit() },
            .init(title: "Reader", icon: "doc.plaintext", keys: Shortcuts.shared.text(.reader), words: ["reader", "read", "чтение", "читать"]) { m.toggleReader() },
            .init(title: "Translate Page", icon: "character.bubble", keys: Shortcuts.shared.text(.translate), words: ["translate", "перевести", "перевод"]) { PageTranslator.shared.toggle(t) },
            .init(title: t?.muted == true ? "Unmute Tab" : "Mute Tab", icon: "speaker.slash", keys: Shortcuts.shared.text(.mute), words: ["mute", "sound", "звук", "выключить звук", "тихо"]) { t?.muted.toggle() },
            .init(title: "Mute All Tabs", icon: "speaker.slash.fill", keys: Shortcuts.shared.text(.muteAll), words: ["mute all", "звук везде", "тишина"]) { m.muteAll() },
            .init(title: "Clear Cookies and Site Data", icon: "trash", keys: "", words: ["cookies", "clear", "site data", "куки", "очистить", "данные сайта"]) { m.clearSiteData() },
            .init(title: "Reload Without Cache", icon: "arrow.clockwise", keys: Shortcuts.shared.text(.reloadNoCache), words: ["reload", "hard reload", "обновить", "перезагрузить"]) { t?.webView?.reloadFromOrigin() },
            .init(title: "New Folder", icon: "folder.badge.plus", keys: Shortcuts.shared.text(.newFolder), words: ["folder", "new folder", "папка"]) { m.newFolder() },
            .init(title: "New Space", icon: "square.stack.3d.up", keys: Shortcuts.shared.text(.newSpace), words: ["space", "new space", "пространство"]) { m.addSpace() },
            .init(title: "New Incognito Space", icon: "eyeglasses", keys: Shortcuts.shared.text(.incognito), words: ["incognito", "private", "инкогнито"]) { m.openIncognito() },
            .init(title: "Clear Temporary Tabs", icon: "arrow.down.to.line", keys: Shortcuts.shared.text(.clearTemp), words: ["clear", "archive", "очистить", "архивировать"]) { m.clearUnpinned() },
            .init(title: PageToolbar.enabled ? "Hide Toolbar" : "Show Toolbar", icon: "rectangle.topthird.inset.filled", keys: Shortcuts.shared.text(.toolbar), words: ["toolbar", "address bar", "hide", "compact", "тулбар", "фокус", "адрес"]) { PageToolbar.toggle() },
            .init(title: "Toggle Sidebar", icon: "sidebar.left", keys: Shortcuts.shared.text(.sidebar), words: ["sidebar", "панель"]) { m.sidebarVisible.toggle() },
            .init(title: "History", icon: "clock.arrow.circlepath", keys: Shortcuts.shared.text(.history), words: ["history", "история"]) { m.showCommandBar(.history) },
            .init(title: "Downloads", icon: "arrow.down.circle", keys: Shortcuts.shared.text(.downloads), words: ["downloads", "загрузки"]) { m.showCommandBar(.downloads) },
            .init(title: "Archived Tabs", icon: "archivebox", keys: Shortcuts.shared.text(.archive), words: ["archive", "архив"]) { m.showCommandBar(.archive) },
            .init(title: m.mainWindowOnTop ? "Stop Floating on Top" : "Float on Top", icon: "pin.square", keys: Shortcuts.shared.text(.floatOnTop), words: ["float", "on top", "always", "поверх", "окно"]) { m.toggleFloatOnTop(m.mainWindow) },
            .init(title: "New Window", icon: "macwindow.badge.plus", keys: Shortcuts.shared.text(.newWindow), words: ["window", "new window", "окно", "новое окно"]) { BrowserModel.openWindow() },
            .init(title: "Little Window", icon: "macwindow", keys: Shortcuts.shared.text(.littleWindow), words: ["little", "window", "окно"]) { LittleWindow.open(nil) },
            .init(title: "Restore Sidebar from Backup", icon: "clock.arrow.circlepath", keys: "", words: ["backup", "restore", "sidebar", "резервная", "копия", "восстановить"]) { BackupsWindow.show() },
            .init(title: "Web Inspector", icon: "hammer", keys: Shortcuts.shared.text(.inspector), words: ["inspector", "devtools", "инспектор"]) { m.showInspector() },
            .init(title: "Settings", icon: "gearshape", keys: "⌘,", words: ["settings", "preferences", "настройки"]) {
                SettingsWindow.show()
            },
        ]
        if t?.url == nil { a.removeAll { ["Copy Link", "Copy Link as Markdown", "Clear Cookies and Site Data", "Reader", "Translate Page"].contains($0.title) } }
        return a
    }

    /// Подходящие под набранное: начало названия — выше, совпадение слова — ниже
    static func matching(_ text: String, model: BrowserModel) -> [CommandAction] {
        let q = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, !q.hasPrefix("!"), Omnibox.directURL(q) == nil else { return [] }
        var out: [(CommandAction, Int)] = []
        for var a in all(model) {
            let title = a.title.lowercased()
            if title.hasPrefix(q) { a.strong = q.count >= 3; out.append((a, 3)) }
            else if title.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { out.append((a, 2)) }
            else if a.words.contains(where: { $0.hasPrefix(q) || (q.count >= 4 && $0.contains(q)) }) { out.append((a, 1)) }
        }
        return out.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

extension BrowserModel {
    /// Копировать ссылку как [Заголовок](адрес)
    func copyMarkdown() {
        guard let t = activeTab, let u = t.url?.absoluteString else { return }
        let title = t.displayTitle.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[\(title)](\(u))", forType: .string)
        showToast("Markdown link copied")
    }

    /// Стереть куки и данные открытого сайта (в его профиле) и перезагрузить
    func clearSiteData() {
        guard let t = activeTab, let wv = t.webView, let site = SiteSettings.site(t.url) else { return }
        let store = wv.configuration.websiteDataStore
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let mine = records.filter { r in let n = r.displayName.lowercased(); return n == site || site.hasSuffix("." + n) || n.hasSuffix("." + site) }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine) {
                t.reload()
                self.showToast("Cleared data for \(site)")
            }
        }
    }
}
