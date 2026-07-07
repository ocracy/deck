import Foundation

// MARK: - Icon

struct IconSpec: Codable, Equatable, Hashable {
    var symbol: String
    var isEmoji: Bool
    var colorHex: String

    static let defaultProject = IconSpec(symbol: "folder.fill", isEmoji: false, colorHex: "#5E8DF7")
    static let claude = IconSpec(symbol: "✳️", isEmoji: true, colorHex: "#D97757")
    static let defaultTerminal = IconSpec(symbol: "terminal.fill", isEmoji: false, colorHex: "#3DDC84")
    static let defaultWeb = IconSpec(symbol: "globe", isEmoji: false, colorHex: "#38BDF8")
}

// MARK: - Canvas Item

enum ItemKind: String, Codable {
    case claude, terminal, web
}

enum TerminalMode: String, Codable {
    case service, oneshot, shell
}

struct CanvasItem: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: ItemKind
    var name: String
    var icon: IconSpec
    var x: Double = 40
    var y: Double = 40

    // terminal
    var command: String?
    var mode: TerminalMode?
    var port: Int?
    var autoStart: Bool = false
    var cwd: String?

    // web
    var url: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, name, icon, x, y, command, mode, port, autoStart, cwd, url
    }

    init(kind: ItemKind, name: String, icon: IconSpec) {
        self.kind = kind
        self.name = name
        self.icon = icon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(ItemKind.self, forKey: .kind) ?? .terminal
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Adsız"
        icon = try c.decodeIfPresent(IconSpec.self, forKey: .icon) ?? .defaultTerminal
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 40
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 40
        command = try c.decodeIfPresent(String.self, forKey: .command)
        mode = try c.decodeIfPresent(TerminalMode.self, forKey: .mode)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        url = try c.decodeIfPresent(String.self, forKey: .url)
    }
}

// MARK: - Project

struct Project: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var path: String
    var icon: IconSpec = .defaultProject
    var items: [CanvasItem] = []

    /// tmux oturum adlarında kullanılan kısa kimlik.
    var shortID: String { String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased() }

    enum CodingKeys: String, CodingKey { case id, name, path, icon, items }

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Proje"
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? NSHomeDirectory()
        icon = try c.decodeIfPresent(IconSpec.self, forKey: .icon) ?? .defaultProject
        items = try c.decodeIfPresent([CanvasItem].self, forKey: .items) ?? []
    }
}

// MARK: - Runtime (persist edilmez)

enum ServiceStatus: Equatable {
    case stopped, starting, running, stopping, crashed
}

enum TabKind: Equatable {
    case claude, shell, oneshot, service, web
}

/// Workspace'te açık bir sekme. Terminal sekmeleri tmux oturumuna bağlıdır.
struct WorkspaceTab: Identifiable, Equatable {
    let id: UUID
    var kind: TabKind
    var title: String
    var tmuxSession: String?
    var itemID: UUID?
    var url: String?

    init(kind: TabKind, title: String, tmuxSession: String? = nil, itemID: UUID? = nil, url: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.tmuxSession = tmuxSession
        self.itemID = itemID
        self.url = url
    }
}

/// ~/.claude/projects altından keşfedilen geçmiş Claude oturumu.
struct ClaudeSession: Identifiable, Equatable {
    let id: String          // sessionId
    var summary: String
    var lastActivity: Date
}
