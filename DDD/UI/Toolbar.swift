//
//  Toolbar.swift
//  Плавающий тулбар сверху по центру.
//

import SwiftUI

struct ToolbarView: View {
    let model: EditorModel

    init(model: EditorModel) {
        self.model = model
    }

    var body: some View {
        let hasSelection = !model.selection.isEmpty
        let primary = model.primary

        HStack(spacing: 2) {
            tool("cube", "Box — B") { model.add(.box) }
            tool("circle", "Sphere — S") { model.add(.sphere) }
            tool("cylinder", "Cylinder — C") { model.add(.cylinder) }

            divider

            tool("square.on.square", "Group — G or ⌘G", enabled: hasSelection) {
                model.groupSelection()
            }
            tool("square.on.square.dashed", "Ungroup — ⇧⌘G", enabled: primary?.kind == .group) {
                model.ungroupSelection()
            }
            tool("circle.dashed", "Solid / hole — H",
                 tint: primary?.mode == .hole ? Theme.orange : nil,
                 enabled: hasSelection) {
                model.toggleHole()
            }
            tool("circle.dashed.inset.filled", "Solid / mask — M",
                 tint: primary?.mode == .mask ? Theme.violet : nil,
                 enabled: hasSelection) {
                model.toggleMask()
            }

            divider

            tool("plus.square.on.square", "Duplicate — ⌘D", enabled: hasSelection) {
                model.duplicateSelection()
            }
            tool("trash", "Delete — ⌫", enabled: hasSelection) {
                model.deleteSelection()
            }

            divider

            tool("arrow.uturn.backward", "Undo — ⌘Z", enabled: model.canUndo) { model.undo() }
            tool("arrow.uturn.forward", "Redo — ⇧⌘Z", enabled: model.canRedo) { model.redo() }

            divider

            Button {
                model.exportSTL()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                    Text("STL")
                        .font(Theme.mono(11, .semibold))
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Color.black.opacity(0.15)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Export parts to STL — ⌘E")
            .padding(.leading, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // .glass(radius: 22)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 5)
    }

    private func tool(_ symbol: String, _ help: String, tint: Color? = nil, enabled: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint ?? Theme.text)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}
