//
//  Persistence.swift
//  Автосохранение в контейнер приложения: работа не теряется, а диалог
//  «Сохранить изменения?» не нужен.
//

import Foundation

enum Persistence {
    static var autosaveURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("3d", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("autosave.json")
    }

    static func loadAutosave() -> SceneDocument? {
        guard let data = try? Data(contentsOf: autosaveURL) else { return nil }
        return try? JSONDecoder().decode(SceneDocument.self, from: data)
    }

    static func save(_ document: SceneDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}
