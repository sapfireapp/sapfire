import AppKit
import SwiftUI

// MARK: - Окно поверх всех

extension BrowserModel {
    /// ⌃⌘P — активное окно (главное или маленькое) держится поверх остальных программ
    func toggleFloatOnTop(_ w: NSWindow? = NSApp.keyWindow) {
        guard let w = w ?? mainWindow else { return }
        let on = w.level != .floating
        Self.setFloating(w, on)
        if let lw = w as? LittleWindow { lw.page.onTop = on; return }
        UserDefaults.standard.set(on, forKey: Prefs.floatOnTop)
        showToast(on ? "Window stays on top" : "Window no longer on top")
    }

    static func setFloating(_ w: NSWindow, _ on: Bool) {
        w.level = on ? .floating : .normal
        // Поверх — и на всех рабочих столах рядом с полноэкранными программами
        if on { w.collectionBehavior.insert(.fullScreenAuxiliary) } else { w.collectionBehavior.remove(.fullScreenAuxiliary) }
    }

    /// Главное окно было поверх всех при прошлом запуске
    func restoreFloatOnTop() {
        guard isPrimary, UserDefaults.standard.bool(forKey: Prefs.floatOnTop), let w = mainWindow else { return }
        Self.setFloating(w, true)
    }

    var mainWindowOnTop: Bool { mainWindow?.level == .floating }
}

// MARK: - Несколько окон (⌘N)

extension BrowserModel {
    /// Пространство открыто в другом окне — вывести то окно вперёд. true — так и сделали.
    @discardableResult
    func focusOwner(of sp: Space) -> Bool {
        guard let other = Self.window(showing: sp), other !== self, let w = other.mainWindow else { return false }
        w.makeKeyAndOrderFront(nil)
        other.showToast("“\(sp.name)” is open in this window")
        return true
    }

    /// Соседнее пространство в сторону `dir`, пропуская открытые в других окнах
    func neighborSpace(from i: Int, _ dir: Int) -> Int? {
        var j = i + dir
        while spaces.indices.contains(j) {
            if Self.window(showing: spaces[j]).map({ $0 === self }) ?? true { return j }
            j += dir
        }
        return nil
    }

    /// Пространство, свободное для нового окна (не открытое ни в одном окне)
    private static func freeSpace() -> Space? {
        BrowserData.shared.spaces.first { !$0.isIncognito && window(showing: $0) == nil }
    }

    /// ⌘N — новое окно. В нём — первое пространство, не открытое в других окнах; если заняты все — новое пространство.
    @discardableResult
    static func openWindow(space: Space? = nil, frame: NSRect? = nil, sidebar: Bool = true) -> BrowserModel {
        let m = BrowserModel()
        let data = BrowserData.shared
        let sp: Space
        if let s = space ?? freeSpace() {
            sp = s
        } else {
            let n = data.spaces.count
            sp = Space(name: "Space \(n + 1)", icon: spaceIcons[n % spaceIcons.count],
                       hue: (0.58 + Double(n) * 0.17).truncatingRemainder(dividingBy: 1))
            data.spaces.append(sp)
        }
        m.currentSpaceID = sp.id
        m.sidebarVisible = sidebar
        windows.append(m)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Sapfire"                     // по имени окна ему достаются свой светофор и крупные углы
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 720, height: 460)
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.contentView = NSHostingView(rootView: BrowserWindow().environment(m).frame(minWidth: 720, minHeight: 460).background(WindowCorner()))
        m.window = w
        if let frame {
            w.setFrame(frame, display: false)
        } else if let base = current.mainWindow?.frame, current !== m {
            // Рядом с текущим, лесенкой
            w.setFrame(base.offsetBy(dx: 28, dy: -28), display: false)
        } else {
            w.center()
        }
        m.watchClose(w)
        w.makeKeyAndOrderFront(nil)
        lastActive = m
        m.updateWindowButtons()
        m.save()
        return m
    }

    /// При запуске: открыть окна, что были открыты при выходе
    static func restoreWindows() {
        let list = pendingWindows
        pendingWindows = []
        guard !list.isEmpty else { return }
        for sw in list {
            guard let sp = BrowserData.shared.spaces.first(where: { $0.id == sw.space }), window(showing: sp) == nil else { continue }
            openWindow(space: sp, frame: sw.frame.map(NSRectFromString), sidebar: sw.sidebar)
        }
        primary.mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Открыть пространство в новом окне (оно не должно быть открыто здесь или где-то ещё)
    func openInNewWindow(_ sp: Space) {
        if focusOwner(of: sp) { return }
        if sp.id == currentSpaceID {
            // Здесь остаётся другое свободное пространство (если его нет — новое окно получит это, а тут — новое)
            guard let other = spaces.first(where: { $0 !== sp && !$0.isIncognito && Self.window(showing: $0) == nil }) else { return }
            currentSpaceID = other.id
        }
        let w = Self.openWindow(space: sp)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Tips.show(.windows, w) }
    }

    /// Первым открытым окном держится невидимый помощник перевода (иначе страница переводилась бы дважды)
    var hostsTranslator: Bool { (Self.windows.first { $0.window != nil } ?? Self.primary) === self }

    /// Следим, когда окно закроют: модель окна уходит, вкладки остаются в своих пространствах
    func watchClose(_ w: NSWindow) {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.windowClosed()
        }
    }

    private func windowClosed() {
        peek.map { _ in closePeek() }
        stopWatchers()
        window = nil
        if Self.lastActive === self { Self.lastActive = nil }
        if !isPrimary { Self.windows.removeAll { $0 === self } }
        if let o = closeObserver { NotificationCenter.default.removeObserver(o); closeObserver = nil }
        save()
    }

    /// Пространство удалили (или закрыли инкогнито): окна, где оно было открыто, переходят на свободное
    static func fixWindows() {
        let ids = Set(BrowserData.shared.spaces.map(\.id))
        var taken = Set<UUID>()
        for m in windows where m.window != nil || m.isPrimary {
            if ids.contains(m.currentSpaceID), !taken.contains(m.currentSpaceID) { taken.insert(m.currentSpaceID); continue }
            if let s = BrowserData.shared.spaces.first(where: { !taken.contains($0.id) }) {
                m.currentSpaceID = s.id
                taken.insert(s.id)
            } else if !m.isPrimary {
                m.window?.close()      // пространств на всех не хватает — лишнее окно закрываем
            }
        }
    }
}

/// Узнаёт своё окно: у каждого окна браузера — своя модель
struct WindowAccessor: NSViewRepresentable {
    let model: BrowserModel

    final class V: NSView {
        weak var model: BrowserModel?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window, let m = model else { return }
            m.window = w
            m.watchClose(w)
            w.contentView?.allowedTouchTypes.insert(.indirect)   // касания трекпада для жестов тремя пальцами
            if w.isKeyWindow || BrowserModel.lastActive == nil { BrowserModel.lastActive = m }
        }
    }

    func makeNSView(context: Context) -> V { let v = V(); v.model = model; return v }
    func updateNSView(_ v: V, context: Context) { v.model = model }
}
