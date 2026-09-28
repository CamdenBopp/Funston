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
        let directory = try applicationSupport(fileManager: fileManager)
            .appending(path: "Media", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        return directory
    }
}

