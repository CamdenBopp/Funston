import Foundation

enum MediaAvailability {
    static func hasSupportedMedia(_ detail: ArtifactDetail) -> Bool {
        guard detail.access == .available, !detail.summary.isAccessRestricted else { return false }
        if detail.summary.mediaType == .collection { return true }
        return detail.files.contains { file in
            guard !file.isPrivate else { return false }
            let suffix = (file.name as NSString).pathExtension.lowercased()
            switch detail.summary.mediaType {
            case .audio: return ["mp3", "m4a", "aac", "wav", "aiff", "aif"].contains(suffix)
            case .movies: return ["mp4", "m4v", "mov", "mkv"].contains(suffix)
            case .texts: return suffix == "pdf" || (suffix == "epub" && file.source?.lowercased() == "original")
            default: return false
            }
        }
    }

    /// Keep unknown items after a failed lookup; an outage is not evidence of absent media.
    static func filter(_ page: SearchPage, lookup: @escaping @Sendable (String) async throws -> ArtifactDetail) async -> (page: SearchPage, lookupFailed: Bool) {
        await withTaskGroup(of: (Int, Bool, Bool).self) { group in
            var next = 0
            var visible = Array(repeating: true, count: page.items.count)
            var lookupFailed = false
            func submit(_ index: Int) {
                let item = page.items[index]
                group.addTask {
                    if item.mediaType == .collection { return (index, true, false) }
                    do { return (index, hasSupportedMedia(try await lookup(item.identifier)), false) }
                    catch { return (index, true, true) }
                }
            }
            while next < min(4, page.items.count) { submit(next); next += 1 }
            while let (index, keep, failed) = await group.next() {
                visible[index] = keep; lookupFailed = lookupFailed || failed
                if next < page.items.count { submit(next); next += 1 }
            }
            let items = page.items.enumerated().compactMap { visible[$0.offset] ? $0.element : nil }
            return (SearchPage(items: items, total: page.total, page: page.page, pageSize: page.pageSize), lookupFailed)
        }
    }
}
