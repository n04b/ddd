//
//  WindowChrome.swift
//  Полупрозрачное тёмное окно с размытием того, что под ним.
//

import SwiftUI
import AppKit

/// Размытие рабочего стола за окном. При «Уменьшить прозрачность»
/// в настройках системы AppKit сам делает его непрозрачным.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Делает окно прозрачным, чтобы через вьюпорт был виден размытый фон.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ConfiguringView()
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ConfiguringView: NSView {
        private var lightsTracking: NSTrackingArea?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            hideTrafficLights(in: window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // MARK: Светофор — виден только под курсором

        private func trafficLights(in window: NSWindow) -> [NSButton] {
            [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        }

        private func hideTrafficLights(in window: NSWindow) {
            let buttons = trafficLights(in: window)
            guard lightsTracking == nil, let container = buttons.first?.superview else { return }
            buttons.forEach { $0.alphaValue = 0 }
            // Зона чуть шире самих кнопок, чтобы они проявлялись на подходе.
            let zone = buttons.map(\.frame).reduce(buttons[0].frame) { $0.union($1) }.insetBy(dx: -10, dy: -8)
            let tracking = NSTrackingArea(rect: zone, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
            container.addTrackingArea(tracking)
            lightsTracking = tracking
        }

        override func mouseEntered(with event: NSEvent) {
            fadeTrafficLights(to: 1)
        }

        override func mouseExited(with event: NSEvent) {
            fadeTrafficLights(to: 0)
        }

        private func fadeTrafficLights(to alpha: CGFloat) {
            guard let window else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                trafficLights(in: window).forEach { $0.animator().alphaValue = alpha }
            }
        }
    }
}
