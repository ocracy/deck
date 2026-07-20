import Foundation
import SwiftUI

/// Proje başına workspace sekme durumu. Sekmeler bellekte yaşar; Claude sekmeleri
/// uygulama yeniden açıldığında tmux'tan `adoptTmuxSessions` ile geri gelir.
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var tabs: [UUID: [WorkspaceTab]] = [:]
    @Published var activeTab: [UUID: UUID] = [:]
    @Published var workspaceOpen: [UUID: Bool] = [:]
    /// Servis paneli: workspace'ten ayrı, yalnız servis terminallerini gösterir.
    @Published var servicePanelOpen: [UUID: Bool] = [:]
    @Published var activeService: [UUID: UUID] = [:]

    func tabs(for projectID: UUID) -> [WorkspaceTab] {
        tabs[projectID] ?? []
    }

    /// Herhangi bir projedeki `tabID`'nin güncel görünen adını döndürür
    /// (kullanıcı yeniden adlandırdıysa `customName`/`title`). Bildirimler
    /// donmuş `DECK_TAB_NAME` yerine bunu kullanır. Bulunamazsa nil.
    func displayName(forTab tabID: UUID) -> String? {
        for list in tabs.values {
            if let tab = list.first(where: { $0.id == tabID }) {
                if let name = tab.customName, !name.isEmpty { return name }
                return tab.title
            }
        }
        return nil
    }

    func addTab(_ tab: WorkspaceTab, to projectID: UUID, activate: Bool) {
        var list = tabs[projectID] ?? []
        if list.contains(where: { $0.id == tab.id }) {
            if activate {
                activeTab[projectID] = tab.id
                touch(tab.id, in: projectID)
                openWorkspace(projectID, true)
            }
            return
        }
        list.append(tab)
        tabs[projectID] = list
        if activate || activeTab[projectID] == nil {
            activeTab[projectID] = tab.id
            touch(tab.id, in: projectID)
        }
        // Sekme eklenince içerik görünsün (masaüstünden workspace'e geç).
        if activate { openWorkspace(projectID, true) }
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
        guard activeTab[projectID] != tabID else { return }   // aynı sekme: gereksiz re-render yok
        guard tabs(for: projectID).contains(where: { $0.id == tabID }) else { return }
        activeTab[projectID] = tabID
        touch(tabID, in: projectID)
    }

    /// Sekmeyi "az önce kullanıldı" olarak damgalar (öne getirme anında). Zamanı
    /// belleğe yazar ve Claude sekmelerinde tmux `@deck_used` opsiyonuna kaydeder
    /// ki uygulama yeniden açıldığında (adoptTmuxSessions) korunsun.
    func touch(_ tabID: UUID, in projectID: UUID) {
        guard var list = tabs[projectID],
              let idx = list.firstIndex(where: { $0.id == tabID }) else { return }
        let now = Date()
        list[idx].lastUsedAt = now
        tabs[projectID] = list
        if let session = list[idx].tmuxSession {
            let epoch = String(Int(now.timeIntervalSince1970))
            Task.detached { TmuxService.setOption(session, key: "@deck_used", value: epoch) }
        }
    }

    /// Sekmeleri son kullanıma göre sıralar: en yeni en solda. Zamanı olmayanlar
    /// (hiç seçilmemiş / eski oturumlar) sona düşer, aralarında mevcut sıra korunur.
    func sortByRecent(_ projectID: UUID) {
        guard var list = tabs[projectID], list.count > 1 else { return }
        list = list.enumerated().sorted { a, b in
            let ta = a.element.lastUsedAt, tb = b.element.lastUsedAt
            switch (ta, tb) {
            case let (x?, y?): return x > y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return a.offset < b.offset   // stabil
            }
        }.map(\.element)
        tabs[projectID] = list
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
    /// `reattach`: her adopt edilen (ya da zaten listede olan) Claude sekmesi için
    /// çağrılır — workspace görünür olsun olmasın hemen tmux'a bağlanması sağlanır
    /// (WorkspaceView'ın gizliyken çalışmayan onChange'ine güvenmek yerine).
    func adoptTmuxSessions(for project: Project, tabStore: ClaudeTabStore,
                           reattach: @escaping (WorkspaceTab) -> Void) {
        let shortID = project.shortID
        let projectID = project.id
        Task.detached(priority: .userInitiated) { [weak self, weak tabStore] in
            // tmux server açılışta soğuksa ilk list-sessions eksik/boş dönebilir;
            // dolu bir yanıt gelene kadar kısa aralıklarla birkaç kez dene.
            var all = TmuxService.listSessions()
            var tries = 0
            while all.isEmpty, tries < 5, FileManager.default.fileExists(atPath: TmuxService.socketPath) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                all = TmuxService.listSessions()
                tries += 1
            }
            let sessions = all.filter { $0.projectID == shortID }
            await MainActor.run {
                guard let self else { return }
                var list = self.tabs[projectID] ?? []
                var maxNumber = 0
                for session in sessions.sorted(by: { $0.number < $1.number }) {
                    maxNumber = max(maxNumber, session.number)
                    if !list.contains(where: { $0.tmuxSession == session.name }) {
                        let tab = WorkspaceTab(id: UUID(uuidString: session.name) ?? UUID(),
                                               kind: .claude,
                                               title: session.customName ?? "Claude \(session.number)",
                                               tmuxSession: session.name,
                                               number: session.number,
                                               customName: session.customName,
                                               lastUsedAt: session.lastUsed)
                        list.append(tab)
                    }
                }
                self.tabs[projectID] = list
                if self.activeTab[projectID] == nil {
                    self.activeTab[projectID] = list.first?.id
                }
                tabStore?.bumpCounter(for: projectID, atLeast: maxNumber)
                // Her Claude sekmesini hemen reattach et (idempotent).
                for tab in list where tab.kind == .claude {
                    reattach(tab)
                }
            }
        }
    }

    /// Workspace ile servis paneli aynı anda açık olmaz.
    func openWorkspace(_ projectID: UUID, _ open: Bool) {
        workspaceOpen[projectID] = open
        if open { servicePanelOpen[projectID] = false }
    }

    func openServicePanel(_ projectID: UUID, _ open: Bool) {
        servicePanelOpen[projectID] = open
        if open { workspaceOpen[projectID] = false }
    }

    func selectService(_ itemID: UUID, in projectID: UUID) {
        activeService[projectID] = itemID
    }
}
