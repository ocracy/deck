import Foundation

/// Discovers Claude Code skills under each project's `<path>/.claude/skills`
/// and caches them in memory. Scanned once per project open (on appear) so the
/// right-click menu reads instantly without hitting disk.
///
/// Layout supported:
///   .claude/skills/<name>/SKILL.md   → skill name = folder name
///   .claude/skills/<name>.md         → skill name = file stem
@MainActor
final class SkillStore: ObservableObject {
    @Published private(set) var skills: [UUID: [String]] = [:]

    func skills(for projectID: UUID) -> [String] {
        skills[projectID] ?? []
    }

    func scan(project: Project) {
        let projectID = project.id
        let root = URL(fileURLWithPath: (project.path as NSString).expandingTildeInPath)
            .appendingPathComponent(".claude/skills")
        Task.detached(priority: .utility) { [weak self] in
            let found = Self.discover(in: root)
            await MainActor.run { self?.skills[projectID] = found }
        }
    }

    private nonisolated static func discover(in root: URL) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        var names: Set<String> = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                // A skill folder must contain a SKILL.md to count.
                let skillFile = entry.appendingPathComponent("SKILL.md")
                if fm.fileExists(atPath: skillFile.path) {
                    names.insert(entry.lastPathComponent)
                }
            } else if entry.pathExtension.lowercased() == "md",
                      entry.deletingPathExtension().lastPathComponent.lowercased() != "readme" {
                names.insert(entry.deletingPathExtension().lastPathComponent)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
