import SwiftUI
import AppKit

/// Tam ekran workspace: üstte 40px sekme çubuğu, altta içerik.
/// TÜM sekme içerikleri ZStack'te canlı tutulur; aktif olmayanlar
/// opacity(0) + allowsHitTesting(false) — geçişler anlıktır.
struct WorkspaceView: View {
    let project: Project
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var pm: ProcessManager
    @ObservedObject var tabStore: ClaudeTabStore
    @ObservedObject var browser: BrowserManager

    @State private var renamingTabID: UUID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    private var tabs: [WorkspaceTab] { workspace.tabs(for: project.id) }
    private var activeID: UUID? { workspace.activeTab[project.id] }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .background(Color(NSColor.windowBackgroundColor))
        // Adopt edilen (tmux'tan geri gelen) Claude sekmelerini reattach et.
        .onChange(of: tabs.map(\.id), initial: true) { _, _ in
            ensureClaudeTabsStarted()
        }
    }

    // MARK: - Sekme çubuğu

    private var tabBar: some View {
        HStack(spacing: 8) {
            PanelSwitcher(projectID: project.id, workspace: workspace)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        tabPill(tab)
                            .draggable(tab.id.uuidString)
                            .dropDestination(for: String.self) { dropped, _ in
                                guard let s = dropped.first, let dragged = UUID(uuidString: s),
                                      dragged != tab.id else { return false }
                                withAnimation(.easeOut(duration: 0.15)) {
                                    workspace.moveTab(dragged, before: tab.id, in: project.id)
                                }
                                return true
                            }
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Boş alana bırakma = sona taşı.
            .dropDestination(for: String.self) { dropped, _ in
                guard let s = dropped.first, let dragged = UUID(uuidString: s) else { return false }
                withAnimation(.easeOut(duration: 0.15)) {
                    workspace.moveTab(dragged, before: nil, in: project.id)
                }
                return true
            }

            newClaudeButton
            newTerminalMenu
            if !webItems.isEmpty {
                webMenu
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(.ultraThinMaterial)
    }

    private var closedTabs: [ClaudeTabStore.ClosedTab] {
        tabStore.closed[project.id] ?? []
    }

    /// "+" menüsü: yeni Claude sekmesi VEYA kapatılmış bir oturumu adıyla sürdür.
    private var newClaudeButton: some View {
        Menu {
            Button {
                addClaudeTab()
            } label: {
                Label("Yeni Claude Sekmesi", systemImage: "plus")
            }
            if !closedTabs.isEmpty {
                Divider()
                Section("Kapatılmış oturumu sürdür") {
                    ForEach(closedTabs) { ct in
                        Button {
                            reopenClosed(ct)
                        } label: {
                            Label(closedLabel(ct), systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
                Divider()
                Button("Geçmiş Listesini Temizle", role: .destructive) {
                    tabStore.clearClosed(for: project.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Claude")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.4), lineWidth: 0.5)
            )
            .foregroundStyle(Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Yeni Claude sekmesi (⌘T) veya kapatılmış oturumu sürdür")
    }

    private func closedLabel(_ ct: ClaudeTabStore.ClosedTab) -> String {
        if let name = ct.name, !name.isEmpty {
            return name
        }
        if let title = ct.title, !title.isEmpty {
            return title
        }
        return "Claude \(ct.number)"
    }

    private func reopenClosed(_ ct: ClaudeTabStore.ClosedTab) {
        tabStore.removeClosed(number: ct.number, for: project.id)
        let resume = ct.claudeSID.map { ClaudeResumeOptions(sessionID: $0) }
        ClaudeTabLauncher.open(project: project, workspace: workspace, tabStore: tabStore,
                               pm: pm, resume: resume, customName: ct.name)
    }

    private var newTerminalMenu: some View {
        Menu {
            Button {
                addShellTab(cwd: project.path)
            } label: {
                Label("Proje Dizini", systemImage: "folder")
            }
            Button {
                pickDirectoryAndOpenShell()
            } label: {
                Label("Diğer Dizin…", systemImage: "folder.badge.plus")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Terminal")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Yeni terminal sekmesi aç")
    }

    private var webItems: [CanvasItem] {
        project.items.filter { $0.kind == .web && !($0.url ?? "").isEmpty }
    }

    private var webMenu: some View {
        Menu {
            ForEach(webItems) { item in
                Button {
                    openWebTab(item)
                } label: {
                    Label(item.name, systemImage: "globe")
                }
            }
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.10))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Web sekmesi aç")
    }

    // MARK: - Pill

    @ViewBuilder
    private func tabPill(_ tab: WorkspaceTab) -> some View {
        let isActive = tab.id == activeID
        let isRenaming = renamingTabID == tab.id

        HStack(spacing: 6) {
            if let dot = pillDot(tab) {
                Circle()
                    .fill(dot)
                    .frame(width: 7, height: 7)
            }
            if tab.kind == .web {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if isRenaming {
                TextField("Claude \(tab.number ?? 0)", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(minWidth: 80, idealWidth: 120)
                    .fixedSize()
                    .focused($renameFocused)
                    .onSubmit { commitRename(tab) }
                    .onExitCommand { cancelRename() }
            } else {
                Text(pillTitle(tab))
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
            }

            Button {
                if isRenaming {
                    commitRename(tab)
                } else {
                    close(tab)
                }
            } label: {
                Image(systemName: isRenaming ? "checkmark" : "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help(isRenaming ? "Adı kaydet (Enter)" : "Sekmeyi kapat")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2),
                        lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if tab.kind == .claude, !isRenaming {
                startRename(tab)
            }
        }
        .onTapGesture {
            if !isRenaming {
                workspace.select(tab.id, in: project.id)
            }
        }
        .help(pillTitle(tab))
    }

    /// Claude: attention noktası (waiting=kırmızı, working=yeşil); servis: durum rengi.
    private func pillDot(_ tab: WorkspaceTab) -> Color? {
        switch tab.kind {
        case .claude:
            switch pm.attention[tab.id] {
            case .waiting: return .red
            case .working: return .green
            case nil: return Color.secondary.opacity(0.5)
            }
        case .service:
            guard let itemID = tab.itemID else { return nil }
            return pm.status(of: itemID).color
        case .shell, .oneshot, .web:
            return nil
        }
    }

    /// Öncelik: customName → tmux pane title (baştaki glifler soyulur) → "Claude N".
    private func pillTitle(_ tab: WorkspaceTab) -> String {
        guard tab.kind == .claude else { return tab.title }
        if let name = tab.customName, !name.isEmpty { return name }
        if let session = tab.tmuxSession,
           let raw = pm.paneTitles[session],
           let cleaned = strippedTitle(raw) {
            return cleaned
        }
        return "Claude \(tab.number ?? 0)"
    }

    private func strippedTitle(_ raw: String) -> String? {
        let s = String(raw.drop(while: { !($0.isLetter || $0.isNumber) }))
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    // MARK: - İçerik

    @ViewBuilder
    private var content: some View {
        if tabs.isEmpty {
            emptyState
        } else {
            ZStack {
                ForEach(tabs) { tab in
                    tabContent(tab)
                        .opacity(tab.id == activeID ? 1 : 0)
                        .allowsHitTesting(tab.id == activeID)
                }
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: WorkspaceTab) -> some View {
        if tab.kind == .web {
            WebTabView(key: webKey(tab),
                       url: tab.url ?? "http://localhost",
                       manager: browser)
        } else {
            TerminalHostView(key: terminalKey(tab), manager: pm)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Açık sekme yok")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button {
                addClaudeTab()
            } label: {
                Label("Yeni Claude Sekmesi", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Servis sekmeleri canvas'taki servisle aynı PTY view'ını paylaşır (key = item id).
    private func terminalKey(_ tab: WorkspaceTab) -> String {
        if tab.kind == .service, let itemID = tab.itemID { return itemID.uuidString }
        return tab.id.uuidString
    }

    private func webKey(_ tab: WorkspaceTab) -> String {
        tab.itemID?.uuidString ?? tab.id.uuidString
    }

    // MARK: - Sekme aksiyonları

    private func addClaudeTab() {
        let n = tabStore.nextNumber(for: project.id)
        let tabID = UUID()
        let tab = WorkspaceTab(id: tabID,
                               kind: .claude,
                               title: "Claude \(n)",
                               tmuxSession: tabID.uuidString,
                               number: n)
        workspace.addTab(tab, to: project.id, activate: true)
        pm.startClaude(tabID: tabID, project: project, number: n,
                       customName: nil, resume: nil, existingSession: nil)
    }

    private func addShellTab(cwd: String) {
        let last = (cwd as NSString).lastPathComponent
        let tab = WorkspaceTab(kind: .shell, title: last.isEmpty ? "Terminal" : last)
        workspace.addTab(tab, to: project.id, activate: true)
        pm.startShell(tabID: tab.id, cwd: cwd)
    }

    private func pickDirectoryAndOpenShell() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Seç"
        panel.message = "Terminalin açılacağı dizini seç"
        panel.directoryURL = URL(fileURLWithPath: project.path)
        if panel.runModal() == .OK, let url = panel.url {
            addShellTab(cwd: url.path)
        }
    }

    private func openWebTab(_ item: CanvasItem) {
        if let existing = tabs.first(where: { $0.kind == .web && $0.itemID == item.id }) {
            workspace.select(existing.id, in: project.id)
            return
        }
        let tab = WorkspaceTab(kind: .web, title: item.name, itemID: item.id, url: item.url)
        workspace.addTab(tab, to: project.id, activate: true)
    }

    private func close(_ tab: WorkspaceTab) {
        switch tab.kind {
        case .claude:
            closeClaudeTab(tab)
        case .service, .web:
            // Servis prosesi/PTY yaşamaya devam eder; yalnız sekme kapanır.
            workspace.closeTab(tab.id, in: project.id)
        case .shell, .oneshot:
            pm.closeTab(tabID: tab.id, killTmux: false)
            workspace.closeTab(tab.id, in: project.id)
        }
    }

    /// Sekme UI'dan ANINDA düşer; sid okuma + tmux kill + kayıt arka planda.
    private func closeClaudeTab(_ tab: WorkspaceTab) {
        workspace.closeTab(tab.id, in: project.id)
        ClaudeTabLauncher.finishClose(tab, projectID: project.id, tabStore: tabStore, pm: pm)
    }

    /// tmux'tan adopt edilen sekmelerin PTY'si yoktur — new-session -A ile reattach.
    private func ensureClaudeTabsStarted() {
        for tab in tabs where tab.kind == .claude {
            guard !pm.hasTerminalView(forKey: tab.id.uuidString) else { continue }
            pm.startClaude(tabID: tab.id, project: project, number: tab.number ?? 0,
                           customName: tab.customName, resume: nil,
                           existingSession: tab.tmuxSession)
        }
    }

    // MARK: - Yeniden adlandırma

    private func startRename(_ tab: WorkspaceTab) {
        renamingTabID = tab.id
        renameText = tab.customName ?? ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            renameFocused = true
        }
    }

    private func commitRename(_ tab: WorkspaceTab) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        let newName: String? = trimmed.isEmpty ? nil : trimmed
        workspace.renameTab(tab.id, in: project.id, to: newName)
        if let session = tab.tmuxSession {
            // @deck_name'e yaz ki ad, adoptTmuxSessions ile yeniden açılışta korunsun.
            let value = newName ?? ""
            Task.detached { TmuxService.setOption(session, key: "@deck_name", value: value) }
        }
        renamingTabID = nil
        renameText = ""
    }

    private func cancelRename() {
        renamingTabID = nil
        renameText = ""
    }
}
