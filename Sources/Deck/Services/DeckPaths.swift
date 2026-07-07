import Foundation

/// Deck'in disk üzerindeki sabit yolları. `appSupport` ve `claudeStateDir`
/// ilk erişimde oluşturulur.
enum DeckPaths {
    static let appSupport: URL = {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deck", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let projectsFile: URL = appSupport.appendingPathComponent("projects.json")

    static let claudeTabsFile: URL = appSupport.appendingPathComponent("claude-tabs.json")

    /// Hook script'inin yazdığı `<tabID>.json` durum dosyaları.
    static let claudeStateDir: URL = {
        let url = appSupport.appendingPathComponent("claude-state", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let tmuxConfig: URL = appSupport.appendingPathComponent("deck-tmux.conf")

    static let hookScript: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/hooks/deck-hook.sh")

    static let claudeSettings: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/settings.json")
}
