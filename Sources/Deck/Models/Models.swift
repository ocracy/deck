import Foundation
import SwiftUI

// MARK: - Icon

struct IconSpec: Codable, Equatable, Hashable {
    var symbol: String
    var isEmoji: Bool
    var colorHex: String

    static let defaultProject = IconSpec(symbol: "folder.fill", isEmoji: false, colorHex: "#5E8DF7")
    static let claude = IconSpec(symbol: "✳️", isEmoji: true, colorHex: "#D97757")
    static let defaultTerminal = IconSpec(symbol: "terminal.fill", isEmoji: false, colorHex: "#3DDC84")
    static let defaultWeb = IconSpec(symbol: "globe", isEmoji: false, colorHex: "#38BDF8")
    static let defaultFolder = IconSpec(symbol: "folder.fill", isEmoji: false, colorHex: "#E8B84B")
}

// MARK: - Canvas Item

enum ItemKind: String, Codable {
    case claude, terminal, web, folder
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
    /// İçinde bulunduğu klasör (yalnız servisler klasöre girebilir; klasörler hep kökte).
    var parentID: UUID?

    // terminal
    var command: String?
    var mode: TerminalMode?
    var port: Int?
    var autoStart: Bool = false
    var cwd: String?

    // web
    var url: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, name, icon, x, y, parentID, command, mode, port, autoStart, cwd, url
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
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
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
    case stopped, starting, running, externalRunning, stopping
    case crashed(exitCode: Int32)

    var isRunning: Bool {
        switch self {
        case .running, .starting, .stopping, .externalRunning: return true
        case .stopped, .crashed: return false
        }
    }

    /// Deck'in kendi PTY'sinde mi çalışıyor (external değil)?
    var isOwnedByDeck: Bool {
        switch self {
        case .running, .starting, .stopping: return true
        default: return false
        }
    }

    var color: Color {
        switch self {
        case .running: return .green
        case .externalRunning: return Color(red: 0.55, green: 0.85, blue: 0.55)
        case .starting, .stopping: return .yellow
        case .stopped: return .gray
        case .crashed: return .red
        }
    }

    var label: String {
        switch self {
        case .stopped: return "durduruldu"
        case .starting: return "başlıyor"
        case .running: return "çalışıyor"
        case .externalRunning: return "dışarıda çalışıyor"
        case .stopping: return "durduruluyor"
        case .crashed(let code): return "çöktü (\(code))"
        }
    }
}

enum ClaudeAttention: Equatable {
    case working, waiting
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
    var number: Int?            // claude sekme numarası ("Claude N")
    var customName: String?     // kullanıcının verdiği ad (pane title'ı ezer)

    init(id: UUID = UUID(), kind: TabKind, title: String, tmuxSession: String? = nil,
         itemID: UUID? = nil, url: String? = nil, number: Int? = nil, customName: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.tmuxSession = tmuxSession
        self.itemID = itemID
        self.url = url
        self.number = number
        self.customName = customName
    }
}

/// ~/.claude/projects altından keşfedilen geçmiş Claude oturumu.
struct ClaudeSession: Identifiable, Equatable {
    let id: String          // sessionId (uuid)
    var summary: String
    var lastActivity: Date
    var fileSizeBytes: Int64
}

// MARK: - Renk yardımcıları

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

extension IconSpec {
    var color: Color { Color(hex: colorHex) }
}
