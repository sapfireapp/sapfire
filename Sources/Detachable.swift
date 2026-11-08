import AppKit
import SwiftUI

// MARK: - Попап, который можно оторвать

/// Попап у значка, который можно оттянуть в сторону (как попап в Safari) или закрепить точкой в углу —
/// тогда он становится маленькой плавающей панелью и не закрывается от кликов мимо.
/// Точка в углу — как у командной строки: пустая — обычный попап, залитая — закреплён (клик — закрыть панель).
struct DetachablePopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ v: NSView, context: Context) {
        let c = context.coordinator
        let binding = $isPresented
        c.onClose = { if binding.wrappedValue { binding.wrappedValue = false } }
        c.make = { pinned, toggle in
            AnyView(content()
                .overlay(alignment: .topTrailing) {
                    PinDot(on: pinned, action: toggle).padding(4)
                })
        }
        // Попап, который закрылся мимо делегата (оторвали, окно ушло) — забыть, иначе он больше не откроется
        if let p = c.popover, !p.isShown { c.popover = nil }
        if isPresented, c.popover == nil, !c.pending {
            c.pending = true
            c.tryShow(from: v, attempts: 10)
        } else if !isPresented, c.popover != nil {
            c.popover?.close()
        }
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var panel: NSPanel?
        var pending = false
        var onClose: () -> Void = {}
        var make: (Bool, @escaping () -> Void) -> AnyView = { _, _ in AnyView(EmptyView()) }

        /// Значок мог ещё не попасть в окно (панель только выезжает) — подождать немного; не вышло — сбросить
        /// запрос, чтобы следующий клик снова открыл попап
        func tryShow(from v: NSView, attempts: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempts == 10 ? 0.08 : 0.05)) { [weak self, weak v] in
                guard let self else { return }
                guard self.popover == nil else { self.pending = false; return }
                guard let v, v.window != nil, !v.isHiddenOrHasHiddenAncestor else {
                    if attempts > 0, let v { self.tryShow(from: v, attempts: attempts - 1) } else { self.pending = false; self.onClose() }
                    return
                }
                self.pending = false
                self.show(from: v)
            }
        }

        func show(from v: NSView) {
            // Уже закреплён — просто показать панель
            if let p = panel { p.makeKeyAndOrderFront(nil); onClose(); return }
            let p = NSPopover()
            p.behavior = .transient
            p.animates = true
            p.delegate = self
            p.contentViewController = NSHostingController(rootView: make(false) { [weak self] in self?.pin() })
            popover = p
            p.show(relativeTo: v.bounds, of: v, preferredEdge: .minY)
        }

        /// Точка: попап → плавающая панель на том же месте
        func pin() {
            guard let p = popover, let v = p.contentViewController?.view, let w = v.window else { return }
            // Место самого содержимого на экране (окно попапа больше — в нём ещё стрелка и поля)
            let frame = w.convertToScreen(v.convert(v.bounds, to: nil))
            let panel = makePanel()
            panel.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.maxY))
            panel.makeKeyAndOrderFront(nil)
            p.close()
        }

        private func makePanel() -> NSPanel {
            panel?.close()
            // Полупрозрачная, как выпадающее меню: размытый рабочий стол / окно под панелью
            let root = make(true) { [weak self] in self?.panel?.close() }
                .background(WindowDragArea())     // тянуть — за любое пустое место
                .background(MenuBackdrop(material: .menu))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .circular))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .circular).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            let hc = NSHostingController(rootView: root)
            // Размер — один раз по содержимому. Если окно подгоняется под содержимое на лету,
            // окно и содержимое бесконечно подстраиваются друг под друга — программа падала
            hc.sizingOptions = []
            let size = hc.view.fittingSize
            let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = true
            p.isReleasedWhenClosed = false
            p.contentViewController = hc
            p.setContentSize(size)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
                if self?.panel === p { self?.panel = nil }
            }
            panel = p
            return p
        }

        // Оттянул попап мышью — он превращается в ту же панель
        func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }
        func detachableWindow(for popover: NSPopover) -> NSWindow? { makePanel() }

        func popoverDidDetach(_ popover: NSPopover) {
            self.popover = nil
            onClose()
        }

        func popoverDidClose(_ n: Notification) {
            popover = nil
            onClose()
        }
    }
}

/// Панель без рамки, которая всё же принимает клики и клавиши
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Системное размытие (как у меню и попапов) — под SwiftUI-содержимым
struct MenuBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    /// .behindWindow — то, что за окном; .withinWindow — содержимое самого окна под видом (страница)
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material; v.blendingMode = blending }
}
