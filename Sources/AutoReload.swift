import AppKit
import SwiftUI
import WebKit

// MARK: - Автообновление вкладки

/// Вкладка обновляется сама раз в N секунд (меню «⋯» или правый клик по вкладке → Auto Reload).
/// По желанию — с сохранением масштаба (щипок) и места на странице. Пока в поле страницы печатают — не обновляем.
/// Вкладка с автообновлением не засыпает.
enum AutoReload {
    static let choices: [(seconds: Int, title: String)] = [
        (30, "Every 30 Seconds"), (60, "Every Minute"), (300, "Every 5 Minutes"),
        (900, "Every 15 Minutes"), (1800, "Every 30 Minutes"), (3600, "Every Hour"),
    ]

    static func label(_ s: Int) -> String {
        s < 60 ? "every \(s) s" : s < 3600 ? "every \(s / 60) min" : s == 3600 ? "every hour" : "every \(s / 3600) h"
    }

    private static var timers: [UUID: Timer] = [:]
    /// Что вернуть после обновления: место на странице и масштаб
    private static var pending: [ObjectIdentifier: (x: Double, y: Double, magnification: CGFloat)] = [:]

    static func set(_ tab: Tab, every s: Int?) {
        tab.autoReload = s
        schedule(tab)
        tab.browser?.save()
        if let s { tab.browser?.showToast("Auto reload \(label(s))") }
    }

    static func setKeepView(_ tab: Tab, _ on: Bool) {
        tab.reloadKeepView = on
        tab.browser?.save()
    }

    static func schedule(_ tab: Tab) {
        timers.removeValue(forKey: tab.id)?.invalidate()
        guard let s = tab.autoReload, s > 0 else { return }
        let id = tab.id
        let t = Timer(timeInterval: TimeInterval(s), repeats: true) { [weak tab] _ in
            guard let tab else { timers.removeValue(forKey: id)?.invalidate(); return }
            fire(tab)
        }
        t.tolerance = min(5, Double(s) * 0.1)          // системе легче собрать пробуждения вместе
        RunLoop.main.add(t, forMode: .common)
        timers[id] = t
    }

    private static func fire(_ tab: Tab) {
        // Вкладку закрыли — таймер больше не нужен
        guard let m = tab.browser, m.allTabs.contains(where: { $0 === tab }), tab.autoReload != nil else {
            timers.removeValue(forKey: tab.id)?.invalidate(); return
        }
        guard Module.autoReload.isOn else { return }
        guard let wv = tab.webView else { tab.ensureWebView(); return }     // уснула — просто открыть заново
        guard !tab.isLoading, !EditingFocus.shared.isEditing(wv) else { return }
        guard tab.reloadKeepView else {
            pending.removeValue(forKey: ObjectIdentifier(wv))
            wv.reload()
            return
        }
        wv.evaluateJavaScript("[window.scrollX, window.scrollY]") { r, _ in
            let p = r as? [Double] ?? [0, 0]
            pending[ObjectIdentifier(wv)] = (p.first ?? 0, p.last ?? 0, wv.magnification)
            wv.reload()
        }
    }

    /// Страница догрузилась (из делегата): вернуть масштаб и место
    static func finished(_ wv: WKWebView) {
        guard let p = pending.removeValue(forKey: ObjectIdentifier(wv)) else { return }
        if p.magnification != 1 { wv.magnification = p.magnification }
        let js = "window.scrollTo(\(p.x), \(p.y))"
        wv.evaluateJavaScript(js)
        // Часть страниц дорисовывается позже (картинки, ленты) — ещё раз чуть погодя
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak wv] in wv?.evaluateJavaScript(js) }
    }

    /// Пункты для меню «⋯» (AppKit)
    static func menu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        let off = ClosureMenuItem("Off") { set(tab, every: nil) }
        off.state = tab.autoReload == nil ? .on : .off
        menu.addItem(off)
        menu.addItem(.separator())
        for c in choices {
            let item = ClosureMenuItem(c.title) { set(tab, every: c.seconds) }
            item.state = tab.autoReload == c.seconds ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let keep = ClosureMenuItem("Keep Zoom and Scroll Position") { setKeepView(tab, !tab.reloadKeepView) }
        keep.state = tab.reloadKeepView ? .on : .off
        menu.addItem(keep)
        return menu
    }
}

/// То же меню для правого клика по вкладке (SwiftUI)
struct AutoReloadMenu: View {
    let tab: Tab
    var body: some View {
        Menu("Auto Reload") {
            Toggle("Off", isOn: Binding(get: { tab.autoReload == nil }, set: { if $0 { AutoReload.set(tab, every: nil) } }))
            Divider()
            ForEach(AutoReload.choices, id: \.seconds) { c in
                Toggle(c.title, isOn: Binding(get: { tab.autoReload == c.seconds }, set: { if $0 { AutoReload.set(tab, every: c.seconds) } }))
            }
            Divider()
            Toggle("Keep Zoom and Scroll Position", isOn: Binding(get: { tab.reloadKeepView }, set: { AutoReload.setKeepView(tab, $0) }))
        }
    }
}
