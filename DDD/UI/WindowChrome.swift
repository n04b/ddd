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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
