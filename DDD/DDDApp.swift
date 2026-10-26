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
                Menu("Fillet") {
                    RoundingMenuItems(model: model)
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
        }
    }
}
