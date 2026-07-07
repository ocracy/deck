import Foundation

/// Claude Code hook'larını idempotent kurar: Claude oturumunun working/waiting
/// durumunu Deck'in izlediği per-sekme dosyaya köprüler.
///
/// Hook'lar `claude` prosesinin env'ini miras alır; Deck sekmeyi spawn ederken
/// `DECK_TAB_ID` / `DECK_TAB_NAME` / `DECK_PROJECT` enjekte eder. Deck dışında
/// `DECK_TAB_ID` boş olduğundan script no-op'tur — kullanıcının diğer Claude
/// oturumlarına sıfır yan etki.
enum HookInstaller {

    /// Event → hook script'ine geçen state argümanı.
    private static let eventStates: [(event: String, state: String)] = [
        ("UserPromptSubmit", "working"),
        ("PreToolUse",       "working"),
        ("PostToolUse",      "working"),
        ("SessionStart",     "working"),
        ("Stop",             "waiting"),
        ("Notification",     "waiting"),
        ("SessionEnd",       "end"),       // oturum kapandı → state dosyasını sil
    ]

    /// Script'i yaz + `~/.claude/settings.json`'a idempotent merge.
    static func installIfNeeded() {
        writeScript()
        mergeSettings()
    }

    // MARK: - script

    private static func writeScript() {
        let url = DeckPaths.hookScript
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try scriptBody.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: url.path)
        } catch {
            NSLog("[HookInstaller] writeScript failed: %@", "\(error)")
        }
    }

    private static let scriptBody = """
    #!/bin/sh
    # Deck <-> Claude Code bridge hook. Managed by Deck.app — do not edit.
    # Reports the Claude session's working/waiting state (and its claude
    # session_id, for resume) to a per-tab file Deck watches. No-op
    # outside Deck (DECK_TAB_ID unset), so it never affects other sessions.
    state="$1"

    # Read stdin (Claude pipes the event JSON) so its write never blocks; we
    # pull session_id out of it below.
    input=$(cat 2>/dev/null)

    [ -z "$DECK_TAB_ID" ] && exit 0

    dir="$HOME/Library/Application Support/Deck/claude-state"
    file="$dir/$DECK_TAB_ID.json"

    if [ "$state" = "end" ]; then
      rm -f "$file" 2>/dev/null
      exit 0
    fi

    mkdir -p "$dir" 2>/dev/null
    esc() { printf '%s' "$1" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'; }
    sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([0-9a-fA-F-]*\\)".*/\\1/p' | head -1)
    name=$(esc "$DECK_TAB_NAME")
    project=$(esc "$DECK_PROJECT")
    ts=$(date +%s)
    tmp="$file.$$.tmp"
    printf '{"state":"%s","name":"%s","project":"%s","sid":"%s","ts":%s}' \\
      "$state" "$name" "$project" "$sid" "$ts" > "$tmp" 2>/dev/null
    mv -f "$tmp" "$file" 2>/dev/null
    exit 0
    """

    // MARK: - settings.json merge

    private static func mergeSettings() {
        let url = DeckPaths.claudeSettings
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Parse edilemeyen settings.json'a dokunma (yorumlar / bozulma).
                NSLog("[HookInstaller] could not parse settings.json — skipping merge")
                return
            }
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let scriptPath = DeckPaths.hookScript.path
        var changed = false

        for (event, state) in eventStates {
            var entries = hooks[event] as? [[String: Any]] ?? []
            // İdempotent: bizim script'e işaret eden bir giriş varsa atla.
            let alreadyInstalled = entries.contains { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains("deck-hook.sh") == true }
            }
            if alreadyInstalled { continue }

            entries.append([
                "matcher": "",
                "hooks": [[
                    "type": "command",
                    "command": "\(scriptPath) \(state)",
                    "timeout": 5,
                    "async": true,
                ]],
            ])
            hooks[event] = entries
            changed = true
        }

        guard changed else { return }
        root["hooks"] = hooks

        do {
            let data = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            NSLog("[HookInstaller] merged Deck hooks into %@", url.path)
        } catch {
            NSLog("[HookInstaller] write settings.json failed: %@", "\(error)")
        }
    }
}
