//
//  ReferenceInspector.swift
//  Свойства референс-изображения: плоскость, масштаб (DPI, размер, калибровка
//  по двум точкам), точки разметки с мировыми координатами, место и вид.
//

import SwiftUI
import AppKit

struct ReferenceInspector: View {
    let model: EditorModel
    let reference: ReferenceImage
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    init(model: EditorModel, reference: ReferenceImage) {
        self.model = model
        self.reference = reference
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            PlaneSwitch(plane: reference.plane) { plane in
                model.setReferencePlane(reference.id, plane)
            }
            scaleSection
            pointsSection
            placementSection
            appearanceSection
            actions
        }
        .onAppear { name = reference.name }
        .onChange(of: reference.name) { _, newName in name = newName }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.sand)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.label(13, .semibold))
                    .foregroundStyle(Theme.text)
                    .focused($nameFocused)
                    .onSubmit { model.renameReference(reference.id, name) }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { model.renameReference(reference.id, name) }
                    }
                Text("Reference · \(reference.pixelWidth) × \(reference.pixelHeight) px")
                    .font(Theme.label(10))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    // MARK: Масштаб

    private var scaleSection: some View {
        let id = reference.id
        let calibrating = model.referenceTool == .calibrate
        return section("SCALE") {
            NumberField(label: "DPI", labelColor: Theme.secondary, labelWidth: 26, value: reference.dpi, unit: "",
                        dragStep: 0.5, keyStep: 1, minimum: 0.01,
                        onChange: { model.setReferenceDPI(id, $0) }, onFinish: { model.breakCoalescing() })
            NumberField(label: "W", labelColor: Theme.secondary, labelWidth: 26, value: reference.width, unit: "mm",
                        dragStep: 0.5, keyStep: 1, minimum: 0.01,
                        onChange: { model.setReferenceWidth(id, $0) }, onFinish: { model.breakCoalescing() })
            NumberField(label: "H", labelColor: Theme.secondary, labelWidth: 26, value: reference.height, unit: "mm",
                        dragStep: 0.5, keyStep: 1, minimum: 0.01,
                        onChange: { model.setReferenceHeight(id, $0) }, onFinish: { model.breakCoalescing() })

            HStack(spacing: 6) {
                Text("File: \(Fmt.number(reference.fileDPI)) dpi · 1 px = \(String(format: "%.3f", reference.mmPerPixel)) mm")
                    .font(Theme.label(10.5))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if abs(reference.dpi - reference.fileDPI) > 1e-6 {
                    Button("Reset") { model.resetReferenceScale(id) }
                        .buttonStyle(.plain)
                        .font(Theme.label(11, .medium))
                        .foregroundStyle(Theme.secondary)
                        .help("Back to the DPI stored in the file")
                }
            }

            wideButton(symbol: "ruler", title: calibrating ? "Calibrating…" : "Calibrate by two points",
                       trailing: calibrating ? "Cancel" : "R", active: calibrating) {
                model.setReferenceTool(calibrating ? .none : .calibrate)
            }
            .help("Click both ends of a distance you know on the image, then type it in mm. R")
        }
    }

    // MARK: Точки разметки

    private var pointsSection: some View {
        let placing = model.referenceTool == .points
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                SectionTitle(text: reference.markers.isEmpty ? "POINTS" : "POINTS · \(reference.markers.count)")
                Spacer()
                Button {
                    model.setReferenceTool(placing ? .none : .points)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: placing ? "checkmark" : "plus")
                            .font(.system(size: 9, weight: .bold))
                        Text(placing ? "Done" : "Add")
                            .font(Theme.label(11, .medium))
                    }
                    .foregroundStyle(placing ? Theme.cyan : Theme.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(placing ? Theme.cyan.opacity(0.14) : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(placing ? "Stop placing points — Esc" : "Click the image to place points — P")
            }

            if reference.markers.isEmpty {
                Text("Mark key spots — corners, hole centers. Their coordinates help place the model. Press P, then click the image.")
                    .font(Theme.label(10.5))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 1) {
                    ForEach(reference.markers) { marker in
                        MarkerRow(model: model, reference: reference, marker: marker)
                    }
                }
            }

            if let measure = model.selectedMarkerDistance {
                let id = reference.id
                NumberField(label: "\(measure.from.label)–\(measure.to.label)", labelColor: Theme.cyan, labelWidth: 34,
                            value: measure.millimeters, unit: "mm", dragStep: 0.1, keyStep: 1, minimum: 0.01,
                            onChange: { model.calibrate(id, from: measure.from.point, to: measure.to.point, distance: $0, coalesce: true) },
                            onFinish: { model.breakCoalescing() })
                Text("Distance between the two selected points. Type the real one to scale the image.")
                    .font(Theme.label(10.5))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Место

    private var placementSection: some View {
        let id = reference.id
        return VStack(alignment: .leading, spacing: 14) {
            section("CENTER") {
                axisField("X", Theme.axisX, reference.center.x) { model.setReferenceCenter(id, axis: 0, $0) }
                axisField("Y", Theme.axisY, reference.center.y) { model.setReferenceCenter(id, axis: 1, $0) }
                axisField("Z", Theme.axisZ, reference.center.z) { model.setReferenceCenter(id, axis: 2, $0) }
            }
            section("ROTATION") {
                HStack(spacing: 2) {
                    NumberField(label: "∠", labelColor: Theme.secondary, value: reference.angle, unit: "°",
                                dragStep: 0.5, keyStep: 15, minimum: nil,
                                onChange: { model.setReferenceAngle(id, $0) }, onFinish: { model.breakCoalescing() })
                    iconButton("rotate.left", "Rotate 90° counterclockwise") { model.rotateReference(id, by: 90) }
                    iconButton("rotate.right", "Rotate 90° clockwise") { model.rotateReference(id, by: -90) }
                    iconButton("flip.horizontal", "Mirror left to right", active: reference.flipped) { model.flipReference(id) }
                }
            }
        }
    }

    // MARK: Вид

    private var appearanceSection: some View {
        let id = reference.id
        return section("APPEARANCE") {
            NumberField(label: "◐", labelColor: Theme.secondary, value: reference.opacity * 100, unit: "%",
                        dragStep: 1, keyStep: 10, minimum: 0,
                        onChange: { model.setReferenceOpacity(id, percent: $0) }, onFinish: { model.breakCoalescing() })
            toggleRow("Show over the model", isOn: reference.onTop,
                      help: "Draw the image on top of the bodies, so its outline shows through them") {
                model.setReferenceOnTop(id, $0)
            }
            toggleRow("Lock in the viewport", isOn: reference.locked,
                      help: "Dragging the image orbits the camera instead of moving it") {
                model.setReferenceLocked(id, $0)
            }
        }
    }

    private var actions: some View {
        let id = reference.id
        return HStack(spacing: 4) {
            iconButton("viewfinder", "Frame the image — F") { model.frameReference(id) }
            iconButton("plus.square.on.square", "Duplicate — ⌘D") { model.duplicateReference(id) }
            iconButton("eye.slash", "Hide") { model.setReferenceVisible(id, false) }
            Spacer()
            Button {
                model.deleteReference(id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle())
            .help("Delete the image")
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
        NumberField(label: label, labelColor: color, value: value, unit: "mm",
                    dragStep: 0.1, keyStep: 1, minimum: nil,
                    onChange: onChange, onFinish: { model.breakCoalescing() })
    }

    private func iconButton(_ symbol: String, _ help: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(active ? Theme.cyan : Theme.secondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
    }

    private func wideButton(symbol: String, title: String, trailing: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(active ? Theme.cyan : Theme.secondary)
                Text(title)
                    .font(Theme.label(11.5, .medium))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                Text(trailing)
                    .font(active ? Theme.label(11.5, .medium) : Theme.mono(10.5))
                    .foregroundStyle(active ? Theme.cyan : Theme.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? Theme.cyan.opacity(0.14) : Theme.field))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(active ? Theme.cyan.opacity(0.85) : Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(_ title: String, isOn: Bool, help: String, onChange: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(title)
                .font(Theme.label(11.5))
                .foregroundStyle(Theme.secondary)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: onChange))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .help(help)
    }
}

/// Строка точки разметки: метка (правится на месте), мировые координаты по осям плоскости,
/// «в начало координат» и удаление.
private struct MarkerRow: View {
    let model: EditorModel
    let reference: ReferenceImage
    let marker: ReferenceMarker
    @State private var hovering = false
    @State private var label = ""
    @FocusState private var focused: Bool

    init(model: EditorModel, reference: ReferenceImage, marker: ReferenceMarker) {
        self.model = model
        self.reference = reference
        self.marker = marker
    }

    var body: some View {
        let selected = model.markerSelection.contains(marker.id)
        let world = reference.world(marker.point)
        let (first, second) = reference.plane.inPlaneAxes

        HStack(spacing: 6) {
            Circle()
                .strokeBorder(selected ? Theme.cyan : Theme.secondary, lineWidth: 1.5)
                .frame(width: 9, height: 9)
            TextField("", text: $label)
                .textFieldStyle(.plain)
                .font(Theme.label(11.5, .semibold))
                .foregroundStyle(selected ? Theme.cyan : Theme.text)
                .frame(width: 28)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
            coordinate(first, world[first])
            coordinate(second, world[second])
            Spacer(minLength: 2)
            if hovering || selected {
                rowButton("scope", "Move the image so this point is at the origin") {
                    model.moveReferenceOrigin(to: marker.id, in: reference.id)
                }
                rowButton("xmark", "Delete the point") {
                    model.deleteMarkers([marker.id], in: reference.id)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? Theme.cyan.opacity(0.14) : (hovering ? Color.white.opacity(0.05) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            model.selectMarker(marker.id, extend: flags.contains(.command) || flags.contains(.shift))
        }
        .onAppear { label = marker.label }
        .onChange(of: marker.label) { _, newLabel in label = newLabel }
    }

    private func coordinate(_ axis: Int, _ value: Double) -> some View {
        let names = ["X", "Y", "Z"]
        let colors = [Theme.axisX, Theme.axisY, Theme.axisZ]
        return HStack(spacing: 3) {
            Text(names[axis])
                .font(Theme.label(9.5, .semibold))
                .foregroundStyle(colors[axis])
            Text(Fmt.number(value))
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
    }

    private func rowButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func commit() {
        guard label != marker.label else { return }
        model.renameMarker(marker.id, in: reference.id, label)
    }
}

/// Плоскость картинки: сверху, спереди или справа — как виды 2, 3 и 4.
struct PlaneSwitch: View {
    let plane: ReferencePlane
    let onChange: (ReferencePlane) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(.top, "Lies on the bed, seen from above (view 2)")
            segment(.front, "Stands on the bed facing the front view (view 3)")
            segment(.right, "Stands on the bed facing the right view (view 4)")
        }
        .padding(2)
        .background(Capsule().fill(Theme.field))
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func segment(_ value: ReferencePlane, _ help: String) -> some View {
        let active = plane == value
        return Button {
            onChange(value)
        } label: {
            Text(value.title)
                .font(Theme.label(11.5, .medium))
                .foregroundStyle(active ? Theme.sand : Theme.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(Capsule().fill(active ? Theme.sand.opacity(0.16) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
