import Foundation

/// Claude sekmelerinin disk kalıcılığı: proje başına monoton "Claude N" sayacı
/// ve kapatılmış-ama-sürdürülebilir sekmeler listesi. Açık sekmelerin gerçeği
/// tmux'tur; burada yalnız tmux'un hatırlayamadıkları tutulur.
/// Dosya: `claude-tabs.json` — `{ "<projectID>": { "counter": Int, "closed": [...] } }`.
@MainActor
final class ClaudeTabStore: ObservableObject {
    struct ClosedTab: Codable, Equatable, Identifiable {
        var id: Int { number }
        let number: Int
        var name: String?
        var claudeSID: String?
        var title: String?

        init(number: Int, name: String? = nil, claudeSID: String? = nil, title: String? = nil) {
            self.number = number
            self.name = name
            self.claudeSID = claudeSID
            self.title = title
        }

        enum CodingKeys: String, CodingKey { case number, name, claudeSID, title }
    }

    private struct Record: Codable {
        var counter: Int = 0
        var closed: [ClosedTab] = []
    }

    @Published private(set) var closed: [UUID: [ClosedTab]] = [:]

    private var records: [String: Record] = [:]

    init() {
        load()
    }

    /// Monoton sayaç — asla geri sarmaz, numaralar yeniden kullanılmaz.
    func nextNumber(for projectID: UUID) -> Int {
        var r = records[projectID.uuidString] ?? Record()
        r.counter += 1
        records[projectID.uuidString] = r
        save()
        return r.counter
    }

    /// Açılışta tmux'tan geri gelen sekmeler ileride çakışma yaratmasın diye.
    func bumpCounter(for projectID: UUID, atLeast n: Int) {
        var r = records[projectID.uuidString] ?? Record()
        guard r.counter < n else { return }
        r.counter = n
        records[projectID.uuidString] = r
        save()
    }

    func recordClosed(_ tab: ClosedTab, for projectID: UUID) {
        var r = records[projectID.uuidString] ?? Record()
        r.closed.removeAll { $0.number == tab.number }
        r.closed.insert(tab, at: 0)
        if r.closed.count > 30 { r.closed = Array(r.closed.prefix(30)) }
        records[projectID.uuidString] = r
        syncPublished()
        save()
    }

    func removeClosed(number: Int, for projectID: UUID) {
        guard var r = records[projectID.uuidString] else { return }
        r.closed.removeAll { $0.number == number }
        records[projectID.uuidString] = r
        syncPublished()
        save()
    }

    func clearClosed(for projectID: UUID) {
        guard var r = records[projectID.uuidString] else { return }
        r.closed.removeAll()
        records[projectID.uuidString] = r
        syncPublished()
        save()
    }

    // MARK: - IO

    private func syncPublished() {
        var result: [UUID: [ClosedTab]] = [:]
        for (key, record) in records {
            guard let id = UUID(uuidString: key), !record.closed.isEmpty else { continue }
            result[id] = record.closed
        }
        closed = result
    }

    private func load() {
        guard let data = try? Data(contentsOf: DeckPaths.claudeTabsFile),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else { return }
        records = decoded
        syncPublished()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        let dest = DeckPaths.claudeTabsFile
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let tmp = dest.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            NSLog("[ClaudeTabStore] save failed: %@", "\(error)")
        }
    }
}
