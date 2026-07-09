import SwiftUI
import AppKit

/// Editörde sunulan öğe türleri.
enum ItemEditorKind: String, CaseIterable, Identifiable {
    case claude, service, oneshot, shell, web

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .service: return "Service"
        case .oneshot: return "Command"
        case .shell: return "Terminal"
        case .web: return "Web"
        }
    }
}

struct ItemEditorSheet: View {
    let project: Project
    let item: CanvasItem?
    let onSave: (CanvasItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var kind: ItemEditorKind
    @State private var name: String
    @State private var command: String
    @State private var portText: String
    @State private var cwd: String
    @State private var autoStart: Bool
    @State private var urlText: String
    @State private var webIncognito: Bool
    @State private var icon: IconSpec
    @State private var iconCustomized: Bool
    @State private var showIconPicker = false

    init(project: Project,
         item: CanvasItem?,
         presetKind: ItemEditorKind = .service,
         onSave: @escaping (CanvasItem) -> Void) {
        self.project = project
        self.item = item
        self.onSave = onSave

        let k: ItemEditorKind
        if let item {
            switch item.kind {
            case .claude: k = .claude
            case .web: k = .web
            case .folder: k = .shell   // klasör editörde düzenlenmez
            case .terminal:
                switch item.mode ?? .shell {
                case .service: k = .service
                case .oneshot: k = .oneshot
                case .shell: k = .shell
                }
            }
        } else {
            k = presetKind
        }
        _kind = State(initialValue: k)
        _name = State(initialValue: item?.name ?? "")
        _command = State(initialValue: item?.command ?? "")
        _portText = State(initialValue: item?.port.map(String.init) ?? "")
        _cwd = State(initialValue: item?.cwd ?? "")
        _autoStart = State(initialValue: item?.autoStart ?? false)
        _urlText = State(initialValue: item?.url ?? "")
        _webIncognito = State(initialValue: item?.webIncognito ?? false)
        _icon = State(initialValue: item?.icon ?? Self.defaultIcon(for: k))
        _iconCustomized = State(initialValue: item != nil)
    }

    static func defaultIcon(for kind: ItemEditorKind) -> IconSpec {
        switch kind {
        case .claude: return .claude
        case .service: return IconSpec(symbol: "server.rack", isEmoji: false, colorHex: "#3DDC84")
        case .oneshot: return IconSpec(symbol: "bolt.fill", isEmoji: false, colorHex: "#F7B955")
        case .shell: return .defaultTerminal
        case .web: return .defaultWeb
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        guard !trimmedName.isEmpty else { return false }
        switch kind {
        case .service, .oneshot:
            return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .shell, .claude:
            return true
        case .web:
            return !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var hasInitialCommand: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item == nil ? "New Item" : "Edit Item")
                .font(.system(size: 15, weight: .semibold))

            Picker("", selection: $kind) {
                ForEach(ItemEditorKind.allCases) { k in
                    Text(k.label).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 10) {
                row("Name") {
                    TextField(placeholderName, text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                // Claude'un görseli markaya özel (sabit); diğerlerinde seçilebilir.
                if kind != .claude {
                    row("Icon") {
                        Button {
                            showIconPicker.toggle()
                        } label: {
                            HStack(spacing: 8) {
                                IconView(spec: icon, size: 34)
                                Text("Change")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showIconPicker, arrowEdge: .trailing) {
                            IconPicker(spec: $icon)
                        }
                    }
                }

                switch kind {
                case .claude:
                    row("Startup command") {
                        TextField("optional — empty opens Claude blank", text: $command)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    cwdRow
                    if hasInitialCommand {
                        row("") {
                            Toggle("Auto-run command on open", isOn: $autoStart)
                                .font(.system(size: 12))
                        }
                        row("") {
                            Text(autoStart
                                 ? "Claude opens and the command is sent immediately."
                                 : "The command is typed into the input box; press Enter to send.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                case .service:
                    commandRow
                    row("Port") {
                        TextField("optional", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text("for readiness check + KILL PORT")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    cwdRow
                    row("") {
                        Toggle("Auto-start when app opens", isOn: $autoStart)
                            .font(.system(size: 12))
                    }
                case .oneshot:
                    commandRow
                    cwdRow
                case .shell:
                    cwdRow
                case .web:
                    row("URL") {
                        TextField("http://localhost:3000", text: $urlText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    row("") {
                        Toggle("Open a fresh private session each time", isOn: $webIncognito)
                            .font(.system(size: 12))
                    }
                    row("") {
                        Text("No login is remembered — you sign in each time, isolated from other tabs.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onChange(of: kind) { _, newKind in
            if !iconCustomized { icon = Self.defaultIcon(for: newKind) }
        }
        .onChange(of: icon) { _, newIcon in
            if newIcon != Self.defaultIcon(for: kind) { iconCustomized = true }
        }
    }

    // MARK: - Satırlar

    private var placeholderName: String {
        switch kind {
        case .claude: return "e.g. Backend Claude"
        case .service: return "e.g. Dev Server"
        case .oneshot: return "e.g. Optimize"
        case .shell: return "e.g. Terminal"
        case .web: return "e.g. Preview"
        }
    }

    private var commandRow: some View {
        row("Command") {
            TextField(kind == .service ? "npm run dev" : "php artisan optimize", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private var cwdRow: some View {
        row("Working directory") {
            TextField("project root (empty) or relative to root: backend", text: $cwd)
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

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            content()
        }
    }

    // MARK: - Aksiyonlar

    private func pickDirectory() {
        let root = (project.path as NSString).expandingTildeInPath
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let start = cwd.isEmpty ? root : (cwd.hasPrefix("/") ? cwd : root + "/" + cwd)
        panel.directoryURL = URL(fileURLWithPath: start)
        if panel.runModal() == .OK, let url = panel.url {
            let picked = url.path
            // Proje kökünün içindeyse köke göre göreli sakla (taşınabilirlik +
            // spawn shell'inin doğru çözmesi için); dışındaysa mutlak bırak.
            if picked == root {
                cwd = ""
            } else if picked.hasPrefix(root + "/") {
                cwd = String(picked.dropFirst(root.count + 1))
            } else {
                cwd = picked
            }
        }
    }

    private func save() {
        var out = item ?? CanvasItem(kind: .terminal, name: "", icon: icon)
        out.name = trimmedName
        out.icon = icon

        switch kind {
        case .claude:
            out.kind = .claude
            out.mode = nil
            out.port = nil
            out.url = nil
            out.icon = .claude
            let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
            out.command = cmd.isEmpty ? nil : cmd          // initial_command
            out.autoStart = cmd.isEmpty ? false : autoStart // otomatik çalıştır (yalnız komut varsa)
            let dir = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            out.cwd = dir.isEmpty ? nil : dir
        case .web:
            out.kind = .web
            out.mode = nil
            out.command = nil
            out.port = nil
            out.autoStart = false
            out.cwd = nil
            out.webIncognito = webIncognito
            var u = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !u.contains("://") { u = "https://" + u }
            out.url = u
        case .service, .oneshot, .shell:
            out.kind = .terminal
            out.url = nil
            out.mode = kind == .service ? .service : (kind == .oneshot ? .oneshot : .shell)
            let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
            out.command = kind == .shell ? nil : cmd
            out.port = kind == .service ? Int(portText.trimmingCharacters(in: .whitespaces)) : nil
            out.autoStart = kind == .service ? autoStart : false
            let dir = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            out.cwd = dir.isEmpty ? nil : dir
        }

        onSave(out)
        dismiss()
    }
}
