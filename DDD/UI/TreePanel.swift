//
//  TreePanel.swift
//  Дерево объектов: выделение, переименование, видимость, перетаскивание в группы.
//

import SwiftUI
import AppKit

private struct TreeItem: Identifiable {
    let node: Node
    let depth: Int
    var id: UUID { node.id }
}

struct TreePanel: View {
    let model: EditorModel
    @State private var contentHeight: CGFloat = 120
    @State private var rootDropTargeted = false

    init(model: EditorModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if model.doc.nodes.isEmpty {
                        Text("Empty. B — box, S — sphere, C — cylinder")
                            .font(Theme.label(11))
                            .foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                    }
                    ForEach(items) { item in
                        TreeRow(model: model, node: item.node, depth: item.depth)
                    }
                    rootDropZone
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: contentHeight)
        }
        .frame(width: 264)
    }

    /// Бросить сюда — вынести объект на верхний уровень.
    private var rootDropZone: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(rootDropTargeted ? Theme.cyan.opacity(0.7) : Color.clear,
                          style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 18)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { values, _ in
                guard let value = values.first, let id = UUID(uuidString: value) else { return false }
                model.moveNode(id, toParent: nil, before: nil)
                return true
            } isTargeted: { targeted in
                rootDropTargeted = targeted
            }
    }

    private var items: [TreeItem] {
        var result: [TreeItem] = []
        func walk(_ nodes: [Node], depth: Int) {
            for node in nodes {
                result.append(TreeItem(node: node, depth: depth))
                if node.kind == .group, model.expanded.contains(node.id) {
                    walk(node.children, depth: depth + 1)
                }
            }
        }
        walk(model.doc.nodes, depth: 0)
        return result
    }
}

private struct TreeRow: View {
    let model: EditorModel
    let node: Node
    let depth: Int
    @State private var hovering = false
    @State private var dropTargeted = false

    init(model: EditorModel, node: Node, depth: Int) {
        self.model = model
        self.node = node
        self.depth = depth
    }

    var body: some View {
        let selected = model.selection.contains(node.id)
        let isGroup = node.kind == .group
        let isTopLevelHole = node.mode == .hole && depth == 0

        HStack(spacing: 6) {
            if isGroup {
                Button {
                    model.toggleExpanded(node.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .rotationEffect(.degrees(model.expanded.contains(node.id) ? 90 : 0))
                        .frame(width: 12, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 20)
            }

            Image(systemName: node.kind.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(node.tint)
                .frame(width: 14)

            if model.renamingID == node.id {
                RenameField(model: model, node: node)
            } else {
                Text(node.name)
                    .font(Theme.label(12, isGroup ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.cyan : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }

            Text(node.summary)
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)

            if isTopLevelHole {
                Text("no cut")
                    .font(Theme.label(9.5))
                    .foregroundStyle(Theme.orange.opacity(0.85))
                    .help("A hole only cuts inside a group. Group it with a solid.")
            }

            Spacer(minLength: 4)

            if hovering || !node.visible {
                Button {
                    model.setVisible(node.id, !node.visible)
                } label: {
                    Image(systemName: node.visible ? "eye" : "eye.slash")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(node.visible ? "Hide" : "Show")
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 4)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.cyan.opacity(0.14) : (hovering ? Color.white.opacity(0.05) : Color.clear))
        )
        .overlay {
            if dropTargeted && isGroup {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.cyan, lineWidth: 1)
            }
        }
        .overlay(alignment: .top) {
            if dropTargeted && !isGroup {
                Rectangle().fill(Theme.cyan).frame(height: 2)
            }
        }
        .opacity(node.visible ? 1 : 0.45)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                model.toggleSelection(node.id)
            } else {
                model.select(node.id)
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.renamingID = node.id
        })
        .draggable(node.id.uuidString)
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let id = UUID(uuidString: value), id != node.id else { return false }
            if isGroup {
                model.moveNode(id, toParent: node.id, before: nil)
            } else {
                model.moveNode(id, toParent: model.doc.parentID(of: node.id), before: node.id)
            }
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .contextMenu {
            Button("Rename") { model.renamingID = node.id }
            Button(node.mode == .hole ? "Make solid" : "Make hole") {
                model.setMode([node.id], node.mode == .hole ? .solid : .hole)
            }
            Divider()
            Button("Group selection") {
                if !model.selection.contains(node.id) { model.select(node.id) }
                model.groupSelection()
            }
            if isGroup {
                Button("Ungroup") {
                    model.select(node.id)
                    model.ungroupSelection()
                }
            }
            Button("Duplicate") {
                if !model.selection.contains(node.id) { model.select(node.id) }
                model.duplicateSelection()
            }
            Divider()
            Button("Delete") {
                if !model.selection.contains(node.id) { model.select(node.id) }
                model.deleteSelection()
            }
        }
    }
}

private struct RenameField: View {
    let model: EditorModel
    let node: Node
    @State private var text = ""
    @FocusState private var focused: Bool

    init(model: EditorModel, node: Node) {
        self.model = model
        self.node = node
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(Theme.label(12))
            .foregroundStyle(Theme.text)
            .focused($focused)
            .onAppear {
                text = node.name
                focused = true
            }
            .onSubmit(commit)
            .onExitCommand {
                model.renamingID = nil
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
    }

    private func commit() {
        guard model.renamingID == node.id else { return }
        model.rename(node.id, text)
        model.renamingID = nil
    }
}
