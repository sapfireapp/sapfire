import AppKit
import ObjectiveC

// MARK: - «Картинка в картинке»: проявление вместо вылета

/// Окно PiP рисует системный агент (PIPAgent): по умолчанию видео «вылетает» из страницы и уезжает в запомненный
/// угол. Здесь иначе: окно встаёт на место сразу, а видео проявляется из прозрачности. Окно агента само по себе
/// прозрачное — виден только наш слой с видео (WebKit держит его в этом процессе и отдаёт агенту), поэтому плавная
/// непрозрачность слоя и есть проявление всего окна (проверено замером яркости). Угол — тот, что помнит система
/// (перетащить можно, она запомнит; программно угол не задаётся — агент такие события не принимает).
/// Всё через закрытые методы PIP.framework: каждый проверяется, нет метода — остаётся обычное поведение.
enum PiPStyle {
    static let fadeDuration: TimeInterval = 0.45
    /// Агент не сообщил о положении окна — проявить всё равно (видео не должно остаться невидимым)
    private static let fallbackDelay: TimeInterval = 0.3

    private typealias ShowIMP = @convention(c) (AnyObject, Selector, UInt32, CGRect, Bool, AnyObject?, AnyObject?) -> Void
    private typealias PresentIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private typealias RectIMP = @convention(c) (AnyObject, Selector, CGRect, AnyObject?) -> Void

    private static let showSel = NSSelectorFromString("agentShowPIP:fromScreenRect:animating:withFence:completion:")
    private static let presentSel = NSSelectorFromString("presentViewControllerAsPictureInPicture:")
    private static let rectSel = NSSelectorFromString("_pipSetWindowContentRect:completion:")

    /// Слой с видео, который сейчас показывает агент (скрыт до проявления)
    private static weak var content: NSView?
    private static var fadeWork: DispatchWorkItem?

    static func install() {
        dlopen("/System/Library/PrivateFrameworks/PIP.framework/PIP", RTLD_NOW)
        guard let proxy = NSClassFromString("PIPAgentProxy"), let controller = NSClassFromString("PIPViewController"),
              let show = class_getInstanceMethod(proxy, showSel),
              let present = class_getInstanceMethod(controller, presentSel),
              let rect = class_getInstanceMethod(controller, rectSel) else { return }

        // Видео отдают агенту — пока прозрачное
        let origPresent = unsafeBitCast(method_getImplementation(present), to: PresentIMP.self)
        let presentBlock: @convention(block) (AnyObject, AnyObject) -> Void = { me, vc in
            if let v = (vc as? NSViewController)?.view { content = v; v.alphaValue = 0 }
            origPresent(me, presentSel, vc)
            // Агент мог не показать окно заново (PiP уже открыт — видео просто сменилось) и не сообщить о месте —
            // тогда видео осталось бы невидимым: проявить в любом случае
            scheduleFade(after: fallbackDelay * 2)
        }
        method_setImplementation(present, imp_implementationWithBlock(presentBlock))

        // Показ окна — без анимации вылета; проявление начнётся, когда агент сообщит, что окно на месте
        let origShow = unsafeBitCast(method_getImplementation(show), to: ShowIMP.self)
        let showBlock: @convention(block) (AnyObject, UInt32, CGRect, Bool, AnyObject?, AnyObject?) -> Void = { me, ctx, from, _, fence, done in
            origShow(me, showSel, ctx, from, false, fence, done)
            scheduleFade(after: fallbackDelay)
        }
        method_setImplementation(show, imp_implementationWithBlock(showBlock))

        // Агент сообщил положение окна — оно уже на экране, проявляем
        let origRect = unsafeBitCast(method_getImplementation(rect), to: RectIMP.self)
        let rectBlock: @convention(block) (AnyObject, CGRect, AnyObject?) -> Void = { me, r, done in
            origRect(me, rectSel, r, done)
            if content?.alphaValue == 0 { scheduleFade(after: 0) }
        }
        method_setImplementation(rect, imp_implementationWithBlock(rectBlock))
        addReturnToPage()
    }

    /// Кнопка окна PiP «вернуть на страницу»: WebKit в чужой программе её не обрабатывает (у Safari — своя обвязка).
    /// Добавляем обработчик сами: найти вкладку, где видео в PiP, открыть её и вернуть видео на страницу
    private static func addReturnToPage() {
        guard let cls = NSClassFromString("WebVideoPresentationInterfaceMacObjC") else { return }
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in DispatchQueue.main.async { returnToPage() } }
        let imp = imp_implementationWithBlock(block)
        for name in ["pipActionRestore:", "pipActionReturn:"] {
            let sel = NSSelectorFromString(name)
            if class_getInstanceMethod(cls, sel) == nil { class_addMethod(cls, sel, imp, "v@:@") }
        }
    }

    private static func returnToPage() {
        let js = "(function(){ var v = Array.from(document.querySelectorAll('video')).find(function(x){ return x.webkitPresentationMode === 'picture-in-picture' }); if (!v) return false; v.webkitSetPresentationMode('inline'); return true })()"
        for m in BrowserModel.windows {
            for t in m.allTabs where t.webView != nil {
                guard let wv = t.webView else { continue }
                let done: (Any?) -> Void = { r in
                    guard (r as? Bool) == true else { return }
                    if let sp = m.space(of: t), m.currentSpaceID != sp.id, let i = m.spaces.firstIndex(where: { $0 === sp }) { m.switchSpace(i) }
                    m.select(t)
                    NSApp.activate(ignoringOtherApps: true)
                    m.mainWindow?.makeKeyAndOrderFront(nil)
                }
                wv.evaluateJavaScript(js) { r, _ in done(r) }
                // Видео во встроенной рамке (плеер другого сайта)
                if let f = MediaFrames.shared.frame(for: wv) {
                    wv.evaluateJavaScript(js, in: f, in: .page) { if case .success(let r) = $0 { done(r) } }
                }
            }
        }
    }

    private static func scheduleFade(after delay: TimeInterval) {
        fadeWork?.cancel()
        let w = DispatchWorkItem { fade() }
        fadeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private static func fade() {
        guard let v = content, v.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            v.animator().alphaValue = 1
        }
    }
}
