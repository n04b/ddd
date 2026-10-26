//
//  InspectorPanel.swift
//  Свойства выделенного: правка сразу, без диалогов и кнопок OK.
//  Подпись поля тянется мышью (⇧ — ×10, ⌥ — ×0.1), значение вводится с клавиатуры,
//  принимаются выражения: 20+5, 60/2-1,5. Стрелки ↑↓ меняют на шаг.
//

import SwiftUI
import AppKit

struct InspectorPanel: View {
    let model: EditorModel

    init(model: EditorModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.selection.count > 1 {
                MultiSelectionInspector(model: model)
            } else if let node = model.primary {
                NodeInspector(model: model, node: node)
                    .id(node.id)
            }
        }
        .padding(12)
        .frame(width: 252, alignment: .leading)
        .glass()
    }
}

private struct MultiSelectionInspector: View {
    let model: EditorModel

    var body: some View {
        let nodes = model.selection.compactMap { model.doc.node($0) }
        let allHoles = nodes.allSatisfy { $0.mode == .hole }

        VStack(alignment: .leading, spacing: 12) {
            Text("Выделено: \(nodes.count)")
                .font(Theme.label(13, .semibold))
                .foregroundStyle(Theme.text)
            ModeSwitch(mode: allHoles ? .hole : .solid) { mode in
                model.setMode(model.selection, mode)
            }
            Button {
                model.groupSelection()
            } label: {
                Label("Сгруппировать", systemImage: "square.on.square")
                    .font(Theme.label(12, .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .foregroundStyle(Theme.cyan)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.cyan.opacity(0.14)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("Тела объединяются, отверстия вырезаются из тел своей группы.")
                .font(Theme.label(10.5))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct NodeInspector: View {
    let model: EditorModel
    let node: Node
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    init(model: EditorModel, node: Node) {
        self.model = model
        self.node = node
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ModeSwitch(mode: node.mode) { mode in
                model.setMode([node.id], mode)
            }

            if node.mode == .hole && model.isTopLevel(node.id) {
                Text("Отверстие режет только внутри группы. Выделите его вместе с телом (⌘-клик) и нажмите ⌘G.")
                    .font(Theme.label(10.5))
                    .foregroundStyle(Theme.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("ПОЛОЖЕНИЕ") {
                axisField("X", Theme.axisX, node.position.x) { model.setPosition(node.id, axis: 0, $0) }
                axisField("Y", Theme.axisY, node.position.y) { model.setPosition(node.id, axis: 1, $0) }
                axisField("Z", Theme.axisZ, node.position.z) { model.setPosition(node.id, axis: 2, $0) }
            }

            section("ПОВОРОТ") {
                angleField("X", Theme.axisX, node.rotation.x) { model.setRotation(node.id, axis: 0, $0) }
                angleField("Y", Theme.axisY, node.rotation.y) { model.setRotation(node.id, axis: 1, $0) }
                angleField("Z", Theme.axisZ, node.rotation.z) { model.setRotation(node.id, axis: 2, $0) }
            }

            sizeSection

            if node.kind == .box {
                roundingSection
            }

            actions
        }
        .onAppear { name = node.name }
        .onChange(of: node.name) { _, newName in name = newName }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: node.kind.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(node.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Имя", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.label(13, .semibold))
                    .foregroundStyle(Theme.text)
                    .focused($nameFocused)
                    .onSubmit { model.rename(node.id, name) }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { model.rename(node.id, name) }
                    }
                Text(node.kind.title)
                    .font(Theme.label(10))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    @ViewBuilder
    private var sizeSection: some View {
        let bounds = model.bounds(of: node.id)
        switch node.kind {
        case .box:
            section("РАЗМЕРЫ") {
                sizeField("Ш", 0, node.size.x)
                sizeField("Г", 1, node.size.y)
                sizeField("В", 2, node.size.z)
            }
        case .sphere:
            section("РАЗМЕРЫ") {
                sizeField("Ø", 0, node.size.x)
            }
        case .cylinder:
            section("РАЗМЕРЫ") {
                sizeField("Ø", 0, node.size.x)
                sizeField("В", 2, node.size.z)
            }
        case .group:
            section("ГАБАРИТЫ") {
                if let size = bounds?.size {
                    Text("\(Fmt.number(size.x)) × \(Fmt.number(size.y)) × \(Fmt.number(size.z)) мм")
                        .font(Theme.mono(11, .medium))
                        .foregroundStyle(Theme.text)
                } else {
                    Text("—").foregroundStyle(Theme.tertiary)
                }
                let solids = node.children.filter { $0.mode == .solid }.count
                Text("Тел: \(solids) · отверстий: \(node.children.count - solids)")
                    .font(Theme.label(10.5))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var roundingSection: some View {
        let id = node.id
        let rounding = node.rounding ?? BoxRounding()
        return section("СКРУГЛЕНИЕ") {
            HStack(spacing: 6) {
                NumberField(label: "R", labelColor: Theme.secondary, value: model.roundingRadius(of: node), unit: "мм",
                            dragStep: 0.1, keyStep: 0.5, minimum: 0.1,
                            onChange: { model.setRoundingRadius(id, $0) },
                            onFinish: { model.breakCoalescing() })
                Menu {
                    RoundingMenuItems(model: model)
                } label: {
                    HStack(spacing: 4) {
                        Text("Скруглить")
                            .font(Theme.label(11.5, .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Theme.cyan)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.cyan.opacity(0.14)))
            }
            Text(rounding.isEmpty
                 ? "Рёбра острые"
                 : "Рёбер: \(rounding.roundedEdgeCount) из 12 · вершин: \(rounding.roundedVertexCount) из 8")
                .font(Theme.label(10.5))
                .foregroundStyle(Theme.tertiary)
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if node.kind == .group {
                actionButton("square.on.square.dashed", "Разгруппировать") { model.ungroupSelection() }
            } else {
                actionButton("square.on.square", "Сгруппировать") { model.groupSelection() }
            }
            actionButton("plus.square.on.square", "Дублировать") { model.duplicateSelection() }
            actionButton("eye.slash", "Скрыть") { model.setVisible(node.id, false) }
            Spacer()
            Button {
                model.deleteSelection()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle())
            .help("Удалить")
        }
    }

    // MARK: Конструкторы

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionTitle(text: title)
            content()
        }
    }

    private func axisField(_ label: String, _ color: Color, _ value: Double,
                           _ onChange: @escaping (Double) -> Void) -> some View {
        NumberField(label: label, labelColor: color, value: value, unit: "мм",
                    dragStep: 0.1, keyStep: 1, minimum: nil,
                    onChange: onChange, onFinish: { model.breakCoalescing() })
    }

    private func angleField(_ label: String, _ color: Color, _ value: Double,
                            _ onChange: @escaping (Double) -> Void) -> some View {
        NumberField(label: label, labelColor: color, value: value, unit: "°",
                    dragStep: 0.5, keyStep: 15, minimum: nil,
                    onChange: onChange, onFinish: { model.breakCoalescing() })
    }

    private func sizeField(_ label: String, _ axis: Int, _ value: Double) -> some View {
        let id = node.id
        return NumberField(label: label, labelColor: Theme.secondary, value: value, unit: "мм",
                           dragStep: 0.1, keyStep: 1, minimum: 0.01,
                           onChange: { model.setSize(id, axis: axis, $0) },
                           onFinish: { model.breakCoalescing() })
    }

    private func actionButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
    }
}

/// Пункты скругления блока: общие для инспектора и меню «Объект».
struct RoundingMenuItems: View {
    let model: EditorModel

    init(model: EditorModel) {
        self.model = model
    }

    var body: some View {
        Button("Все рёбра и вершины") { model.roundAll(vertices: true) }
        Button("Все рёбра, вершины острые") { model.roundAll(vertices: false) }
        Divider()
        Menu("Рёбра") {
            edgeSection("Вдоль X", axis: 0)
            edgeSection("Вдоль Y", axis: 1)
            edgeSection("Вертикальные", axis: 2)
        }
        Menu("Вершины") {
            ForEach(0..<8, id: \.self) { v in
                Toggle(BoxRounding.vertexName(v), isOn: Binding(
                    get: { model.isVertexRounded(v) },
                    set: { model.setVertex(v, $0) }
                ))
            }
        }
        Divider()
        Button("Убрать скругление") { model.clearRounding() }
            .disabled(!model.hasRounding)
    }

    private func edgeSection(_ title: String, axis: Int) -> some View {
        Section(title) {
            ForEach(axis * 4..<axis * 4 + 4, id: \.self) { e in
                Toggle(BoxRounding.edgeName(e), isOn: Binding(
                    get: { model.isEdgeRounded(e) },
                    set: { model.setEdge(e, $0) }
                ))
            }
        }
    }
}

/// Переключатель «Тело / Отверстие».
struct ModeSwitch: View {
    let mode: NodeMode
    let onChange: (NodeMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment("Тело", .solid, Theme.emerald)
            segment("Отверстие", .hole, Theme.orange)
        }
        .padding(2)
        .background(Capsule().fill(Theme.field))
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func segment(_ title: String, _ value: NodeMode, _ color: Color) -> some View {
        let active = mode == value
        return Button {
            onChange(value)
        } label: {
            Text(title)
                .font(Theme.label(11.5, .medium))
                .foregroundStyle(active ? color : Theme.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(Capsule().fill(active ? color.opacity(0.16) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Числовое поле: тянуть подпись — менять значение, ввод с клавиатуры, выражения.
struct NumberField: View {
    let label: String
    let labelColor: Color
    let value: Double
    let unit: String
    let dragStep: Double
    let keyStep: Double
    let minimum: Double?
    let onChange: (Double) -> Void
    let onFinish: () -> Void

    @State private var text = ""
    @State private var invalid = false
    @State private var dragStart: Double?
    @FocusState private var focused: Bool

    init(label: String, labelColor: Color, value: Double, unit: String,
         dragStep: Double, keyStep: Double, minimum: Double?,
         onChange: @escaping (Double) -> Void, onFinish: @escaping () -> Void) {
        self.label = label
        self.labelColor = labelColor
        self.value = value
        self.unit = unit
        self.dragStep = dragStep
        self.keyStep = keyStep
        self.minimum = minimum
        self.onChange = onChange
        self.onFinish = onFinish
    }

    var body: some View {
        let active = focused || dragStart != nil

        HStack(spacing: 6) {
            Text(label)
                .font(Theme.label(10.5, .semibold))
                .foregroundStyle(labelColor)
                .frame(width: 16, height: 24, alignment: .leading)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(scrub)
                .help("Тяните влево-вправо. ⇧ — быстрее, ⌥ — точнее")

            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.mono(11.5, .medium))
                .foregroundStyle(invalid ? Theme.red : Theme.text)
                .focused($focused)
                .onSubmit(commit)
                .onKeyPress(.upArrow) {
                    bump(1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    bump(-1)
                    return .handled
                }

            Text(unit)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(active ? Theme.cyan.opacity(0.85) : Theme.hairline, lineWidth: 1)
        )
        .onAppear { text = Fmt.number(value) }
        .onChange(of: value) { _, newValue in
            if !focused { text = Fmt.number(newValue) }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if dragStart == nil { dragStart = value }
                let step = dragStep * modifierMultiplier()
                var next = (dragStart ?? value) + Double(gesture.translation.width) * step
                next = (next / step).rounded() * step
                if let minimum { next = max(minimum, next) }
                onChange(next)
            }
            .onEnded { _ in
                dragStart = nil
                onFinish()
            }
    }

    private func modifierMultiplier() -> Double {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) { return 10 }
        if flags.contains(.option) { return 0.1 }
        return 1
    }

    private func commit() {
        guard let parsed = ExpressionEvaluator.evaluate(text) else {
            invalid = true
            text = Fmt.number(value)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                invalid = false
            }
            return
        }
        invalid = false
        var next = parsed
        if let minimum { next = max(minimum, next) }
        if abs(next - value) > 1e-9 { onChange(next) }
        text = Fmt.number(next)
        onFinish()
    }

    private func bump(_ direction: Double) {
        let base = ExpressionEvaluator.evaluate(text) ?? value
        var next = base + direction * keyStep * modifierMultiplier()
        if let minimum { next = max(minimum, next) }
        onChange(next)
        text = Fmt.number(next)
        onFinish()
    }
}
