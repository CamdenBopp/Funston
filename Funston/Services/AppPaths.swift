import Foundation

enum AppPaths {
    static func applicationSupport(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appending(path: "Funston", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func database(fileManager: FileManager = .default) throws -> URL {
        try applicationSupport(fileManager: fileManager).appending(path: "funston.sqlite3")
    }

    static func media(fileManager: FileManager = .default) throws -> URL {
        let documents = try fileManager.url(for: .documentDirectory, in: .userDomainMask,
                                            appropriateFor: nil, create: true)
        let directory = documents.appending(path: "Media", directoryHint: .isDirectory)
        let legacy = try applicationSupport(fileManager: fileManager)
            .appending(path: "Media", directoryHint: .isDirectory)
        try migrateMedia(from: legacy, to: directory, fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        return directory
    }
    static func migrateMedia(from legacy: URL, to directory: URL, fileManager: FileManager = .default) throws {
        // Move rather than copy: saved basenames and in-flight attempt identities
        // remain valid, and large downloads never occupy twice their disk space.
        if fileManager.fileExists(atPath: legacy.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for source in try fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                if !fileManager.fileExists(atPath: destination.path) {
                    try fileManager.moveItem(at: source, to: destination)
                }
            }
        }
    }

}

