//
//  Overlays.swift
//  Мелкие элементы поверх вьюпорта: виды камеры, статус, уведомления.
//

import SwiftUI

struct ViewPresetsView: View {
    let model: EditorModel

    init(model: EditorModel) {
        self.model = model
    }

    var body: some View {
        HStack(spacing: 0) {
            preset("ISO", .iso, "Isometric — 1")
            preset("TOP", .top, "Top — 2")
            preset("FRONT", .front, "Front — 3")
            preset("SIDE", .right, "Right — 4")
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 4)
            Button {
                model.frameSelection()
            } label: {
                Image(systemName: "viewfinder")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle())
            .help("Frame selection — F")
        }
        .font(Theme.mono(10, .medium))
        .foregroundStyle(Theme.secondary)
        .padding(4)
        .glass(radius: 16)
    }

    private func preset(_ title: String, _ value: ViewPreset, _ help: String) -> some View {
        Button {
            model.setView(value)
        } label: {
            Text(title)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
    }
}

struct StatusView: View {
    let model: EditorModel

    init(model: EditorModel) {
        self.model = model
    }

    var body: some View {
        HStack(spacing: 8) {
            if model.isComputing {
                ProgressView()
                    .controlSize(.mini)
                Text("computing")
            } else if model.output.isDraft {
                Text("draft")
            }
            Text("\(model.partTriangles) tris · \(Int(model.output.milliseconds.rounded())) ms")
        }
        .font(Theme.mono(10))
        .foregroundStyle(Theme.tertiary)
    }
}

struct ToastView: View {
    let model: EditorModel
    let toast: Toast

    init(model: EditorModel, toast: Toast) {
        self.model = model
        self.toast = toast
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text)
                .font(Theme.label(12))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            if toast.canUndo {
                Button("Undo") {
                    model.undo()
                    model.toast = nil
                }
                .buttonStyle(.plain)
                .font(Theme.label(12, .semibold))
                .foregroundStyle(Theme.cyan)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: 560)
        .glass(radius: 18)
    }
}
