import SwiftUI
import AppKit

struct HomeView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var pm: ProcessManager
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var router: AppRouter

    private enum HomeSheet: Identifiable {
        case new
        case edit(Project)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let p): return p.id.uuidString
            }
        }
    }

    @State private var sheet: HomeSheet?
    @State private var deleteCandidate: Project?
    @State private var showDeleteAlert = false
    @State private var hoveredCardID: UUID?
    @State private var showUpdatePopover = false
    @ObservedObject private var updater = UpdateChecker.shared

    private static let columns = [GridItem(.adaptive(minimum: 160, maximum: 160), spacing: 20, alignment: .top)]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#101018"), Color(hex: "#1A1A28")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            if store.projects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Projects")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 20) {
                            ForEach(store.projects) { project in
                                projectCard(project)
                            }
                            addCard
                        }
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            updateButton
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .new:
                ProjectEditorSheet(existing: nil) { name, path, icon in
                    var created = store.addProject(name: name, path: path)
                    created.icon = icon
                    store.updateProject(created)
                }
            case .edit(let p):
                ProjectEditorSheet(existing: p) { name, path, icon in
                    var updated = p
                    updated.name = name
                    updated.path = path
                    updated.icon = icon
                    store.updateProject(updated)
                }
            }
        }
        .alert("Delete Project", isPresented: $showDeleteAlert, presenting: deleteCandidate) { p in
            Button("Delete", role: .destructive) { performDelete(p) }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text("The project \"\(p.name)\" will be removed from Deck. Files on disk are left untouched.")
        }
    }

    // MARK: - Güncelleme (sağ üst)

    private var updateButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    showUpdatePopover = true
                } label: {
                    Image(systemName: updater.buttonSystemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(updater.buttonTint ?? Color.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                        .overlay(alignment: .topTrailing) {
                            if updater.hasAvailableUpdate {
                                Circle().fill(Color.orange)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 1, y: -1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(updater.buttonTooltip)
                .popover(isPresented: $showUpdatePopover, arrowEdge: .bottom) {
                    UpdateView(checker: updater)
                }
            }
            Spacer()
        }
        .padding(14)
    }

    // MARK: - Boş durum

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.3x3.topleft.filled")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Color(hex: "#5E8DF7"))
            Text("Welcome to Deck")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
            Text("Give every project its own desktop: services, terminals,\nweb previews, and Claude sessions in one place.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                sheet = .new
            } label: {
                Label("Create Your First Project", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
    }

    // MARK: - Kartlar

    private func projectCard(_ project: Project) -> some View {
        let running = runningServiceCount(project)
        let waiting = waitingClaudeCount(project)
        return VStack(spacing: 8) {
            IconView(spec: project.icon, size: 56)
                .overlay(alignment: .topTrailing) {
                    if waiting > 0 { badge(count: waiting) }
                }
            Text(project.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(abbreviatedPath(project.path))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if running > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("\(running) service")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 160, height: 140)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(hoveredCardID == project.id ? 0.1 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { inside in
            if inside { hoveredCardID = project.id }
            else if hoveredCardID == project.id { hoveredCardID = nil }
        }
        .onTapGesture { router.open(project.id) }
        .contextMenu {
            Button("Open") { router.open(project.id) }
            Button("Edit...") { sheet = .edit(project) }
            Divider()
            Button("Delete", role: .destructive) {
                deleteCandidate = project
                showDeleteAlert = true
            }
        }
    }

    private var addCard: some View {
        Button {
            sheet = .new
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                Text("New Project")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 160, height: 140)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15),
                                  style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func badge(count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red))
            .offset(x: 8, y: -6)
    }

    // MARK: - Yardımcılar

    private func runningServiceCount(_ project: Project) -> Int {
        project.items.filter {
            $0.kind == .terminal && $0.mode == .service && pm.status(of: $0.id).isRunning
        }.count
    }

    private func waitingClaudeCount(_ project: Project) -> Int {
        workspace.tabs(for: project.id).filter {
            $0.kind == .claude && pm.attention[$0.id] == .waiting
        }.count
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func performDelete(_ project: Project) {
        for item in project.items
        where item.kind == .terminal && item.mode == .service && pm.status(of: item.id).isOwnedByDeck {
            pm.stopService(item)
        }
        for tab in workspace.tabs(for: project.id) {
            pm.closeTab(tabID: tab.id, killTmux: tab.kind == .claude)
            workspace.closeTab(tab.id, in: project.id)
        }
        // Sekme listesine güvenme: proje hiç açılmadıysa tabs boştur ama
        // tmux oturumları yaşıyor olabilir — yetim oturum + hayalet rozet bırakma.
        let shortID = project.shortID
        Task.detached(priority: .utility) {
            for s in TmuxService.listSessions() where s.projectID == shortID {
                TmuxService.kill(s.name)
                let state = DeckPaths.claudeStateDir.appendingPathComponent("\(s.name).json")
                try? FileManager.default.removeItem(at: state)
            }
        }
        router.closeProject(project.id)
        store.deleteProject(project.id)
    }
}

// MARK: - Proje düzenleme sheet'i

private struct ProjectEditorSheet: View {
    let existing: Project?
    let onSave: (String, String, IconSpec) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var path: String
    @State private var icon: IconSpec
    @State private var showIconPicker = false

    init(existing: Project?, onSave: @escaping (String, String, IconSpec) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _path = State(initialValue: existing?.path ?? "")
        _icon = State(initialValue: existing?.icon ?? .defaultProject)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !path.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New Project" : "Edit Project")
                .font(.system(size: 15, weight: .semibold))

            HStack(spacing: 12) {
                Button {
                    showIconPicker.toggle()
                } label: {
                    IconView(spec: icon, size: 44)
                }
                .buttonStyle(.plain)
                .help("Change image")
                .popover(isPresented: $showIconPicker, arrowEdge: .trailing) {
                    IconPicker(spec: $icon)
                }

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Project name", text: $name)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 6) {
                        TextField("Project directory", text: $path)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Button {
                            pickDirectory()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Choose directory")
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(name.trimmingCharacters(in: .whitespaces),
                           path.trimmingCharacters(in: .whitespaces),
                           icon)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                name = url.lastPathComponent
            }
        }
    }
}
