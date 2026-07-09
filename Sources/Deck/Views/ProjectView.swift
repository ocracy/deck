import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Claude sekme aç/kapat yardımcıları (CanvasView + ProjectView ortak)

@MainActor
enum ClaudeTabLauncher {
    static func open(project: Project,
                     workspace: WorkspaceStore,
                     tabStore: ClaudeTabStore,
                     pm: ProcessManager,
                     resume: ClaudeResumeOptions? = nil,
                     customName: String? = nil,
                     initialCommand: String? = nil,
                     autoRun: Bool = false,
                     cwd: String? = nil) {
        let number = tabStore.nextNumber(for: project.id)
        let tabID = UUID()
        let tab = WorkspaceTab(id: tabID,
                               kind: .claude,
                               title: "Claude \(number)",
                               tmuxSession: tabID.uuidString,
                               number: number,
                               customName: customName)
        workspace.addTab(tab, to: project.id, activate: true)
        pm.startClaude(tabID: tabID,
                       project: project,
                       number: number,
                       customName: customName,
                       resume: resume,
                       existingSession: nil,
                       initialCommand: initialCommand,
                       autoRun: autoRun,
                       cwdOverride: cwd)
        workspace.openWorkspace(project.id, true)
    }

    /// Sekme UI'dan anında düşer; ağır temizlik bir sonraki runloop'a ertelenir.
    static func close(_ tab: WorkspaceTab,
                      projectID: UUID,
                      workspace: WorkspaceStore,
                      tabStore: ClaudeTabStore,
                      pm: ProcessManager) {
        workspace.closeTab(tab.id, in: projectID)
        DispatchQueue.main.async {
            guard tab.kind == .claude, tab.number != nil else {
                pm.closeTab(tabID: tab.id, killTmux: false)
                return
            }
            finishClose(tab, projectID: projectID, tabStore: tabStore, pm: pm)
        }
    }

    /// Kapanan Claude sekmesinin sid'ini yakala (tmux → hook fallback),
    /// resume listesine kaydet ve tmux oturumunu öldür — hepsi arka planda.
    static func finishClose(_ tab: WorkspaceTab,
                            projectID: UUID,
                            tabStore: ClaudeTabStore,
                            pm: ProcessManager) {
        let sessionName = tab.tmuxSession
        let number = tab.number ?? 0
        let customName = tab.customName
        let title = sessionName.flatMap { pm.paneTitles[$0] }
        Task {
            let tmuxSid: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let sessionName else { return nil }
                return TmuxService.listSessions().first { $0.name == sessionName }?.claudeSID
            }.value
            // Oturum tmux'ta yoksa (ör. /exit ile bitti) hook'un yakaladığı sid'e düş.
            let sid = tmuxSid ?? pm.claudeSID(for: tab.id)
            tabStore.recordClosed(.init(number: number, name: customName, claudeSID: sid, title: title),
                                  for: projectID)
            pm.closeTab(tabID: tab.id, killTmux: true)
        }
    }
}

// MARK: - ProjectView

struct ProjectView: View {
    let project: Project
    @ObservedObject var store: ProjectStore
    @ObservedObject var pm: ProcessManager
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var tabStore: ClaudeTabStore
    @ObservedObject var browserManager: BrowserManager
    @ObservedObject var skillStore: SkillStore
    @ObservedObject var router: AppRouter

    @State private var didAppear = false
    @State private var showSettings = false
    @State private var deckJSONMtime: Date?
    private let deckJSONTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var isWorkspaceOpen: Bool {
        workspace.workspaceOpen[project.id] ?? false
    }

    private var isServicePanelOpen: Bool {
        workspace.servicePanelOpen[project.id] ?? false
    }

    private var isActive: Bool {
        router.selectedProjectID == project.id
    }

    private var runningServiceCount: Int {
        project.items.filter {
            $0.kind == .terminal && $0.mode == .service && pm.status(of: $0.id).isRunning
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Color.white.opacity(0.06))
            ZStack {
                CanvasView(project: project,
                           keyboardEnabled: isActive && !isWorkspaceOpen && !isServicePanelOpen,
                           store: store,
                           pm: pm,
                           workspace: workspace,
                           tabStore: tabStore,
                           skillStore: skillStore)
                // Servis paneli: yalnız servis terminalleri, stop/restart kontrolleriyle.
                ServicePanelView(project: project, workspace: workspace, pm: pm)
                    .opacity(isServicePanelOpen ? 1 : 0)
                    .allowsHitTesting(isServicePanelOpen)
                // Workspace her zaman mount kalır; terminal/web içerikleri yaşar.
                WorkspaceView(project: project,
                              workspace: workspace,
                              pm: pm,
                              tabStore: tabStore,
                              browser: browserManager)
                    .opacity(isWorkspaceOpen ? 1 : 0)
                    .allowsHitTesting(isWorkspaceOpen)
            }
        }
        .background(Color(hex: "#101018"))
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            pm.adoptClaudeTabs(for: project, workspace: workspace, tabStore: tabStore)
            pm.scanExternalServices(projects: [project])
            skillStore.scan(project: project)
            syncDeckJSON(force: true)
        }
        .sheet(isPresented: $showSettings) {
            ProjectSettingsSheet(project: project) { updated in
                store.updateProject(updated)
            }
        }
        // deck.json köprüsü: Claude (veya kullanıcı) dosyayı değiştirince
        // öğeler canvas'a otomatik akar.
        .onReceive(deckJSONTimer) { _ in
            guard isActive else { return }
            syncDeckJSON(force: false)
        }
        // Workspace/panel kapanınca odağı gizli terminalden al — yoksa canvas
        // kısayolları ölür ve tuşlar görünmez Claude'a akar.
        .onChange(of: isWorkspaceOpen) { _, open in
            if !open { releaseTerminalFocus() }
        }
        .onChange(of: isServicePanelOpen) { _, open in
            if !open { releaseTerminalFocus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deckToggleWorkspace)) { _ in
            guard isActive else { return }
            workspace.openWorkspace(project.id, !isWorkspaceOpen)
        }
        .onReceive(NotificationCenter.default.publisher(for: .deckToggleServicePanel)) { _ in
            guard isActive else { return }
            workspace.openServicePanel(project.id, !isServicePanelOpen)
        }
        .onReceive(NotificationCenter.default.publisher(for: .deckNewClaudeTab)) { _ in
            guard isActive else { return }
            ClaudeTabLauncher.open(project: project, workspace: workspace, tabStore: tabStore, pm: pm)
        }
        .onReceive(NotificationCenter.default.publisher(for: .deckCloseActiveTab)) { _ in
            guard isActive, isWorkspaceOpen,
                  let activeID = workspace.activeTab[project.id],
                  let tab = workspace.tabs(for: project.id).first(where: { $0.id == activeID })
            else { return }
            ClaudeTabLauncher.close(tab, projectID: project.id,
                                    workspace: workspace, tabStore: tabStore, pm: pm)
        }
        .onReceive(NotificationCenter.default.publisher(for: .deckSelectTab)) { note in
            guard isActive, isWorkspaceOpen, let n = note.object as? Int else { return }
            let tabs = workspace.tabs(for: project.id)
            guard n >= 1, n <= tabs.count else { return }
            workspace.select(tabs[n - 1].id, in: project.id)
        }
    }

    private func releaseTerminalFocus() {
        DispatchQueue.main.async {
            if NSApp.keyWindow?.firstResponder is LocalProcessTerminalView {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private func syncDeckJSON(force: Bool) {
        let mtime = DeckFileService.modificationDate(for: project)
        guard let mtime else { return }
        if !force, mtime == deckJSONMtime { return }
        deckJSONMtime = mtime
        DeckFileService.sync(project: project, store: store)
    }

    // MARK: - Üst bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                router.selectedProjectID = nil
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Back to projects")

            // Proje ikonu + adı: tıklayınca masaüstüne (ikonlara) dön.
            Button {
                workspace.openWorkspace(project.id, false)
                workspace.openServicePanel(project.id, false)
            } label: {
                HStack(spacing: 8) {
                    IconView(spec: project.icon, size: 24)
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    if isWorkspaceOpen || isServicePanelOpen {
                        Image(systemName: "house.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to desktop")

            Spacer()

            if runningServiceCount > 0 {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("\(runningServiceCount) running")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                }
                .padding(.trailing, 4)
            }

            // Workspace ↔ Servisler geçişi burada — sekme hizasında değil,
            // proje barında (⌘B / ⌘J kısayollarıyla).
            PanelSwitcher(projectID: project.id, workspace: workspace)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Project settings")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(hex: "#14141E"))
    }
}
