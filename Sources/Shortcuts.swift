import AppKit
import SwiftUI

// MARK: - Свои горячие клавиши (Settings → Shortcuts)
//
// Все сочетания — в одном списке. Нажатия ловит перехват клавиш (раньше меню и страницы) и сравнивает
// по коду клавиши, а не по букве, — работают в любой раскладке. Меню только показывает текущие сочетания.

/// Сочетание: код клавиши + модификаторы (⌘ ⌥ ⌃ ⇧)
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    var mods: UInt

    static let modMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    init(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.mods = flags.intersection(Self.modMask).rawValue
    }
    init?(event e: NSEvent) {
        self.init(e.keyCode, e.modifierFlags)
    }
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: mods) }

    /// Как показывать: ⌃⌥⇧⌘ и клавиша
    var text: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + (Keys.name[keyCode] ?? "#\(keyCode)")
    }

    /// Для меню (если такую клавишу меню умеет показать)
    var menuKey: (KeyEquivalent, EventModifiers)? {
        guard let k = Keys.equivalent(keyCode) else { return nil }
        var m: EventModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.shift) { m.insert(.shift) }
        return (k, m)
    }

    /// Без ⌘/⌥/⌃ — одна клавиша (в поле ввода она остаётся тексту)
    var isPlain: Bool { flags.intersection([.command, .option, .control]).isEmpty }

    /// Годится ли как горячая клавиша: без ⌘/⌥/⌃ — только F1–F12 и клавиши, которыми почти не пишут
    /// (` и § слева от 1): буквы и цифры мешали бы набору текста
    var isValid: Bool { !isPlain || Keys.isFunction(keyCode) || Keys.plainOK.contains(keyCode) }
}

/// Коды клавиш (раскладка US — как подписаны клавиши на Mac)
enum Keys {
    static let name: [UInt16: String] = {
        var d: [UInt16: String] = [:]
        let letters: [(UInt16, String)] = [(0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"),
            (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"), (1, "S"),
            (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
            (24, "="), (27, "−"), (33, "["), (30, "]"), (41, ";"), (39, "'"), (43, ","), (47, "."), (44, "/"), (42, "\\"), (50, "`"), (10, "§"),
            (123, "←"), (124, "→"), (125, "↓"), (126, "↑"), (48, "⇥"), (36, "↩"), (53, "⎋"), (51, "⌫"), (117, "⌦"), (49, "Space"),
            (115, "↖"), (119, "↘"), (116, "⇞"), (121, "⇟"),
            (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"), (101, "F9"),
            (109, "F10"), (103, "F11"), (111, "F12")]
        for (k, n) in letters { d[k] = n }
        return d
    }()

    /// Клавиши, которые годятся в сочетание и без ⌘/⌥/⌃: ` и § (слева от 1)
    static let plainOK: Set<UInt16> = [50, 10]

    static func isFunction(_ k: UInt16) -> Bool { name[k]?.hasPrefix("F") == true && (name[k]?.count ?? 0) > 1 }

    static func equivalent(_ k: UInt16) -> KeyEquivalent? {
        switch k {
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        case 48: return .tab
        case 36: return .return
        case 53: return .escape
        case 51: return .delete
        case 117: return .deleteForward
        case 49: return .space
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        default:
            guard let n = name[k], n.count == 1 else { return nil }
            let c = n == "−" ? "-" : n.lowercased()
            return KeyEquivalent(Character(c))
        }
    }
}

/// Действия, которым можно назначить сочетание
enum ShortcutID: String, CaseIterable {
    // Вкладки
    case newTab, openLocation, editAddress, closeTab, reopenClosed, duplicate, pin, clearTemp,
         nextTab, prevTab, overview, newFolder, copyLink, copyMarkdown, copyQuote, mute, muteAll, undo, redo,
         revealTab, resetPinned
    case pinned1, pinned2, pinned3, pinned4, pinned5, pinned6, pinned7, pinned8, pinned9
    // Страница
    case back, forward, reload, reloadNoCache, resetNetwork, stop, find, findNext, findPrev, reader, translate, inspector,
         zoomIn, zoomOut, actualSize, print, savePage, share, clearCookies, summarize, captureImage
    // Сплит
    case splitNew, closeSplit, pane1, pane2, pane3, pane4
    // Пространства и окна
    case newSpace, nextSpace, prevSpace, renameSpace, spaceLook, incognito, newWindow, closeWindow, littleWindow, floatOnTop, sidebar, compactSidebar, toolbar
    case space1, space2, space3, space4, space5, space6, space7, space8, space9
    // Списки
    case history, allHistory, downloads, allDownloads, archive

    var title: String {
        switch self {
        case .newTab: "New tab"
        case .openLocation: "Open location"
        case .editAddress: "Edit current address"
        case .closeTab: "Close tab"
        case .reopenClosed: "Reopen closed tab"
        case .duplicate: "Duplicate tab"
        case .pin: "Pin / unpin"
        case .clearTemp: "Clear temporary tabs"
        case .nextTab: "Next tab"
        case .prevTab: "Previous tab"
        case .overview: "Tab overview"
        case .newFolder: "New folder"
        case .copyLink: "Copy link"
        case .copyMarkdown: "Copy link as Markdown"
        case .copyQuote: "Copy as quote"
        case .revealTab: "Reveal tab in sidebar"
        case .resetPinned: "Reset pinned tabs"
        case .print: "Print"
        case .savePage: "Save page as"
        case .share: "Share"
        case .summarize: "Summarize page"
        case .captureImage: "Capture image"
        case .clearCookies: "Clear cookies and reload"
        case .renameSpace: "Rename space"
        case .spaceLook: "Space icon & color"
        case .mute: "Mute / unmute tab"
        case .muteAll: "Mute all tabs"
        case .undo: "Undo tab action"
        case .redo: "Redo tab action"
        case .back: "Back"
        case .forward: "Forward"
        case .reload: "Reload"
        case .reloadNoCache: "Reload without cache"
        case .stop: "Stop loading"
        case .find: "Find on page"
        case .findNext: "Find next"
        case .findPrev: "Find previous"
        case .reader: "Reader"
        case .translate: "Translate page"
        case .inspector: "Web inspector"
        case .resetNetwork: "Reset network connections"
        case .zoomIn: "Zoom in"
        case .zoomOut: "Zoom out"
        case .actualSize: "Actual size"
        case .splitNew: "Split with new tab"
        case .closeSplit: "Close split"
        case .newSpace: "New space"
        case .nextSpace: "Next space"
        case .prevSpace: "Previous space"
        case .incognito: "Incognito"
        case .newWindow: "New window"
        case .closeWindow: "Close window"
        case .littleWindow: "Little window"
        case .floatOnTop: "Float on top"
        case .sidebar: "Show / hide sidebar"
        case .compactSidebar: "Compact sidebar"
        case .toolbar: "Show / hide toolbar"
        case .history: "History"
        case .allHistory: "Show all history"
        case .downloads: "Downloads"
        case .allDownloads: "Show all downloads"
        case .archive: "Archived tabs"
        default:
            if let n = number { rawValue.hasPrefix("pinned") ? "Pinned site \(n)" : rawValue.hasPrefix("pane") ? "Split pane \(n)" : "Space \(n)" }
            else { rawValue }
        }
    }

    var number: Int? { Int(String(rawValue.last!)) }

    var group: String {
        switch self {
        case .newTab, .openLocation, .editAddress, .closeTab, .reopenClosed, .duplicate, .pin, .clearTemp, .nextTab, .prevTab,
             .overview, .newFolder, .copyLink, .copyMarkdown, .copyQuote, .mute, .muteAll, .undo, .redo, .revealTab, .resetPinned: "Tabs"
        case .pinned1, .pinned2, .pinned3, .pinned4, .pinned5, .pinned6, .pinned7, .pinned8, .pinned9: "Pinned Sites"
        case .back, .forward, .reload, .reloadNoCache, .resetNetwork, .stop, .find, .findNext, .findPrev, .reader, .translate, .inspector,
             .zoomIn, .zoomOut, .actualSize, .print, .savePage, .share, .clearCookies, .summarize, .captureImage: "Page"
        case .splitNew, .closeSplit, .pane1, .pane2, .pane3, .pane4: "Split"
        case .history, .allHistory, .downloads, .allDownloads, .archive: "Lists"
        default: "Spaces & Windows"
        }
    }
    static let groups = ["Tabs", "Page", "Split", "Spaces & Windows", "Lists", "Pinned Sites"]

    /// В поле ввода клавиша остаётся тексту (⌘← — в начало строки, ⌘Z — отмена набора)
    /// ⌥1…⌥9 в поле ввода печатают знаки (¡ ™ £ …) — там остаются тексту
    var yieldsToText: Bool { [.back, .forward, .undo, .redo].contains(self) || (rawValue.hasPrefix("space") && number != nil) }

    var defaults: [KeyCombo] {
        let c: NSEvent.ModifierFlags = .command
        func k(_ code: UInt16, _ f: NSEvent.ModifierFlags = .command) -> KeyCombo { KeyCombo(code, f) }
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        switch self {
        case .newTab: return [k(17)]
        case .openLocation: return [k(37)]
        case .editAddress: return [k(14)]
        case .closeTab: return [k(13)]
        case .reopenClosed: return [k(17, [c, .shift])]
        case .duplicate: return [k(2)]
        case .pin: return [k(2, [c, .shift])]
        case .clearTemp: return [k(40, [c, .shift])]
        case .nextTab: return [k(125, [c, .option])]
        case .prevTab: return [k(126, [c, .option])]
        case .overview: return [k(42, [c, .shift]), KeyCombo(50, [])]       // ⌘⇧\ и ` (в поле ввода ` — текст)
        case .newFolder: return [k(3, [c, .shift])]
        case .copyLink: return [k(8, [c, .shift])]
        case .copyMarkdown: return [k(8, [c, .option, .shift])]
        case .copyQuote: return [k(8, [c, .control, .shift])]
        case .print: return [k(35)]
        case .savePage: return [k(1, [c, .shift])]
        case .summarize: return [k(32, [c, .option])]
        case .captureImage: return [k(19, [c, .shift])]
        case .revealTab, .resetPinned, .share, .clearCookies, .renameSpace, .spaceLook, .resetNetwork: return []
        case .mute: return [k(46, [c, .control])]
        case .muteAll: return [k(46, [c, .control, .shift])]
        case .undo: return [k(6)]
        case .redo: return [k(6, [c, .shift])]
        case .back: return [k(123), k(33)]
        case .forward: return [k(124), k(30)]
        case .reload: return [k(15)]
        case .reloadNoCache: return [k(15, [c, .shift])]
        case .stop: return [k(47)]
        case .find: return [k(3)]
        case .findNext: return [k(5)]
        case .findPrev: return [k(5, [c, .shift])]
        case .reader: return [k(15, [c, .option])]
        case .translate: return [k(17, [c, .option])]
        case .inspector: return [k(34, [c, .option])]
        case .zoomIn: return [k(24)]
        case .zoomOut: return [k(27)]
        case .actualSize: return [k(29)]
        case .splitNew: return [k(14, [c, .shift]), k(24, [.control, .shift])]
        case .closeSplit: return [k(14, [c, .option]), k(27, [.control, .shift])]
        case .newSpace: return [k(45, [c, .control])]
        case .nextSpace: return [k(124, [c, .option]), k(48, .option)]
        case .prevSpace: return [k(123, [c, .option]), k(48, [.option, .shift])]
        case .incognito: return [k(45, [c, .shift])]
        case .newWindow: return [k(45)]
        case .closeWindow: return [k(13, [c, .shift])]
        case .littleWindow: return [k(45, [c, .option])]
        case .floatOnTop: return [k(35, [c, .control])]
        case .sidebar: return [k(1)]
        case .compactSidebar: return [k(1, [c, .option])]
        case .toolbar: return [k(37, [c, .shift])]
        case .history: return [k(16)]
        case .allHistory: return [k(16, [c, .option])]
        case .downloads: return [k(38, [c, .shift])]
        case .allDownloads: return [k(37, [c, .option])]
        case .archive: return [k(0, [c, .shift])]
        case .pinned1, .pinned2, .pinned3, .pinned4, .pinned5, .pinned6, .pinned7, .pinned8, .pinned9:
            return [k(digits[number! - 1])]
        case .space1, .space2, .space3, .space4, .space5, .space6, .space7, .space8, .space9:
            return [k(digits[number! - 1], .option)]       // ⌥1…⌥9
        case .pane1, .pane2, .pane3, .pane4:
            return [k(digits[number! - 1], [.control, .shift])]
        }
    }
}

@Observable
final class Shortcuts {
    static let shared = Shortcuts()
    private static let key = "shortcuts"
    /// Изменённые пользователем (остальные — по умолчанию); пустой список — без сочетания
    private(set) var custom: [String: [KeyCombo]] = [:]

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let c = try? JSONDecoder().decode([String: [KeyCombo]].self, from: d) { custom = c }
    }

    func combos(_ id: ShortcutID) -> [KeyCombo] { custom[id.rawValue] ?? id.defaults }
    func isCustom(_ id: ShortcutID) -> Bool { custom[id.rawValue] != nil && custom[id.rawValue] != id.defaults }
    func text(_ id: ShortcutID) -> String { combos(id).map(\.text).joined(separator: " / ") }

    /// Кто сейчас на этом сочетании
    func owner(of c: KeyCombo) -> ShortcutID? { ShortcutID.allCases.first { combos($0).contains(c) } }

    /// Назначить сочетание (у другого действия оно не забирается — оба подсвечиваются как конфликт)
    func set(_ id: ShortcutID, _ c: KeyCombo?) {
        custom[id.rawValue] = c.map { [$0] } ?? []
        save()
    }

    /// Сочетания, занятые самой macOS и меню «Правка» (в них Sapfire вмешиваться не должен)
    static let system: [KeyCombo: String] = {
        let c: NSEvent.ModifierFlags = .command
        return [KeyCombo(8, c): "Copy", KeyCombo(9, c): "Paste", KeyCombo(7, c): "Cut", KeyCombo(0, c): "Select All",
                KeyCombo(12, c): "Quit", KeyCombo(4, c): "Hide", KeyCombo(4, [c, .option]): "Hide Others", KeyCombo(46, c): "Minimize",
                KeyCombo(43, c): "Settings", KeyCombo(50, c): "Switch windows", KeyCombo(49, c): "Spotlight",
                KeyCombo(48, c): "Switch apps", KeyCombo(9, [c, .shift, .option]): "Paste and Match Style",
                KeyCombo(48, .control): "Recent tabs (Sapfire)", KeyCombo(53, []): "Esc (Sapfire)"]
    }()

    /// С чем конфликтует сочетание действия: другие действия Sapfire и занятые системой
    func conflicts(_ id: ShortcutID) -> [String] {
        var out: [String] = []
        for c in combos(id) {
            for o in ShortcutID.allCases where o != id && combos(o).contains(c) { out.append("\(c.text) — also “\(o.title)”") }
            if let s = Self.system[c] { out.append("\(c.text) — macOS: \(s)") }
        }
        return out
    }
    var conflictCount: Int { ShortcutID.allCases.filter { !conflicts($0).isEmpty }.count }

    func reset(_ id: ShortcutID) { custom[id.rawValue] = nil; save() }
    func resetAll() { custom = [:]; save() }

    private func save() {
        if let d = try? JSONEncoder().encode(custom) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    /// Какое действие у нажатия
    func action(for e: NSEvent) -> ShortcutID? {
        let c = KeyCombo(e.keyCode, e.modifierFlags)
        return ShortcutID.allCases.first { combos($0).contains(c) }
    }

    // MARK: Выполнить

    static func run(_ id: ShortcutID, _ m: BrowserModel = .current) {
        // Инкогнито заперто — вкладки, страница и сплит недоступны (печать, сохранение, обзор, копирование адреса…)
        if IncognitoLock.covers(m), ["Tabs", "Page", "Split"].contains(id.group) { return }
        Tour.shared.ran(id)
        let t = m.activeTab
        switch id {
        case .newTab: m.showCommandBar(.newTab)
        case .openLocation, .editAddress: m.showCommandBar(.current)
        case .closeTab: if m.peek != nil { m.closePeek() } else { m.closeActiveTab() }
        case .reopenClosed: m.reopenClosed()
        case .duplicate: m.duplicateSelectionOrActive()
        case .pin: if let t { m.togglePin(t) }
        case .clearTemp: m.clearUnpinned()
        case .nextTab: m.cycleTab(1)
        case .prevTab: m.cycleTab(-1)
        case .overview: m.overview.toggle(model: m)
        case .newFolder: m.newFolder()
        case .copyLink: m.copyURL()
        case .copyMarkdown: m.copyMarkdown()
        case .copyQuote: m.copyQuote()
        case .revealTab: m.revealActiveTab()
        case .resetPinned: m.resetPinned()
        case .print: m.printPage()
        case .savePage: m.savePage()
        case .share: m.share()
        case .summarize: if Module.summarize.isOn { Summarizer.shared.toggle(m) }
        case .captureImage: ImageCapture.shared.pick(m)
        case .clearCookies: m.clearCookiesAndReload()
        case .renameSpace: m.rename(m.currentSpace)
        case .spaceLook: m.editSpaceLook()
        case .mute: t?.muted.toggle()
        case .muteAll: m.muteAll()
        case .undo: BrowserUndo.shared.undo(model: m)
        case .redo: BrowserUndo.shared.redo(model: m)
        case .back: PageSwipe.shared.step(t?.webView, back: true)
        case .forward: PageSwipe.shared.step(t?.webView, back: false)
        case .reload: t?.reload()
        case .reloadNoCache: t?.webView?.reloadFromOrigin()
        case .stop: t?.webView?.stopLoading()
        case .find: m.find.show()
        case .findNext: m.find.next()
        case .findPrev: m.find.prev()
        case .reader: m.toggleReader()
        case .translate: PageTranslator.shared.toggle(t)
        case .inspector: m.showInspector()
        case .resetNetwork: NetworkReset.now(manual: true)
        case .zoomIn: m.zoom(0.1)
        case .zoomOut: m.zoom(-0.1)
        case .actualSize: m.zoom(0)
        case .splitNew: m.showCommandBar(.split)
        case .closeSplit: m.closeSplit()
        case .newSpace: m.addSpace()
        case .nextSpace: m.cycleSpace(1)
        case .prevSpace: m.cycleSpace(-1)
        case .incognito: m.openIncognito()
        case .newWindow:
            let w = BrowserModel.openWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Tips.show(.windows, w) }
        case .closeWindow: (NSApp.keyWindow ?? m.mainWindow)?.performClose(nil)
        case .littleWindow: LittleWindow.open(nil)
        case .floatOnTop: m.toggleFloatOnTop()
        case .sidebar: m.sidebarVisible.toggle()
        case .compactSidebar: m.toggleCompactSidebar()
        case .toolbar: PageToolbar.toggle(); if !PageToolbar.enabled { Tips.show(.focus, m) }
        case .history: m.showCommandBar(.history)
        case .allHistory: HistoryWindow.show()
        case .downloads: m.showCommandBar(.downloads)
        case .allDownloads: DownloadsWindow.show()
        case .archive: m.showCommandBar(.archive)
        case .pinned1, .pinned2, .pinned3, .pinned4, .pinned5, .pinned6, .pinned7, .pinned8, .pinned9: m.selectTab(number: id.number!)
        case .space1, .space2, .space3, .space4, .space5, .space6, .space7, .space8, .space9: m.swipe.switchTo(id.number! - 1, model: m)
        case .pane1, .pane2, .pane3, .pane4: m.focusPane(id.number!)
        }
    }
}

extension View {
    /// Пункт меню показывает текущее сочетание действия (нажатия ловит перехват клавиш)
    func shortcut(_ id: ShortcutID) -> some View { modifier(ShortcutKey(id: id)) }
}

extension NSMenuItem {
    /// Пункт меню (AppKit) показывает текущее сочетание действия — как .shortcut(_:) у SwiftUI.
    /// Не для пунктов с альтернативой по ⌥: та узнаётся по тому же сочетанию, что у основного
    func showShortcut(_ id: ShortcutID) {
        guard let (k, m) = Shortcuts.shared.combos(id).lazy.compactMap({ $0.isPlain ? nil : $0.menuKey }).first else { return }
        var f: NSEvent.ModifierFlags = []
        if m.contains(.command) { f.insert(.command) }
        if m.contains(.option) { f.insert(.option) }
        if m.contains(.control) { f.insert(.control) }
        if m.contains(.shift) { f.insert(.shift) }
        keyEquivalent = String(k.character)
        keyEquivalentModifierMask = f
    }
}

private struct ShortcutKey: ViewModifier {
    let id: ShortcutID
    @State private var store = Shortcuts.shared
    func body(content: Content) -> some View {
        if let (k, m) = store.combos(id).lazy.compactMap({ $0.isPlain ? nil : $0.menuKey }).first { content.keyboardShortcut(k, modifiers: m) } else { content }   // одна клавиша в меню перехватывала бы набор текста
    }
}

// MARK: - Страница Settings → Shortcuts

struct ShortcutsPage: View {
    @State private var store = Shortcuts.shared
    @State private var recording: ShortcutID?
    @State private var note: String?
    @State private var monitor: Any?
    @State private var query = ""
    @State private var onlyConflicts = false

    /// Подходит под поиск: по названию, группе или сочетанию («⌘T», «cmd t», «opt»)
    private func matches(_ id: ShortcutID) -> Bool {
        if onlyConflicts && store.conflicts(id).isEmpty { return false }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let keys = store.text(id).lowercased()
        let spelled = keys.replacingOccurrences(of: "⌘", with: "cmd ").replacingOccurrences(of: "⌥", with: "opt ")
            .replacingOccurrences(of: "⌃", with: "ctrl ").replacingOccurrences(of: "⇧", with: "shift ")
        return id.title.lowercased().contains(q) || id.group.lowercased().contains(q) || keys.contains(q) || spelled.contains(q)
    }

    var body: some View {
        let n = store.conflictCount
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Search shortcuts — name or keys", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).frame(height: 24)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .circular))
                if n > 0 {
                    Toggle(isOn: $onlyConflicts) {
                        Label("\(n) conflict\(n == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                    }
                    .toggleStyle(.button).controlSize(.small).tint(.orange)
                    .help("Show only shortcuts that clash")
                }
                Button("Restore All") { stop(); store.resetAll(); note = nil }
                    .controlSize(.small)
                    .disabled(!ShortcutID.allCases.contains { store.isCustom($0) })
            }
            .padding(.bottom, 6)
            Text("Click a shortcut and press new keys. Esc — cancel, Delete — no shortcut.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.bottom, 10)
            if let note {
                Label(note, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.orange)
                    .padding(.bottom, 8)
            }
            let groups = ShortcutID.groups.filter { g in ShortcutID.allCases.contains { $0.group == g && matches($0) } }
            if groups.isEmpty {
                Text(onlyConflicts ? "No conflicts" : "Nothing found").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            ForEach(groups, id: \.self) { g in
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                    ForEach(ShortcutID.allCases.filter { $0.group == g && matches($0) }, id: \.self) { id in row(id) }
                }
                .padding(.bottom, 14)
            }
            if query.isEmpty && !onlyConflicts {
                fixedRow("⌃Tab / ⌃⇧Tab", "Recent tabs (hold ⌃)")
                fixedRow("Esc", "Close command bar, find, overview, Peek")
            }
        }
        .onChange(of: n) { if n == 0 { onlyConflicts = false } }
        .onDisappear { stop() }
    }

    private func row(_ id: ShortcutID) -> some View {
        let clash = store.conflicts(id)
        return HStack(spacing: 8) {
            Text(id.title).font(.system(size: 12)).lineLimit(1)
            if !clash.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    .help(clash.joined(separator: "\n"))
                Text(clash.first!).font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer(minLength: 8)
            if store.isCustom(id) {
                Button { store.reset(id); note = nil } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Restore “\(Shortcuts.shared.defaultsText(id))”")
            }
            Button { recording == id ? stop() : start(id) } label: {
                Text(recording == id ? "Type shortcut…" : (store.text(id).isEmpty ? "—" : store.text(id)))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(recording == id ? Color.accentColor : .primary)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 86, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .circular).fill(!clash.isEmpty && recording != id ? Color.orange.opacity(0.18) : Color.primary.opacity(recording == id ? 0.1 : 0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .circular).stroke(recording == id ? Color.accentColor : (!clash.isEmpty ? Color.orange : .clear), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        }
        .frame(height: 24)
    }

    private func fixedRow(_ keys: String, _ title: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(keys).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).frame(minWidth: 86, minHeight: 22)
        }
        .frame(height: 24)
        .help("Fixed shortcut")
    }

    private func start(_ id: ShortcutID) {
        stop()
        recording = id
        SettingsNav.shared.recording = true
        note = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard let id = recording else { return e }
            let flags = e.modifierFlags.intersection(KeyCombo.modMask)
            if e.keyCode == 53 && flags.isEmpty { stop(); return nil }                       // Esc — отмена
            if (e.keyCode == 51 || e.keyCode == 117) && flags.isEmpty {                     // Delete — без сочетания
                store.set(id, nil); stop(); return nil
            }
            let c = KeyCombo(e.keyCode, e.modifierFlags)
            guard c.isValid else {
                note = "Add ⌘, ⌥ or ⌃ — a plain key would get in the way of typing (only ` § and F-keys work alone)."
                return nil
            }
            store.set(id, c)
            note = store.conflicts(id).first.map { "Conflict: \($0). Change one of them." }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = nil
        SettingsNav.shared.recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

extension Shortcuts {
    func defaultsText(_ id: ShortcutID) -> String { id.defaults.map(\.text).joined(separator: " / ") }
}

// MARK: - Жесты трекпада (Settings → Gestures)

/// Жесты тремя пальцами: каждому можно назначить любое действие из списка горячих клавиш (или ничего)
enum GestureID: String, CaseIterable {
    case left, right, up, down, tap

    var title: String {
        switch self {
        case .left: "Swipe left"
        case .right: "Swipe right"
        case .up: "Swipe up"
        case .down: "Swipe down"
        case .tap: "Tap"
        }
    }
    var icon: String {
        switch self {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .tap: "hand.tap"
        }
    }
    /// Как было: пальцы влево — следующая вкладка (как листать страницы), вверх — закрыть, вниз — отменить, тап — обзор
    var defaultAction: ShortcutID? {
        switch self {
        case .left: .nextTab
        case .right: .prevTab
        case .up: .closeTab
        case .down: .undo
        case .tap: .overview
        }
    }
}

enum Gestures {
    private static let key = "gestureActions"
    private static var stored: [String: String] { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }

    /// Действие жеста (nil — ничего)
    static func action(_ g: GestureID) -> ShortcutID? {
        guard let v = stored[g.rawValue] else { return g.defaultAction }
        return v == "none" ? nil : ShortcutID(rawValue: v)
    }
    static func set(_ g: GestureID, _ a: ShortcutID?) {
        var s = stored
        s[g.rawValue] = a?.rawValue ?? "none"
        UserDefaults.standard.set(s, forKey: key)
    }
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
    static var isCustom: Bool { !stored.isEmpty }

    // Жесты двумя пальцами — можно выключить по отдельности
    static var pages: Bool { UserDefaults.standard.object(forKey: Prefs.twoFingerPages) as? Bool ?? true }
    static var spaces: Bool { UserDefaults.standard.object(forKey: Prefs.twoFingerSpaces) as? Bool ?? true }
    static var window: Bool { UserDefaults.standard.object(forKey: Prefs.twoFingerWindow) as? Bool ?? true }
}

/// Строка «жест → действие» с выпадающим списком всех действий
struct GestureRow: View {
    let gesture: GestureID
    /// Ширина колонки подписей (как у остальных строк настроек) — выпадающие встают в одну колонку с галками
    var labelWidth: CGFloat = 190
    /// Выпадающий список ужимается до остатка строки (узкая карточка тура), а не по своему содержимому
    var flexible = false
    @State private var tick = 0
    var body: some View {
        let _ = tick
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 1) { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 4, height: 4) } }
                    .frame(width: 14, alignment: .leading).foregroundStyle(.secondary)
                Image(systemName: gesture.icon).font(.system(size: 11, weight: .semibold)).frame(width: 14)
                Text(gesture.title + ":").font(.system(size: 13)).frame(width: 90, alignment: .trailing)
            }
            .frame(width: labelWidth, alignment: .trailing)
            Picker("", selection: Binding(
                get: { Gestures.action(gesture)?.rawValue ?? "none" },
                set: { Gestures.set(gesture, ShortcutID(rawValue: $0)); tick += 1 })) {
                Text("Nothing").tag("none")
                ForEach(ShortcutID.groups, id: \.self) { g in
                    Section(g) {
                        ForEach(ShortcutID.allCases.filter { $0.group == g }, id: \.self) { a in
                            Text(a.title).tag(a.rawValue)
                        }
                    }
                }
            }
            .labelsHidden()
            .modifier(PickerSizing(flexible: flexible))
            if !flexible { Spacer(minLength: 0) }
        }
    }
}

private struct PickerSizing: ViewModifier {
    let flexible: Bool
    func body(content: Content) -> some View {
        if flexible { content.frame(maxWidth: .infinity) } else { content.fixedSize() }
    }
}
