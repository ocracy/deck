import Foundation

/// Claude Code'un diskteki oturum deposunu okur:
/// `~/.claude/projects/{encoded-cwd}/{session-uuid}.jsonl`.
/// CLI makine-okunur bir "list sessions" komutu sunmadığı için resume listesi
/// buradan üretilir; devam etmenin resmi yolu `claude --resume <id>`.
enum ClaudeSessionService {

    // MARK: - Path

    /// Mutlak cwd → `~/.claude/projects/...` dizin adı. Tilde açılır, tüm '/' → '-'.
    static func encodedProjectPath(forCwd cwd: String) -> String {
        let expanded = (cwd as NSString).expandingTildeInPath
        return expanded.replacingOccurrences(of: "/", with: "-")
    }

    static func sessionsDirectory(forCwd cwd: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encodedProjectPath(forCwd: cwd), isDirectory: true)
    }

    // MARK: - Scan

    /// Oturum dosyalarını tara. Adı geçerli UUID olmayan dosyalar sessizce atlanır.
    /// mtime'a göre yeni → eski sıralı. Arka planda çağrılmak üzere sync API.
    static func scan(cwd: String) -> [ClaudeSession] {
        let dir = sessionsDirectory(forCwd: cwd)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }

        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let results: [ClaudeSession] = urls.compactMap { url in
            guard url.pathExtension == "jsonl" else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: stem) != nil else { return nil }

            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let preview = firstUserMessage(at: url) ?? ""
            return ClaudeSession(id: stem,
                                 summary: preview,
                                 lastActivity: mtime,
                                 fileSizeBytes: size)
        }

        return results.sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: - Resume komutu

    /// zsh'a verilecek komut: `claude --resume '<id>' [--fork-session] ['<prompt>']`.
    static func resumeCommand(_ opts: ClaudeResumeOptions) -> String {
        var parts: [String] = ["claude", "--resume", Shell.singleQuoted(opts.sessionID)]
        if opts.fork {
            parts.append("--fork-session")
        }
        if let prompt = opts.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            parts.append(Shell.singleQuoted(prompt))
        }
        return parts.joined(separator: " ")
    }

    // MARK: - JSONL önizleme

    /// JSONL'i satır satır yürüyüp kullanıcı mesajlarını topla; sistem zarfı
    /// (`<command-message>` vb.) olmayan ilkini döndür. Hepsi zarfsa ilkinin
    /// tag'leri sökülmüş hali. ~10 aday veya 4 MB'ta durur.
    private static func firstUserMessage(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let decoder = JSONDecoder()
        let chunkSize = 64 * 1024
        var leftover = Data()
        var scanned = 0
        let maxScan = 4 * 1024 * 1024
        let maxCandidates = 10
        var candidates: [String] = []

        func process(_ lineData: Data) -> Bool {
            guard let raw = decodeUserMessage(lineData, decoder: decoder) else { return false }
            candidates.append(raw)
            return candidates.count >= maxCandidates
        }

        outer: while scanned < maxScan {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            scanned += chunk.count
            leftover.append(chunk)
            let newline: UInt8 = 0x0A
            while let nlIndex = leftover.firstIndex(of: newline) {
                let lineData = leftover.subdata(in: 0..<nlIndex)
                leftover.removeSubrange(0...nlIndex)
                if process(lineData) { break outer }
            }
        }
        if candidates.count < maxCandidates, !leftover.isEmpty {
            _ = process(leftover)
        }

        if let plain = candidates.first(where: { !looksLikeSystemEnvelope($0) }) {
            return truncatePreview(plain)
        }
        if let first = candidates.first {
            let cleaned = stripSystemEnvelopeTags(first)
            return cleaned.isEmpty ? nil : truncatePreview(cleaned)
        }
        return nil
    }

    private static func decodeUserMessage(_ data: Data, decoder: JSONDecoder) -> String? {
        guard !data.isEmpty,
              let env = try? decoder.decode(UserEnvelope.self, from: data),
              env.type == "user" else {
            return nil
        }
        let raw = env.message.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    /// Claude Code slash-komut ve diğer insan-dışı turları tag'lerle sarar;
    /// bunlar önizleme için gürültüdür.
    private static func looksLikeSystemEnvelope(_ s: String) -> Bool {
        let lower = s.lowercased()
        let markers = [
            "<command-message",
            "<command-name",
            "<command-args",
            "<command-stdout",
            "<command-stderr",
            "<local-command",
            "<system-reminder",
            "<bash-input"
        ]
        return markers.contains(where: lower.hasPrefix)
    }

    /// `<command-name>/foo</command-name>` → `/foo` gibi; tag'leri söker.
    private static func stripSystemEnvelopeTags(_ s: String) -> String {
        let pattern = "<[^>]+>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        let stripped = regex.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
        return stripped
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncatePreview(_ s: String) -> String {
        let collapsed = s
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if collapsed.count <= 200 { return collapsed }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: 200)
        return String(collapsed[..<cutoff]) + "…"
    }

    // MARK: - JSONL zarf modelleri

    private struct UserEnvelope: Decodable {
        let type: String
        let message: MessageBody
    }

    private struct MessageBody: Decodable {
        let content: FlexibleContent
    }

    /// `content` ya düz string ya da content-block dizisidir; yalnız text alınır.
    private struct FlexibleContent: Decodable {
        let text: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                self.text = single
                return
            }
            let blocks = (try? container.decode([Block].self)) ?? []
            self.text = blocks.compactMap(\.text).joined(separator: " ")
        }

        private struct Block: Decodable {
            let type: String
            let text: String?
        }
    }
}

struct ClaudeResumeOptions: Equatable {
    var sessionID: String
    var fork: Bool = false
    var initialPrompt: String? = nil
}
