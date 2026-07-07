import SwiftUI

// MARK: - Claude sekme aç/kapat yardımcıları (CanvasView + ProjectView ortak)

@MainActor
enum ClaudeTabLauncher {
    static func open(project: Project,
                     workspace: WorkspaceStore,
                     tabStore: ClaudeTabStore,
                     pm: ProcessManager,
                     resume: ClaudeResumeOptions? = nil,
                     customName: String? = nil) {
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
                       existingSession: nil)
        workspace.openWorkspace(project.id, true)
    }

    /// Claude sekmesi kapanırken @claude_sid kaydedilir ki sonradan sürdürülebilsin.
    static func close(_ tab: WorkspaceTab,
                      projectID: UUID,
                      workspace: WorkspaceStore,
                      tabStore: ClaudeTabStore,
                      pm: ProcessManager) {
        guard tab.kind == .claude, let number = tab.number else {
            pm.closeTab(tabID: tab.id, killTmux: false)
            workspace.closeTab(tab.id, in: projectID)
            return
        }
        let sessionName = tab.tmuxSession
        let title = sessionName.flatMap { pm.paneTitles[$0] }
        let customName = tab.customName
        Task {
            let sid: String? = await Task.detached { () -> String? in
                guard let sessionName else { return nil }
                return TmuxService.listSessions().first { $0.name == sessionName }?.claudeSID
            }.value
            tabStore.recordClosed(.init(number: number, name: customName, claudeSID: sid, title: title),
                                  for: projectID)
            pm.closeTab(tabID: tab.id, killTmux: true)
            workspace.closeTab(tab.id, in: projectID)
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
    @ObservedObject var router: AppRouter

    @State private var didAppear = false

    private var isWorkspaceOpen: Bool {
        workspace.workspaceOpen[project.id] ?? false
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
                           store: store,
                           pm: pm,
                           workspace: workspace,
                           tabStore: tabStore)
                // Workspace her zaman mount kalır; terminal/web içerikleri yaşar.
                WorkspaceView(project: project,
                              workspace: workspace,
                              pm: pm,
                              tabStore: tabStore,
                              browserManager: browserManager)
                    .opacity(isWorkspaceOpen ? 1 : 0)
                    .allowsHitTesting(isWorkspaceOpen)
            }
        }
        .background(Color(hex: "#101018"))
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            workspace.adoptTmuxSessions(for: project, tabStore: tabStore)
        }
        .onReceive(NotificationCenter.default.publisher(for: .deckToggleWorkspace)) { _ in
            guard isActive else { return }
            workspace.openWorkspace(project.id, !isWorkspaceOpen)
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
            .help("Projelere dön")

            IconView(spec: project.icon, size: 24)
            Text(project.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            if runningServiceCount > 0 {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("\(runningServiceCount) servis çalışıyor")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                }
                .padding(.trailing, 6)
            }

            Button {
                workspace.openWorkspace(project.id, !isWorkspaceOpen)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isWorkspaceOpen ? "chevron.down" : "rectangle.topthird.inset.filled")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Workspace")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Workspace'i aç/kapat (⌘B)")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(hex: "#14141E"))
    }
}
