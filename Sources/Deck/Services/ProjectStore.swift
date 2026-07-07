import Foundation
import CoreGraphics

/// Projelerin disk kalıcılığı: `~/Library/Application Support/Deck/projects.json`.
/// Şema: `{"version": 1, "projects": [...]}`.
@MainActor
final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = []

    private struct FileFormat: Codable {
        var version: Int = 1
        var projects: [Project] = []
    }

    /// moveItem sırasında sürükleme her karede save tetiklemesin diye debounce.
    private var pendingSave: Task<Void, Never>?
    private static let ioQueue = DispatchQueue(label: "deck.projectstore.io", qos: .utility)

    init() {
        load()
    }

    func project(_ id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    @discardableResult
    func addProject(name: String, path: String) -> Project {
        var project = Project(name: name, path: path)
        var claude = CanvasItem(kind: .claude, name: "Claude", icon: .claude)
        claude.x = 60
        claude.y = 60
        project.items.append(claude)
        projects.append(project)
        save()
        return project
    }

    func updateProject(_ p: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == p.id }) else { return }
        projects[idx] = p
        save()
    }

    func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        save()
    }

    func upsertItem(_ item: CanvasItem, in projectID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
        if let ii = projects[pi].items.firstIndex(where: { $0.id == item.id }) {
            projects[pi].items[ii] = item
        } else {
            projects[pi].items.append(item)
        }
        save()
    }

    func removeItem(_ itemID: UUID, from projectID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[pi].items.removeAll { $0.id == itemID }
        save()
    }

    func moveItem(_ itemID: UUID, in projectID: UUID, to point: CGPoint) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let ii = projects[pi].items.firstIndex(where: { $0.id == itemID }) else { return }
        projects[pi].items[ii].x = Double(point.x)
        projects[pi].items[ii].y = Double(point.y)
        scheduleSave()
    }

    /// Anında atomik yazım (tmp + move). addProject/deleteProject buradan geçer.
    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        writeToDisk()
    }

    // MARK: - IO

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: DeckPaths.projectsFile),
              let decoded = try? JSONDecoder().decode(FileFormat.self, from: data) else { return }
        projects = decoded.projects
    }

    private func writeToDisk() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(FileFormat(version: 1, projects: projects)) else {
            NSLog("[ProjectStore] encode failed")
            return
        }
        let dest = DeckPaths.projectsFile
        Self.ioQueue.async {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                let tmp = dest.appendingPathExtension("tmp")
                try data.write(to: tmp, options: .atomic)
                _ = try? fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
            } catch {
                NSLog("[ProjectStore] save failed: %@", "\(error)")
            }
        }
    }
}
