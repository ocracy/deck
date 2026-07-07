import Foundation

/// Claude sekmelerini Deck'e özel, izole bir tmux sunucusunda çalıştırır
/// (sabit `-S` soketi + minimal config) — sekmeler uygulama kapansa da yaşar.
/// `-L` KULLANILMAZ: launchd ortamı ile login shell farklı TMUX_TMPDIR görür,
/// sabit `-S` yolu her çağıran için aynıdır.
///
/// Metadata tmux user option'ları olarak oturumda saklanır:
///   `@deck_project` (proje shortID), `@deck_num`, `@deck_name`, `@claude_sid`.
enum TmuxService {
    static let socketPath = "/tmp/deck-tmux-\(getuid()).sock"

    static var tmuxPath: String? {
        cachedTmuxPath
    }

    private static let cachedTmuxPath: String? = Shell.findExecutable([
        "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux",
        "/opt/local/bin/tmux", "/usr/bin/tmux",
    ])

    static var isAvailable: Bool { tmuxPath != nil }

    /// Minimal config'i yazar; sunucu zaten yaşıyorsa yeniden yükler.
    /// Mouse OFF: scroll'u Deck kendisi sürer (copy-mode), tmux mouse'u
    /// kaparsa SwiftTerm'de metin seçimi çalışmaz.
    static func ensureConfig() {
        let body = """
        set -g status off
        set -sg escape-time 0
        set -g default-terminal "screen-256color"
        set -as terminal-features ",*:RGB"
        set -g history-limit 50000
        set -g destroy-unattached off
        set -g mouse off
        set -g focus-events off
        set -g set-clipboard off
        set -g aggressive-resize off
        """
        try? body.write(to: DeckPaths.tmuxConfig, atomically: true, encoding: .utf8)
        if run(["list-sessions"]).status == 0 {
            _ = run(["source-file", DeckPaths.tmuxConfig.path])
        }
    }

    // MARK: - Sorgular / mutasyonlar

    struct Session: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let projectID: String
        let number: Int
        let customName: String?
        let claudeSID: String?
        let attached: Bool
    }

    /// Deck'e ait tüm oturumlar (`@deck_project` dolu olanlar).
    static func listSessions() -> [Session] {
        let fmt = "#{session_name}\t#{@deck_project}\t#{@deck_num}\t#{@deck_name}\t#{@claude_sid}\t#{session_attached}"
        let r = run(["list-sessions", "-F", fmt])
        guard r.status == 0 else { return [] }
        var result: [Session] = []
        for line in r.out.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 6, !f[1].isEmpty else { continue }
            result.append(Session(
                name: f[0],
                projectID: f[1],
                number: Int(f[2]) ?? 0,
                customName: f[3].isEmpty ? nil : f[3],
                claudeSID: f[4].isEmpty ? nil : f[4],
                attached: f[5] != "0"
            ))
        }
        return result
    }

    static func hasSession(_ name: String) -> Bool {
        run(["has-session", "-t", name]).status == 0
    }

    static func kill(_ name: String) {
        _ = run(["kill-session", "-t", name])
    }

    static func setOption(_ session: String, key: String, value: String) {
        _ = run(["set-option", "-t", session, key, value])
    }

    /// `[session_name: pane_title]` — Claude OSC ile kendi başlığını set eder.
    static func paneTitles() -> [String: String] {
        let r = run(["list-panes", "-a", "-F", "#{session_name}\t#{pane_title}"])
        guard r.status == 0 else { return [:] }
        var result: [String: String] = [:]
        for line in r.out.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 2 else { continue }
            result[f[0]] = f[1]
        }
        return result
    }

    /// Geçmişte gezinme: `copy-mode -e` en alta inince kendiliğinden çıkar,
    /// yazmaya kaldığı yerden devam edilir.
    static func scroll(_ session: String, lines: Int, up: Bool) {
        guard lines > 0 else { return }
        if up {
            _ = run(["copy-mode", "-e", "-t", session, ";",
                     "send-keys", "-t", session, "-X", "-N", "\(lines)", "scroll-up"])
        } else {
            _ = run(["send-keys", "-t", session, "-X", "-N", "\(lines)", "scroll-down"])
        }
    }

    // MARK: - Başlatma komutu

    /// `zsh -l -i -c` ile çalıştırılacak tam string:
    /// `exec '<tmux>' -S '<sock>' -f '<conf>' new-session -A -D -s '<name>' -x C -y R [-e K='v']... ['<inner>']`
    /// `-A -D`: oturum varsa bağlan (eski istemciyi düşür), yoksa `inner` ile yarat.
    static func attachCommand(session: String, cols: Int, rows: Int,
                              env: [String: String], inner: String?) -> String {
        let tmux = tmuxPath ?? "tmux"
        var parts = [
            "exec", Shell.singleQuoted(tmux),
            "-S", Shell.singleQuoted(socketPath),
            "-f", Shell.singleQuoted(DeckPaths.tmuxConfig.path),
            "new-session", "-A", "-D",
            "-s", Shell.singleQuoted(session),
            "-x", "\(cols)", "-y", "\(rows)",
        ]
        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            parts.append("-e")
            parts.append("\(k)=\(Shell.singleQuoted(v))")
        }
        if let inner {
            parts.append(Shell.singleQuoted(inner))
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Private

    @discardableResult
    private static func run(_ args: [String]) -> (status: Int32, out: String) {
        guard let tmux = tmuxPath else { return (-1, "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        p.arguments = ["-S", socketPath] + args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return (-1, "")
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
