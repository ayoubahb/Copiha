import Foundation

struct ClipItem: Codable {
    var text: String
    var firstCopied: Date
    var lastCopied: Date
    var copyCount: Int
}

final class Store {
    static let shared = Store()

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Copiha", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {}

    func save(_ items: [ClipItem]) {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logError("Store: save error — \(error)")
        }
    }

    func load() -> [ClipItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            if let items = try? JSONDecoder().decode([ClipItem].self, from: data) {
                return items
            }
            // Migrate from old [String] format
            let strings = try JSONDecoder().decode([String].self, from: data)
            let now = Date()
            return strings.map { ClipItem(text: $0, firstCopied: now, lastCopied: now, copyCount: 1) }
        } catch {
            logError("Store: load error — \(error)")
            return []
        }
    }
}
