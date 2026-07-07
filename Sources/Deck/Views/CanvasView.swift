import SwiftUI

struct CanvasView: View {
    let project: Project
    @ObservedObject var store: ProjectStore
    @ObservedObject var pm: ProcessManager
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var tabStore: ClaudeTabStore

    private struct EditorContext: Identifiable {
        let id = UUID()
        var item: CanvasItem?
        var spawn: CGPoint?
        var preset: ItemEditorKind = .service
    }

    @State private var editor: EditorContext?
    @State private var showResumeSheet = false
    @State private var hoveredItemID: UUID?
    @State private var draggingID: UUID?
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background(size: geo.size)
                ForEach(project.items) { item in
                    itemView(item, canvasSize: geo.size)
                        .position(position(for: item))
                }
            }
            .sheet(item: $editor) { ctx in
                ItemEditorSheet(project: project, item: ctx.item, presetKind: ctx.preset) { saved in
                    var out = saved
                    if ctx.item == nil {
                        let p = ctx.spawn ?? freeSpot(in: geo.size)
                        out.x = p.x
                        out.y = p.y
                    }
                    store.upsertItem(out, in: project.id)
                }
            }
            .sheet(isPresented: $showResumeSheet) {
                ClaudeResumeSheet(project: project) { opts in
                    ClaudeTabLauncher.open(project: project, workspace: workspace,
                                           tabStore: tabStore, pm: pm, resume: opts)
                }
            }
        }
        .clipped()
    }

    // MARK: - Zemin

    private func background(size: CGSize) -> some View {
        LinearGradient(colors: [Color(hex: "#101018"), Color(hex: "#1A1A28")],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    editor = EditorContext(item: nil, spawn: value.location)
                }
            )
            .contextMenu {
                Button("Yeni Servis") { newItem(.service, size: size) }
                Button("Yeni Komut") { newItem(.oneshot, size: size) }
                Button("Yeni Terminal") { newItem(.shell, size: size) }
                Button("Yeni Web") { newItem(.web, size: size) }
            }
    }

    private func newItem(_ preset: ItemEditorKind, size: CGSize) {
        editor = EditorContext(item: nil, spawn: freeSpot(in: size), preset: preset)
    }

    /// Mevcut ikonlarla çakışmayan ilk boş yuvayı bulur.
    private func freeSpot(in size: CGSize) -> CGPoint {
        let cols = max(1, Int((max(size.width, 300) - 100) / 110))
        for i in 0..<300 {
            let p = CGPoint(x: 96 + Double(i % cols) * 110,
                            y: 96 + Double(i / cols) * 124)
            let occupied = project.items.contains { abs($0.x - p.x) < 56 && abs($0.y - p.y) < 62 }
            if !occupied { return p }
        }
        return CGPoint(x: 120, y: 120)
    }

    // MARK: - İkon görünümü

    private func position(for item: CanvasItem) -> CGPoint {
        var p = CGPoint(x: item.x, y: item.y)
        if draggingID == item.id {
            p.x += dragOffset.width
            p.y += dragOffset.height
        }
        return p
    }

    @ViewBuilder
    private func itemView(_ item: CanvasItem, canvasSize: CGSize) -> some View {
        let isService = item.kind == .terminal && item.mode == .service
        let status = pm.status(of: item.id)

        VStack(spacing: 5) {
            IconView(spec: item.icon, size: 72)
                .overlay(alignment: .bottomTrailing) {
                    if isService {
                        Circle()
                            .fill(status.color)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
                            .offset(x: 3, y: 3)
                            .help(status.label)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.kind == .claude, waitingClaudeCount > 0 {
                        Text("\(waitingClaudeCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 7, y: -6)
                    }
                }

            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                .frame(maxWidth: 100)

            // Sabit yükseklikte kontrol yuvası: hover'da servis kontrolleri.
            ZStack {
                if isService, hoveredItemID == item.id, draggingID == nil {
                    HStack(spacing: 6) {
                        miniButton(status.isOwnedByDeck ? "stop.fill" : "play.fill",
                                   help: status.isOwnedByDeck ? "Durdur" : "Başlat") {
                            pm.toggleService(item, project: project)
                        }
                        miniButton("arrow.clockwise", help: "Yeniden başlat") {
                            pm.restartService(item, project: project)
                        }
                        if let port = item.port {
                            miniButton("bolt.slash.fill", help: "Portu boşalt (\(port))") {
                                pm.killPort(port, feedbackKey: item.id.uuidString)
                            }
                        }
                    }
                }
            }
            .frame(height: 22)
        }
        .frame(width: 108)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredItemID = item.id }
            else if hoveredItemID == item.id { hoveredItemID = nil }
        }
        .onTapGesture(count: 2) { doubleClick(item) }
        .gesture(dragGesture(item, canvasSize: canvasSize))
        .contextMenu { contextMenu(for: item, status: status) }
    }

    private func miniButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.15)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var waitingClaudeCount: Int {
        workspace.tabs(for: project.id).filter {
            $0.kind == .claude && pm.attention[$0.id] == .waiting
        }.count
    }

    // MARK: - Sürükleme

    private func dragGesture(_ item: CanvasItem, canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                draggingID = item.id
                dragOffset = value.translation
            }
            .onEnded { value in
                draggingID = nil
                dragOffset = .zero
                let maxX = max(60.0, canvasSize.width - 60)
                let maxY = max(56.0, canvasSize.height - 70)
                let nx = min(max(item.x + value.translation.width, 60), maxX)
                let ny = min(max(item.y + value.translation.height, 56), maxY)
                store.moveItem(item.id, in: project.id, to: CGPoint(x: nx, y: ny))
            }
    }

    // MARK: - Çift tık aksiyonları

    private func doubleClick(_ item: CanvasItem) {
        switch item.kind {
        case .claude:
            ClaudeTabLauncher.open(project: project, workspace: workspace, tabStore: tabStore, pm: pm)
        case .web:
            openWebTab(item)
        case .terminal:
            switch item.mode ?? .shell {
            case .service: openServiceTab(item, startIfStopped: true)
            case .oneshot: runOneshot(item)
            case .shell: openShellTab(item)
            }
        }
    }

    private func openServiceTab(_ item: CanvasItem, startIfStopped: Bool) {
        if startIfStopped, !pm.status(of: item.id).isRunning {
            pm.startService(item, project: project)
        }
        if let tab = workspace.tabs(for: project.id).first(where: { $0.kind == .service && $0.itemID == item.id }) {
            workspace.select(tab.id, in: project.id)
        } else {
            workspace.addTab(WorkspaceTab(kind: .service, title: item.name, itemID: item.id),
                             to: project.id, activate: true)
        }
        workspace.openWorkspace(project.id, true)
    }

    private func runOneshot(_ item: CanvasItem) {
        guard let command = item.command, !command.isEmpty else { return }
        let tab = WorkspaceTab(kind: .oneshot, title: item.name, itemID: item.id)
        workspace.addTab(tab, to: project.id, activate: true)
        pm.runOneshot(tabID: tab.id, command: command, cwd: item.cwd ?? project.path)
        workspace.openWorkspace(project.id, true)
    }

    private func openShellTab(_ item: CanvasItem) {
        if let tab = workspace.tabs(for: project.id).first(where: { $0.kind == .shell && $0.itemID == item.id }) {
            workspace.select(tab.id, in: project.id)
        } else {
            let tab = WorkspaceTab(kind: .shell, title: item.name, itemID: item.id)
            workspace.addTab(tab, to: project.id, activate: true)
            pm.startShell(tabID: tab.id, cwd: item.cwd ?? project.path)
        }
        workspace.openWorkspace(project.id, true)
    }

    private func openWebTab(_ item: CanvasItem) {
        if let tab = workspace.tabs(for: project.id).first(where: { $0.kind == .web && $0.itemID == item.id }) {
            workspace.select(tab.id, in: project.id)
        } else {
            workspace.addTab(WorkspaceTab(kind: .web, title: item.name, itemID: item.id, url: item.url),
                             to: project.id, activate: true)
        }
        workspace.openWorkspace(project.id, true)
    }

    // MARK: - Sağ tık menüleri

    @ViewBuilder
    private func contextMenu(for item: CanvasItem, status: ServiceStatus) -> some View {
        switch item.kind {
        case .claude:
            Button("Yeni Claude Sekmesi") {
                ClaudeTabLauncher.open(project: project, workspace: workspace, tabStore: tabStore, pm: pm)
            }
            Button("Geçmişi Sürdür...") { showResumeSheet = true }
            closedTabsMenu
        case .web:
            Button("Aç") { openWebTab(item) }
            Divider()
            editDeleteButtons(item)
        case .terminal:
            switch item.mode ?? .shell {
            case .service:
                Button("Aç") { openServiceTab(item, startIfStopped: false) }
                if status.isOwnedByDeck {
                    Button("Durdur") { pm.stopService(item) }
                } else {
                    Button("Başlat") { pm.startService(item, project: project) }
                }
                Button("Yeniden Başlat") { pm.restartService(item, project: project) }
                if let port = item.port {
                    Button("Portu Boşalt (\(port))") {
                        pm.killPort(port, feedbackKey: item.id.uuidString)
                    }
                }
                Divider()
                editDeleteButtons(item)
            case .oneshot:
                Button("Çalıştır") { runOneshot(item) }
                Divider()
                editDeleteButtons(item)
            case .shell:
                Button("Aç") { openShellTab(item) }
                Divider()
                editDeleteButtons(item)
            }
        }
    }

    @ViewBuilder
    private func editDeleteButtons(_ item: CanvasItem) -> some View {
        Button("Düzenle...") { editor = EditorContext(item: item, spawn: nil) }
        Button("Sil", role: .destructive) { deleteItem(item) }
    }

    @ViewBuilder
    private var closedTabsMenu: some View {
        let closedTabs = tabStore.closed[project.id] ?? []
        if !closedTabs.isEmpty {
            Divider()
            Menu("Kapatılmış Sekmeler") {
                ForEach(closedTabs) { ct in
                    Button(closedLabel(ct)) { reopenClosed(ct) }
                }
                Divider()
                Button("Listeyi Temizle") { tabStore.clearClosed(for: project.id) }
            }
        }
    }

    private func closedLabel(_ ct: ClaudeTabStore.ClosedTab) -> String {
        var label = ct.name ?? "Claude \(ct.number)"
        if let title = ct.title, !title.isEmpty {
            label += " — \(title)"
        }
        return label
    }

    private func reopenClosed(_ ct: ClaudeTabStore.ClosedTab) {
        tabStore.removeClosed(number: ct.number, for: project.id)
        let resume = ct.claudeSID.map { ClaudeResumeOptions(sessionID: $0) }
        ClaudeTabLauncher.open(project: project, workspace: workspace, tabStore: tabStore,
                               pm: pm, resume: resume, customName: ct.name)
    }

    private func deleteItem(_ item: CanvasItem) {
        if item.kind == .terminal, item.mode == .service, pm.status(of: item.id).isOwnedByDeck {
            pm.stopService(item)
        }
        for tab in workspace.tabs(for: project.id) where tab.itemID == item.id {
            pm.closeTab(tabID: tab.id, killTmux: false)
            workspace.closeTab(tab.id, in: project.id)
        }
        store.removeItem(item.id, from: project.id)
    }
}
