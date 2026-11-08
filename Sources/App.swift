import AppKit
import SwiftUI
import WebKit

@main
struct SapfireApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = BrowserModel.primary

    var body: some Scene {
        Window("Sapfire", id: "main") {
            BrowserWindow()
                .environment(model)
                .frame(minWidth: 720, minHeight: 460)
                .background(WindowCorner())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 900)
        .commands { BrowserCommands() }

    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitors: [Any] = []

    /// Ссылки из других программ (когда Sapfire — браузер по умолчанию) и файлы .html
    func application(_ application: NSApplication, open urls: [URL]) {
        let little = UserDefaults.standard.object(forKey: Prefs.linksInLittleWindow) as? Bool ?? true
        for u in urls {
            if little && !u.isFileURL { LittleWindow.open(u); Tips.show(.littleWindow) }
            else {
                BrowserModel.shared.newTab(url: u)
                BrowserModel.shared.mainWindow?.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Два пальца по странице — назад / вперёд. Движок берёт это из системной настройки «перелистывание
        // страниц»; если она выключена (жесты отданы трём пальцам), включаем её только для Sapfire
        UserDefaults.standard.set(true, forKey: "AppleEnableSwipeNavigateWithScrolls")
        WebEngine.applyCookiesEverywhere()
        Tunnel.applyAll()
        IconWatcher.start()         // сохранили sapfire_icon.psd — новая иконка в Dock без перезапуска
        PiPStyle.install()          // «картинка в картинке» проявляется на месте, а не вылетает из страницы
        NetworkReset.start()        // сеть сменилась (VPN, Wi-Fi, сон) — сбросить умершие подключения движка
        IncognitoLock.shared.start()
        Ext.start()
        Updates.start()             // раз в сутки — нет ли новой версии на GitHub (Settings → General → Updates)
        Setup.shared.autoStart()    // первый запуск — настройка в 4 экрана, в конце — предложение тура (потом Help → Welcome Tour)
        // Окна, открытые при прошлом выходе
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { BrowserModel.restoreWindows() }

        // Клавиши, которые надо перехватить раньше меню и веб-страницы
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
            // Окно, в котором нажали (у каждого окна браузера — своё состояние)
            let m = BrowserModel.windows.first { $0.window != nil && $0.window === e.window } ?? BrowserModel.current
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Сочетания клавиш расширений
            if !(e.window is LittleWindow), e.window === m.window, Ext.handleKey(e) { return nil }
            // Маленькое окно: ⌘W закрывает его, ⌘L — правка адреса; остальное — как обычно
            if let lw = e.window as? LittleWindow {
                switch Shortcuts.shared.action(for: e) {
                case .closeTab: lw.close(); return nil
                case .openLocation, .editAddress:
                    lw.page.address = lw.page.url?.absoluteString ?? ""; lw.page.editing = true; return nil
                case .back where !EditingFocus.shared.textWantsUndo(in: lw): PageSwipe.shared.step(lw.page.webView, back: true); return nil
                case .forward where !EditingFocus.shared.textWantsUndo(in: lw): PageSwipe.shared.step(lw.page.webView, back: false); return nil
                default: return e
                }
            }
            // Остальные окна (настройки) — клавиши как обычно, без перехватов браузера
            if let w = e.window, w !== m.mainWindow { return e }
            // Инкогнито заперто: обычные клавиши (пробел, стрелки…) и ⌃Tab — не в страницу и не по вкладкам; ↩ — «Unlock»
            if IncognitoLock.covers(m) {
                let plain = flags.intersection([.command, .option]).isEmpty
                if plain && e.keyCode != 36 && e.keyCode != 76 { return nil }
            }
            // ⌃Tab / ⌃⇧Tab — переключатель последних вкладок
            if flags.contains(.control) && e.keyCode == 48 {
                withAnimation(.easeOut(duration: 0.12)) {
                    m.switcher.step(flags.contains(.shift) ? -1 : 1, model: m)
                }
                return nil
            }
            if e.keyCode == 53, m.switcher.visible { m.switcher.cancel(); return nil }
            // ⌥Tab — быстро: два последних пространства; дольше (⌥ зажат, Tab ещё раз или держишь) — по кругу
            if e.keyCode == 48, flags.subtracting([.shift, .capsLock, .function, .numericPad]) == .option, m.commandBar == nil {
                m.spaceTab(flags.contains(.shift) ? -1 : 1)
                return nil
            }
            // ↑ / ↓, пока курсор над сайдбаром, — соседняя вкладка (в поле ввода стрелки остаются тексту)
            if e.keyCode == 125 || e.keyCode == 126, flags.subtracting([.function, .numericPad]).isEmpty,
               m.commandBar == nil, !m.overview.visible, m.sidebarVisible || m.sidebarPeek,
               let w = m.mainWindow, w.mouseLocationOutsideOfEventStream.x < Metrics.sidebarWidth,
               !EditingFocus.shared.textWantsUndo(in: w) {
                m.stepTab(e.keyCode == 125 ? 1 : -1)
                return nil
            }
            // Peek: Esc закрывает карточку (⌘W — через «Close tab»)
            if m.peek != nil, m.commandBar == nil, e.keyCode == 53 {
                m.closePeek(); return nil
            }
            if e.keyCode == 53, m.overview.visible { m.overview.close(); return nil }
            if e.keyCode == 53, m.commandBar == nil, Summarizer.shared.visible { Summarizer.shared.close(); return nil }
            if e.keyCode == 53, m.commandBar == nil, ImageCapture.shared.picking { ImageCapture.shared.cancelPick(); return nil }
            if e.keyCode == 53, m.commandBar == nil, ImageCapture.shared.visible { ImageCapture.shared.close(); return nil }
            if m.commandBar != nil {
                switch e.keyCode {
                case 125: m.moveCommandSelection(1); return nil      // ↓
                case 126: m.moveCommandSelection(-1); return nil     // ↑
                case 53: m.hideCommandBar(); return nil              // Esc
                case 48: m.autocompleteBang(); return nil            // Tab
                default: break
                }
            }
            // Esc сбрасывает групповое выделение вкладок
            if m.commandBar == nil, e.keyCode == 53, !m.find.visible, !m.selection.ids.isEmpty {
                m.selection.clear()
                return nil
            }
            // Esc закрывает поиск по странице
            if m.commandBar == nil, e.keyCode == 53, m.find.visible {
                m.find.hide()
                return nil
            }
            // Горячие клавиши (Settings → Shortcuts). ⌘Z, ⌘← и ⌘→ в поле ввода остаются тексту
            if let a = Shortcuts.shared.action(for: e) {
                // Одна клавиша без ⌘/⌥/⌃ (` для обзора) в поле ввода — тоже текст
                if a.yieldsToText || (KeyCombo(e.keyCode, e.modifierFlags).isPlain && !Keys.isFunction(e.keyCode)),
                   EditingFocus.shared.textWantsUndo(in: e.window ?? NSApp.keyWindow) { return e }
                Shortcuts.run(a, m)
                return nil
            }
            return e
        }) { monitors.append(k) }

        // Отпустил Control — открываем выбранную в переключателе вкладку
        if let f = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { e in
            let m = BrowserModel.current
            if !e.modifierFlags.contains(.option) { m.endSpaceTab() }
            if m.switcher.visible && !e.modifierFlags.contains(.control) {
                withAnimation(.easeOut(duration: 0.12)) { m.switcher.commit(model: m) }
            }
            return e
        }) { monitors.append(f) }

        // Клик внутри одной из половин сплита делает её активной
        if let c = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { e in
            let m = BrowserModel.windows.first { $0.window != nil && $0.window === e.window } ?? BrowserModel.current
            if let content = e.window?.contentView {
                var v = content.hitTest(e.locationInWindow)
                while let cur = v, !(cur is WKWebView) { v = cur.superview }
                if let wv = v as? WKWebView, let tab = m.tab(for: wv) {
                    if let i = m.currentSpace.paneTabs.firstIndex(where: { $0 === tab }), m.activePane != i { m.activePane = i }
                }
            }
            return e
        }) { monitors.append(c) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrowserModel.shared.save()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct BrowserCommands: Commands {
    /// Команды меню действуют в окне, где сейчас работают
    private var model: BrowserModel { .current }

    /// Пункт меню: действие и его текущее сочетание (Settings → Shortcuts)
    private func item(_ title: String, _ id: ShortcutID) -> some View {
        Button(title) { Shortcuts.run(id) }.shortcut(id)
    }

    var body: some Commands {
        // Настройки — своё окно (тянется, без системной полосы заголовка)
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsWindow.show() }
                .keyboardShortcut(",")
            Button("Check for Updates…") { Updates.check(manual: true) }
        }

        CommandGroup(replacing: .newItem) {
            item("New Tab", .newTab)
            item("Open Location…", .openLocation)
            item("Edit Current Address", .editAddress)
            item("Split with New Tab", .splitNew)
            item("New Window", .newWindow)
            item("New Little Window", .littleWindow)
            item("Reopen Closed Tab", .reopenClosed)
            Divider()
            item("History", .history)
            item("Show All History", .allHistory)
            item("Downloads", .downloads)
            item("Show All Downloads", .allDownloads)
            item("Archived Tabs", .archive)
            Divider()
            item("Close Tab", .closeTab)
            item("Close Window", .closeWindow)
        }
        CommandGroup(replacing: .saveItem) {
            item("Save Page As…", .savePage)
        }
        CommandGroup(replacing: .importExport) {
            Button("Import from Arc…") { ArcImport.run() }.disabled(!ArcImport.available)
            Button("Import from Another Browser…") { BrowserImport.run() }
            Button("Import Bookmarks from HTML…") { BrowserImport.importHTMLFile() }
            Button("Import Passwords from CSV…") { PasswordStore.importCSV() }
            Divider()
            Button("Restore Sidebar from Backup…") { BackupsWindow.show() }
        }
        CommandGroup(replacing: .printItem) {
            item("Share…", .share)
            item("Print…", .print)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            item("Copy Link", .copyLink)
            item("Copy Link as Markdown", .copyMarkdown)
            item("Copy as Quote", .copyQuote)
        }

        CommandMenu("Tab") {
            item("Back", .back)
            item("Forward", .forward)
            item("Reload", .reload)
            item("Reload Without Cache", .reloadNoCache)
            item("Clear Cookies and Reload", .clearCookies)
            item("Reset Network Connections", .resetNetwork)
            item("Stop Loading", .stop)
            Divider()
            item("Reader", .reader)
            if Module.summarize.isOn { item("Summarize Page", .summarize) }
            if Module.capture.isOn { item("Capture Image", .captureImage) }
            item("Translate Page", .translate)
            Divider()
            item("Web Inspector", .inspector)
            Divider()
            item("Find on Page", .find)
            item("Find Next", .findNext)
            item("Find Previous", .findPrev)
            Divider()
            item("Undo Tab Action", .undo)
            item("Redo Tab Action", .redo)
            Divider()
            item("New Folder…", .newFolder)
            item("Duplicate Tab", .duplicate)
            item("Pin / Unpin", .pin)
            item("Close Split", .closeSplit)
            item("Mute / Unmute Tab", .mute)
            item("Mute All Tabs", .muteAll)
            item("Clear Unpinned Tabs", .clearTemp)
            item("Reveal Tab in Sidebar", .revealTab)
            item("Reset Pinned Tabs", .resetPinned)
            Divider()
            item("Next Tab", .nextTab)
            item("Previous Tab", .prevTab)
            item("Tab Overview", .overview)
            ForEach(1...9, id: \.self) { i in
                item("Pinned Site \(i)", ShortcutID(rawValue: "pinned\(i)")!)
            }
        }

        CommandMenu("Spaces") {
            item("New Space", .newSpace)
            item("Next Space", .nextSpace)
            item("Previous Space", .prevSpace)
            Divider()
            item("Rename Space…", .renameSpace)
            item("Icon & Color…", .spaceLook)
            Menu("Profile") {
                ForEach(model.profiles) { p in
                    Toggle(p.name, isOn: Binding(get: { model.currentSpace.profileID == p.id },
                                                 set: { if $0 { model.setProfile(model.currentSpace, p) } }))
                }
                Divider()
                Button("New Profile…") { model.newProfile(for: model.currentSpace) }
            }
            .disabled(model.currentSpace.isIncognito)
            Divider()
            item("New Incognito Space", .incognito)
            Button("Lock Incognito") { IncognitoLock.shared.lock() }
                .disabled(!model.spaces.contains { $0.isIncognito } || !IncognitoLock.enabled)
            Button("Close Incognito Space") {
                if let s = model.spaces.first(where: { $0.isIncognito }) { model.closeIncognito(s) }
            }
            .disabled(!model.spaces.contains { $0.isIncognito })
            Divider()
            ForEach(1...9, id: \.self) { i in
                item("Space \(i)", ShortcutID(rawValue: "space\(i)")!)
            }
        }

        CommandMenu("Extensions") {
            ExtensionsMenuItems()
        }

        CommandGroup(replacing: .help) {
            Button("Set Up Sapfire…") { Setup.shared.start() }
            Button("Welcome Tour") { Tour.shared.start() }
        }
        CommandGroup(after: .windowArrangement) {
            item("Float on Top", .floatOnTop)
        }

        CommandGroup(before: .toolbar) {
            item("Sidebar", .sidebar)
            item("Compact / Expand Sidebar", .compactSidebar)
            item("Show / Hide Toolbar", .toolbar)
            item("Zoom In", .zoomIn)
            item("Zoom Out", .zoomOut)
            item("Actual Size", .actualSize)
            Divider()
            Toggle("Block Ads", isOn: Binding(
                get: { model.adBlockEnabled },
                set: { model.adBlockEnabled = $0 }))
            Divider()
        }
    }
}
