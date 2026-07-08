import SwiftUI
import AppKit

// MARK: - Klavye kısayolu bildirimleri (CommandMenu → aktif ProjectView)

extension Notification.Name {
    /// ⌘B — workspace'i aç/kapat.
    static let deckToggleWorkspace = Notification.Name("Deck.ToggleWorkspace")
    /// ⌘J — servis panelini aç/kapat.
    static let deckToggleServicePanel = Notification.Name("Deck.ToggleServicePanel")
    /// ⌘T — yeni Claude sekmesi.
    static let deckNewClaudeTab = Notification.Name("Deck.NewClaudeTab")
    /// ⌘W — aktif sekmeyi kapat.
    static let deckCloseActiveTab = Notification.Name("Deck.CloseActiveTab")
    /// ⌘1..9 — sekme seç; `object: Int` (1...9).
    static let deckSelectTab = Notification.Name("Deck.SelectTab")
    /// ⌘⌫ — canvas'ta seçili öğeleri sil (menü fallback'i).
    static let deckDeleteSelection = Notification.Name("Deck.DeleteSelection")
    /// ⌘P — canvas arama paleti (menü fallback'i).
    static let deckSearchCanvas = Notification.Name("Deck.SearchCanvas")
}

// MARK: - Router

@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedProjectID: UUID?
    /// Açılmış projeler mount kalır (terminal/web içerikleri yaşasın diye).
    @Published var openedProjectIDs: Set<UUID> = []

    func open(_ id: UUID) {
        openedProjectIDs.insert(id)
        selectedProjectID = id
    }

    func closeProject(_ id: UUID) {
        openedProjectIDs.remove(id)
        if selectedProjectID == id { selectedProjectID = nil }
    }
}

// MARK: - App

@main
struct DeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var processManager = ProcessManager()
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var tabStore = ClaudeTabStore()
    @StateObject private var browserManager = BrowserManager()
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup("Deck") {
            RootView(router: router,
                     store: projectStore,
                     pm: processManager,
                     workspace: workspaceStore,
                     tabStore: tabStore,
                     browserManager: browserManager)
                .frame(minWidth: 1000, minHeight: 640)
                .preferredColorScheme(.dark)
                .onAppear { bootstrap() }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Çalışma Alanı") {
                Button("Workspace'i Aç/Kapat") {
                    NotificationCenter.default.post(name: .deckToggleWorkspace, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Servis Panelini Aç/Kapat") {
                    NotificationCenter.default.post(name: .deckToggleServicePanel, object: nil)
                }
                .keyboardShortcut("j", modifiers: .command)

                Button("Yeni Claude Sekmesi") {
                    NotificationCenter.default.post(name: .deckNewClaudeTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Sekmeyi Kapat") {
                    NotificationCenter.default.post(name: .deckCloseActiveTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)

                Divider()

                Button("Öğe Ara") {
                    NotificationCenter.default.post(name: .deckSearchCanvas, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("Seçilenleri Sil") {
                    NotificationCenter.default.post(name: .deckDeleteSelection, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)

                Divider()

                ForEach(1..<10) { n in
                    Button("Sekme \(n)") {
                        NotificationCenter.default.post(name: .deckSelectTab, object: n)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
        }
    }

    private func bootstrap() {
        appDelegate.processManager = processManager
        appDelegate.browserManager = browserManager
        appDelegate.projectStore = projectStore
        processManager.projectStore = projectStore
        processManager.tabStore = tabStore

        TmuxService.ensureConfig()
        DispatchQueue.global(qos: .utility).async {
            HookInstaller.installIfNeeded()
        }
        // Sessiz güncelleme kontrolü (24 saat throttle'lı).
        Task { await UpdateChecker.shared.checkNow(force: false) }

        for project in projectStore.projects {
            for item in project.items
            where item.kind == .terminal && item.mode == .service && item.autoStart {
                processManager.startService(item, project: project)
            }
        }
        processManager.scanExternalServices(projects: projectStore.projects)
    }
}

// MARK: - RootView

struct RootView: View {
    @ObservedObject var router: AppRouter
    @ObservedObject var store: ProjectStore
    @ObservedObject var pm: ProcessManager
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var tabStore: ClaudeTabStore
    @ObservedObject var browserManager: BrowserManager

    private var openedProjects: [Project] {
        store.projects.filter { router.openedProjectIDs.contains($0.id) }
    }

    var body: some View {
        ZStack {
            HomeView(store: store, pm: pm, workspace: workspace, router: router)
                .opacity(router.selectedProjectID == nil ? 1 : 0)
                .allowsHitTesting(router.selectedProjectID == nil)

            // Açılmış her proje mount kalır; yalnız seçili olan görünür.
            ForEach(openedProjects) { project in
                ProjectView(project: project,
                            store: store,
                            pm: pm,
                            workspace: workspace,
                            tabStore: tabStore,
                            browserManager: browserManager,
                            router: router)
                    .opacity(router.selectedProjectID == project.id ? 1 : 0)
                    .allowsHitTesting(router.selectedProjectID == project.id)
            }
        }
        .background(Color(hex: "#101018"))
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var processManager: ProcessManager?
    weak var browserManager: BrowserManager?
    weak var projectStore: ProjectStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` ile doğrudan çalıştırıldığında da pencere öne gelsin.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let win = NSApp.windows.first { win.makeKeyAndOrderFront(nil) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        projectStore?.flushSync()
        processManager?.terminateAllSync()
        browserManager?.clearAll()
    }
}
