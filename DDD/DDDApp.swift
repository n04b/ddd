//
//  DDDApp.swift
//  DDD
//
//  Created by Mikhail Rogalev on 26/10/2026.
//

import SwiftUI

@main
struct DDDApp: App {
    @State private var model = EditorModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { model.newProject() }
                    .keyboardShortcut("n")
                Button("Open…") { model.openProject() }
                    .keyboardShortcut("o")
                Divider()
                Button("Import Reference Image…") { model.importReferenceImages() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveProject() }
                    .keyboardShortcut("s")
                Button("Save As…") { model.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Export STL…") { model.exportSTL() }
                    .keyboardShortcut("e")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandMenu("Object") {
                Button("Box") { model.add(.box) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Sphere") { model.add(.sphere) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Cylinder") { model.add(.cylinder) }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Divider()
                Button("Group") { model.groupSelection() }
                    .keyboardShortcut("g")
                Button("Ungroup") { model.ungroupSelection() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Solid / Hole") { model.toggleHole() }
                    .keyboardShortcut("h", modifiers: [.command, .option])
                Button("Solid / Mask") { model.toggleMask() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Menu("Fillets") {
                    FilletPresetItems(model: model)
                }
                .disabled(model.roundableIDs.isEmpty)
                Divider()
                Button("Duplicate") { model.duplicateSelection() }
                    .keyboardShortcut("d")
                // Без сочетания в меню: ⌘⌫ нужен текстовым полям. Удаление — ⌫ во вьюпорте.
                Button("Delete") { model.deleteSelection() }
                Divider()
                Button("Frame Selection") { model.frameSelection() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
            }
            // Без однобуквенных сочетаний: P и R ловит вьюпорт, а в меню они мешали бы полям ввода.
            CommandMenu("Reference") {
                let reference = model.selectedReferenceImage
                Button("Import Image…") { model.importReferenceImages() }
                Divider()
                Button(model.referenceTool == .points ? "Stop Adding Points" : "Add Points") {
                    model.setReferenceTool(model.referenceTool == .points ? .none : .points)
                }
                .disabled(reference == nil)
                Button(model.referenceTool == .calibrate ? "Cancel Calibration" : "Calibrate Scale…") {
                    model.setReferenceTool(model.referenceTool == .calibrate ? .none : .calibrate)
                }
                .disabled(reference == nil)
                Button("Reset Scale to File DPI") {
                    if let id = reference?.id { model.resetReferenceScale(id) }
                }
                .disabled(reference == nil)
                Menu("Plane") {
                    ForEach(ReferencePlane.allCases, id: \.self) { plane in
                        Button(plane.title) {
                            if let id = reference?.id { model.setReferencePlane(id, plane) }
                        }
                    }
                }
                .disabled(reference == nil)
                Divider()
                Button(reference?.locked == true ? "Unlock" : "Lock") {
                    if let reference { model.setReferenceLocked(reference.id, !reference.locked) }
                }
                .disabled(reference == nil)
                Button(reference?.onTop == true ? "Draw Under the Model" : "Show Over the Model") {
                    if let reference { model.setReferenceOnTop(reference.id, !reference.onTop) }
                }
                .disabled(reference == nil)
            }
        }
    }
}
