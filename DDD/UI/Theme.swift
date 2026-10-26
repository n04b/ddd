//
//  Theme.swift
//  Цвета и стеклянные панели по референсу: тёмное размытое стекло,
//  циан — выделение, оранжевый — отверстия, изумрудный — тела.
//

import SwiftUI

enum Theme {
    static let cyan = Color(red: 0.30, green: 0.84, blue: 0.98)
    static let orange = Color(red: 1.00, green: 0.72, blue: 0.42)
    static let emerald = Color(red: 0.31, green: 0.87, blue: 0.64)
    static let violet = Color(red: 0.72, green: 0.58, blue: 1.00)
    static let red = Color(red: 1.00, green: 0.47, blue: 0.44)
    static let axisX = Color(red: 1.00, green: 0.45, blue: 0.45)
    static let axisY = Color(red: 0.45, green: 0.90, blue: 0.55)
    static let axisZ = Color(red: 0.45, green: 0.65, blue: 1.00)

    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.34)
    static let hairline = Color.white.opacity(0.09)
    static let field = Color.black.opacity(0.28)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func label(_ size: CGFloat = 12, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

struct GlassPanel: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(Color.black.opacity(0.30), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

extension View {
    func glass(radius: CGFloat = 12) -> some View {
        modifier(GlassPanel(radius: radius))
    }
}

/// Подзаголовок секции: капс, разрядка, приглушённый цвет.
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Theme.tertiary)
    }
}

/// Кнопка-иконка с подсветкой при наведении.
struct HoverButtonStyle: ButtonStyle {
    var radius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration, radius: radius)
    }
}

private struct HoverButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let radius: CGFloat
    @State private var hovering = false

    init(configuration: ButtonStyleConfiguration, radius: CGFloat) {
        self.configuration = configuration
        self.radius = radius
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.08 : 0)))
            )
            .onHover { hovering = $0 }
    }
}

extension NodeKind {
    var symbol: String {
        switch self {
        case .box: return "cube"
        case .sphere: return "circle"
        case .cylinder: return "cylinder"
        case .group: return "square.stack.3d.up"
        }
    }

    var title: String {
        switch self {
        case .box: return "Box"
        case .sphere: return "Sphere"
        case .cylinder: return "Cylinder"
        case .group: return "Group"
        }
    }
}

extension Node {
    var tint: Color {
        if mode == .hole { return Theme.orange }
        if mode == .mask { return Theme.violet }
        return kind == .group ? Theme.cyan : Theme.emerald
    }
}
