import Foundation
import SwiftUI

/// Proje başına workspace sekme durumu. Sekmeler bellekte yaşar; Claude sekmeleri
/// uygulama yeniden açıldığında tmux'tan `adoptTmuxSessions` ile geri gelir.
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var tabs: [UUID: [WorkspaceTab]] = [:]
    @Published var activeTab: [UUID: UUID] = [:]
    @Published var workspaceOpen: [UUID: Bool] = [:]

    func tabs(for projectID: UUID) -> [WorkspaceTab] {
        tabs[projectID] ?? []
    }

    func addTab(_ tab: WorkspaceTab, to projectID: UUID, activate: Bool) {
        var list = tabs[projectID] ?? []
        if list.contains(where: { $0.id == tab.id }) {
            if activate { activeTab[projectID] = tab.id }
            return
        }
        list.append(tab)
        tabs[projectID] = list
        if activate || activeTab[projectID] == nil {
            activeTab[projectID] = tab.id
        }
    }

    func closeTab(_ tabID: UUID, in projectID: UUID) {
        var list = tabs[projectID] ?? []
        guard let idx = list.firstIndex(where: { $0.id == tabID }) else { return }
        list.remove(at: idx)
        tabs[projectID] = list
        if activeTab[projectID] == tabID {
            if list.indices.contains(idx) {
                activeTab[projectID] = list[idx].id
            } else {
                activeTab[projectID] = list.last?.id
            }
        }
    }

    func select(_ tabID: UUID, in projectID: UUID) {
        guard tabs(for: projectID).contains(where: { $0.id == tabID }) else { return }
        activeTab[projectID] = tabID
    }

    /// Sürükle-bırak sıralama: `tabID`'yi `targetID`'nin önüne taşır;
    /// `targetID` nil ise sona atar.
    func moveTab(_ tabID: UUID, before targetID: UUID?, in projectID: UUID) {
        var list = tabs[projectID] ?? []
        guard let from = list.firstIndex(where: { $0.id == tabID }) else { return }
        let moved = list.remove(at: from)
        if let targetID, let to = list.firstIndex(where: { $0.id == targetID }) {
            list.insert(moved, at: to)
        } else {
            list.append(moved)
        }
        tabs[projectID] = list
    }

    func renameTab(_ tabID: UUID, in projectID: UUID, to name: String?) {
        guard var list = tabs[projectID],
              let idx = list.firstIndex(where: { $0.id == tabID }) else { return }
        list[idx].customName = name
        if let name, !name.isEmpty { list[idx].title = name }
        tabs[projectID] = list
    }

    /// Açılışta tmux'tan `@deck_project == project.shortID` olan oturumları sekme olarak
    /// geri getirir. İdempotent: zaten açık olan oturum için sekme eklemez.
    /// Reattach (pm.startClaude) WorkspaceView tarafında yapılır.
    func adoptTmuxSessions(for project: Project, tabStore: ClaudeTabStore) {
        let shortID = project.shortID
        let projectID = project.id
        Task.detached(priority: .userInitiated) { [weak self, weak tabStore] in
            let sessions = TmuxService.listSessions().filter { $0.projectID == shortID }
            guard !sessions.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                var list = self.tabs[projectID] ?? []
                var maxNumber = 0
                for session in sessions.sorted(by: { $0.number < $1.number }) {
                    maxNumber = max(maxNumber, session.number)
                    guard !list.contains(where: { $0.tmuxSession == session.name }) else { continue }
                    let tab = WorkspaceTab(id: UUID(uuidString: session.name) ?? UUID(),
                                           kind: .claude,
                                           title: session.customName ?? "Claude \(session.number)",
                                           tmuxSession: session.name,
                                           number: session.number,
                                           customName: session.customName)
                    list.append(tab)
                }
                self.tabs[projectID] = list
                if self.activeTab[projectID] == nil {
                    self.activeTab[projectID] = list.first?.id
                }
                tabStore?.bumpCounter(for: projectID, atLeast: maxNumber)
            }
        }
    }

    func openWorkspace(_ projectID: UUID, _ open: Bool) {
        workspaceOpen[projectID] = open
    }
}
