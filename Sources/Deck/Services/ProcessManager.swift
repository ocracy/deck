import Foundation
import Combine
import Darwin
import AppKit
import SwiftTerm

/// tmux destekli terminallerde işaretleyici: `tmuxSession` doluysa scroll
/// monitörü wheel'i tmux copy-mode'a yönlendirir (scrollback tmux'tadır,
/// SwiftTerm yalnız tmux'un çizdiği tek ekranı görür).
final class DeckTerminalView: LocalProcessTerminalView {
    var tmuxSession: String?
}

/// Çekirdek runtime: SwiftTerm view cache'i + servis yaşam döngüsü +
/// Claude tmux oturumları + attention (hook köprüsü) izleyicisi.
@MainActor
final class ProcessManager: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published var statuses: [UUID: ServiceStatus] = [:]
    @Published var attention: [UUID: ClaudeAttention] = [:]
    @Published var paneTitles: [String: String] = [:]
    weak var projectStore: ProjectStore?
    weak var tabStore: ClaudeTabStore?
    weak var workspaceStore: WorkspaceStore?

    private var terminalViews: [String: DeckTerminalView] = [:]
    private var pendingRestart: [UUID: (item: CanvasItem, project: Project)] = [:]
    private var tabSIDs: [UUID: String] = [:]
    private var backgroundKeys: Set<String> = []
    private var backgroundNames: [String: String] = [:]
    /// startClaude çağrıldı ama process henüz running değil — çift spawn'ı önler.
    private var startingClaudeKeys: Set<String> = []
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var lastScrollSend = Date.distantPast
    private var stateWatcher: DispatchSourceFileSystemObject?
    private var statePollTimer: Timer?
    private var titleTimer: Timer?

    private lazy var spawnEnvironment: [String] = Self.buildSpawnEnvironment()

    override init() {
        super.init()
        TmuxService.ensureConfig()
        installKeyMonitor()
        installScrollMonitor()
        startStateWatching()
        startTitleTimer()
    }

    // MARK: - Terminal view cache

    func status(of itemID: UUID) -> ServiceStatus {
        statuses[itemID] ?? .stopped
    }

    /// Anahtar: servislerde item id, sekmelerde tab id (uuidString).
    /// View scrollback + imleç durumunun sahibidir; seçim değişse de yaşar.
    func terminalView(forKey key: String) -> DeckTerminalView {
        if let view = terminalViews[key] { return view }
        // Cömert başlangıç frame'i: SwiftTerm ilk spawn'da PTY winsize'ı
        // buradan hesaplar; 0×0 layout öncesi boyuta düşmesin.
        let view = DeckTerminalView(frame: NSRect(x: 0, y: 0, width: 1200, height: 720))
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0)
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        view.getTerminal().changeScrollback(10_000)
        terminalViews[key] = view
        return view
    }

    func hasTerminalView(forKey key: String) -> Bool {
        terminalViews[key] != nil
    }

    // MARK: - Servisler (doğrudan PTY)

    func startService(_ item: CanvasItem, project: Project) {
        guard let command = item.command, !command.isEmpty else { return }
        let key = item.id.uuidString
        let view = terminalView(forKey: key)
        if view.process.running { return }

        statuses[item.id] = .starting
        removeStateFile(key)

        let cwd = item.resolvedCwd(projectPath: project.path)
        feed(key: key, ansi: "\r\n\u{1B}[2m— starting: \(command) (dir: \(cwd)) —\u{1B}[0m\r\n")

        let cols = max(80, view.getTerminal().cols)
        let rows = max(24, view.getTerminal().rows)
        // stty: ilk spawn'da PTY winsize'ı içeriden yeniden damgalar;
        // SwiftTerm'in layout sonrası TIOCSWINSZ'i yine kazanır.
        let wrapped = "stty cols \(cols) rows \(rows) 2>/dev/null; cd \(Shell.singleQuoted(cwd)) && \(command)"

        var env = spawnEnvironment
        env.append("COLUMNS=\(cols)")
        env.append("LINES=\(rows)")
        env.append("DECK_TAB_ID=\(key)")
        env.append("DECK_TAB_NAME=\(item.name)")
        env.append("DECK_PROJECT=\(project.name)")

        view.startProcess(executable: "/bin/zsh",
                          args: ["-l", "-i", "-c", wrapped],
                          environment: env,
                          execName: nil)
        scheduleReadinessCheck(itemID: item.id, key: key, port: item.port)
    }

    /// Kibarca durdur: PTY'ye 0x03 (SIGINT) → 3sn → SIGTERM → 3sn → SIGKILL.
    /// Deck'in başlatmadığı (external) servislerde portu boşaltır.
    func stopService(_ item: CanvasItem) {
        let key = item.id.uuidString
        if let view = terminalViews[key], view.process.running {
            statuses[item.id] = .stopping
            let pid = view.process.shellPid
            view.process.send(data: ArraySlice([0x03]))
            afterMain(3) { [weak self] in
                guard let self, let v = self.terminalViews[key], v.process.running else { return }
                kill(pid, SIGTERM)
                self.afterMain(3) { [weak self] in
                    guard let self, let v = self.terminalViews[key], v.process.running else { return }
                    kill(pid, SIGKILL)
                }
            }
            return
        }

        if statuses[item.id] == .externalRunning, let port = item.port {
            statuses[item.id] = .stopping
            let itemID = item.id
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = Self.killPortSync(port)
                await MainActor.run { self?.statuses[itemID] = .stopped }
            }
        }
    }

    func restartService(_ item: CanvasItem, project: Project) {
        if let view = terminalViews[item.id.uuidString], view.process.running {
            pendingRestart[item.id] = (item, project)
            stopService(item)
        } else {
            startService(item, project: project)
        }
    }

    func toggleService(_ item: CanvasItem, project: Project) {
        if terminalViews[item.id.uuidString]?.process.running == true || statuses[item.id] == .externalRunning {
            stopService(item)
        } else {
            startService(item, project: project)
        }
    }

    /// Portu dinleyen her süreci öldürür (lsof | xargs kill -9).
    func killPort(_ port: Int, feedbackKey: String?) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let output = Self.killPortSync(port)
            guard let feedbackKey else { return }
            await MainActor.run {
                self?.feed(key: feedbackKey, ansi: "\r\n\u{1B}[33m[kill port :\(port)]\u{1B}[0m \(output)")
            }
        }
    }

    /// `stopped` görünen ama portu bağlı servisleri `.externalRunning` yapar.
    func scanExternalServices(projects: [Project]) {
        var candidates: [(id: UUID, port: Int)] = []
        for project in projects {
            for item in project.items where item.kind == .terminal && item.mode == .service {
                guard let port = item.port else { continue }
                if let view = terminalViews[item.id.uuidString], view.process.running { continue }
                switch statuses[item.id] {
                case .none, .stopped:
                    candidates.append((item.id, port))
                default:
                    break
                }
            }
        }
        guard !candidates.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let bound = candidates.filter { Self.isPortBound($0.port) }.map(\.id)
            guard !bound.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                for id in bound {
                    switch self.statuses[id] {
                    case .none, .stopped: self.statuses[id] = .externalRunning
                    default: break
                    }
                }
            }
        }
    }

    // MARK: - Sekme terminalleri

    func startShell(tabID: UUID, cwd: String) {
        let key = tabID.uuidString
        let view = terminalView(forKey: key)
        if view.process.running { return }
        let expanded = (cwd as NSString).expandingTildeInPath
        let cols = max(80, view.getTerminal().cols)
        let rows = max(24, view.getTerminal().rows)
        let wrapped = "stty cols \(cols) rows \(rows) 2>/dev/null; cd \(Shell.singleQuoted(expanded)) && exec /bin/zsh -l -i"
        var env = spawnEnvironment
        env.append("COLUMNS=\(cols)")
        env.append("LINES=\(rows)")
        view.startProcess(executable: "/bin/zsh",
                          args: ["-l", "-i", "-c", wrapped],
                          environment: env,
                          execName: nil)
    }

    /// Komutu görünmez bir PTY'de çalıştırır; bitince ses + bildirim verir ve
    /// terminali temizler. Sekme açılmaz — canvas'taki durum noktası yeter.
    func runBackground(_ item: CanvasItem, project: Project) {
        guard let command = item.command, !command.isEmpty else { return }
        let key = item.id.uuidString
        if terminalViews[key]?.process.running == true { return }
        backgroundKeys.insert(key)
        backgroundNames[key] = item.name
        statuses[item.id] = .running
        spawnPlain(key: key, command: command, cwd: item.resolvedCwd(projectPath: project.path))
    }

    func runOneshot(tabID: UUID, command: String, cwd: String) {
        let key = tabID.uuidString
        let view = terminalView(forKey: key)
        if view.process.running { return }
        let expanded = (cwd as NSString).expandingTildeInPath
        feed(key: key, ansi: "\r\n\u{1B}[2m— running: \(command) (dir: \(expanded)) —\u{1B}[0m\r\n")
        spawnPlain(key: key, command: command, cwd: cwd)
    }

    private func spawnPlain(key: String, command: String, cwd: String) {
        let view = terminalView(forKey: key)
        let expanded = (cwd as NSString).expandingTildeInPath
        let cols = max(80, view.getTerminal().cols)
        let rows = max(24, view.getTerminal().rows)
        let wrapped = "stty cols \(cols) rows \(rows) 2>/dev/null; cd \(Shell.singleQuoted(expanded)) && \(command)"
        var env = spawnEnvironment
        env.append("COLUMNS=\(cols)")
        env.append("LINES=\(rows)")
        env.append("DECK_TAB_ID=\(key)")
        view.startProcess(executable: "/bin/zsh",
                          args: ["-l", "-i", "-c", wrapped],
                          environment: env,
                          execName: nil)
    }

    /// tmux create-or-attach. `existingSession` doluysa o oturuma bağlanır
    /// (adopt); değilse tab id adıyla yeni oturum yaratılır. Oturum ölmüşse
    /// `-A` inner komutu çalıştırır, yani Claude yeniden başlar.
    func startClaude(tabID: UUID, project: Project, number: Int, customName: String?,
                     resume: ClaudeResumeOptions?, existingSession: String?,
                     initialCommand: String? = nil, autoRun: Bool = false,
                     cwdOverride: String? = nil) {
        let key = tabID.uuidString
        // Çift reattach koruması: bootstrap + ProjectView.onAppear ikisi de
        // reattach edebilir; process.running henüz true olmadan ikinci çağrı
        // aynı view'da ikinci PTY spawn edip tmux client'ını orphan bırakırdı.
        if startingClaudeKeys.contains(key) { return }
        let view = terminalView(forKey: key)
        if view.process.running { return }
        startingClaudeKeys.insert(key)
        // Reattach'te state dosyasını KORU: canlı oturumun "waiting" rozeti
        // açılışta hemen görünmeli (startStateWatching bilerek saklıyor).
        if existingSession == nil { removeStateFile(key) }

        let session = existingSession ?? key
        let rawCwd = cwdOverride.map { ($0 as NSString).expandingTildeInPath }
        let expandedCwd = rawCwd ?? (project.path as NSString).expandingTildeInPath
        let cols = max(80, view.getTerminal().cols)
        let rows = max(24, view.getTerminal().rows)
        let tabName = customName ?? "Claude \(number)"
        let hookEnv = ["DECK_TAB_ID": key,
                       "DECK_TAB_NAME": tabName,
                       "DECK_PROJECT": project.name]

        var env = spawnEnvironment
        env.append("COLUMNS=\(cols)")
        env.append("LINES=\(rows)")
        for (k, v) in hookEnv { env.append("\(k)=\(v)") }

        let trimmedInitial = initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command: String
        if let resume {
            command = ClaudeSessionService.resumeCommand(resume)
            tabSIDs[tabID] = resume.sessionID
        } else if let ic = trimmedInitial, !ic.isEmpty, autoRun {
            // Otomatik çalıştır: komut argüman olarak verilir, hemen işlenir.
            command = "claude \(Shell.singleQuoted(ic))"
        } else {
            command = "claude"
        }
        let inner = "cd \(Shell.singleQuoted(expandedCwd)) && exec \(command)"

        let wrapped: String
        if TmuxService.isAvailable {
            view.tmuxSession = session
            wrapped = TmuxService.attachCommand(session: session, cols: cols, rows: rows,
                                                env: hookEnv, inner: inner)
        } else {
            // tmux yoksa kalıcı olmayan düz spawn — uygulama yine çalışsın.
            wrapped = "stty cols \(cols) rows \(rows) 2>/dev/null; \(inner)"
        }
        view.startProcess(executable: "/bin/zsh",
                          args: ["-l", "-i", "-c", wrapped],
                          environment: env,
                          execName: nil)
        // Spawn tamamlandı; kısa süre sonra guard'ı kaldır (process.running
        // artık true; sonraki reattach oradan return eder).
        afterMain(1.0) { [weak self] in self?.startingClaudeKeys.remove(key) }

        // Otomatik çalıştır KAPALI + komut varsa: Claude arayüzü açıldıktan sonra
        // komutu girdi kutusuna yaz (Enter YOK — kullanıcı görüp kendi gönderir).
        if existingSession == nil, resume == nil, !autoRun,
           let ic = trimmedInitial, !ic.isEmpty {
            afterMain(1.6) { [weak self] in
                self?.sendInput(key: key, data: Array(ic.utf8))
            }
        } else if resume != nil, let ic = trimmedInitial, !ic.isEmpty {
            // Sürdürülen oturum (ör. "Kopyala → /branch"): geçmiş yüklenip TUI
            // hazır olunca komutu Enter'la (0x0D) gönder. Resume yavaş olabildiği
            // için gecikme daha uzun; tek gönderim (çoklu /branch dallanmasın).
            afterMain(3.0) { [weak self] in
                self?.sendInput(key: key, data: Array(ic.utf8) + [0x0D])
            }
        }

        if TmuxService.isAvailable {
            // Metadata'yı yalnız YENİ oturumda damgala; reattach'te zaten yazılı
            // (gereksiz senkron yük + @claude_sid'i ezme riski olmasın).
            if existingSession == nil {
                stampTmuxOptions(session: session,
                                 projectShortID: project.shortID,
                                 number: number,
                                 customName: customName,
                                 claudeSID: resume?.sessionID ?? tabSIDs[tabID])
            } else {
                // Attach sonrası boş ekran: winsize değişimi tmux istemcisine
                // SIGWINCH gönderir → tam yeniden çizim (softReset alt-screen'i bozar).
                for delay in [0.7, 1.6, 2.8] {
                    afterMain(delay) { [weak self] in self?.nudgeRedraw(key: key) }
                }
            }
        }
    }

    /// Hook'un yakaladığı claude oturum kimliği (resume için).
    func claudeSID(for tabID: UUID) -> String? {
        tabSIDs[tabID]
    }

    /// tmux'ta yaşayan Claude oturumlarını sekme olarak geri getirir ve
    /// hemen reattach eder — tek giriş noktası (bootstrap + ProjectView).
    func adoptClaudeTabs(for project: Project, workspace: WorkspaceStore, tabStore: ClaudeTabStore) {
        workspace.adoptTmuxSessions(for: project, tabStore: tabStore) { [weak self] tab in
            guard let self, !self.hasTerminalView(forKey: tab.id.uuidString) else { return }
            self.startClaude(tabID: tab.id, project: project, number: tab.number ?? 0,
                             customName: tab.customName, resume: nil,
                             existingSession: tab.tmuxSession)
        }
    }

    func closeTab(tabID: UUID, killTmux: Bool) {
        let key = tabID.uuidString
        var session: String? = nil
        if let view = terminalViews[key] {
            session = view.tmuxSession
            if view.process.running { kill(view.process.shellPid, SIGKILL) }
        }
        if killTmux, TmuxService.isAvailable {
            let name = session ?? key
            Task.detached(priority: .utility) { TmuxService.kill(name) }
        }
        terminalViews.removeValue(forKey: key)
        statuses.removeValue(forKey: tabID)
        pendingRestart.removeValue(forKey: tabID)
        tabSIDs.removeValue(forKey: tabID)
        removeStateFile(key)
        if attention.removeValue(forKey: tabID) != nil {
            updateBadge()
        }
    }

    func sendInput(key: String, data: [UInt8]) {
        guard let view = terminalViews[key], view.process.running else { return }
        view.process.send(data: ArraySlice(data))
    }

    /// SwiftTerm'in önbelleğini atıp tüm buffer'ı yeniden çizdirir.
    /// softReset scrollback'e DOKUNMAZ (reset ile karıştırma).
    func repaint(key: String) {
        guard let view = terminalViews[key] else { return }
        let terminal = view.getTerminal()
        let cols = max(1, terminal.cols)
        let rows = max(1, terminal.rows)
        view.resize(cols: cols, rows: rows)
        terminal.softReset()
        terminal.refresh(startRow: 0, endRow: rows)
        view.needsDisplay = true
    }

    // MARK: - Kapanış

    /// Güncelleme öncesi hızlı temizlik: timer/monitor/watcher'ları durdur ve
    /// yalnız tmux DESTEKLİ OLMAYAN (servis/shell/oneshot) PTY'leri öldür.
    /// Claude (tmux-backed) terminallere DOKUNMA — killpg(SIGKILL) bazı
    /// makinelerde (server henüz daemonize olmadan client'ın process grubundayken)
    /// tmux server'ını da düşürüp oturumları yok edebiliyor. Bunlar uygulama
    /// kapanınca doğal SIGHUP ile detach olur, oturum server'da yaşar ve sonraki
    /// açılışta reattach edilir.
    func prepareForShutdown() {
        titleTimer?.invalidate(); titleTimer = nil
        statePollTimer?.invalidate(); statePollTimer = nil
        stateWatcher?.cancel(); stateWatcher = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        for (key, view) in terminalViews where view.tmuxSession == nil {
            if view.process.running { _ = killpg(view.process.shellPid, SIGKILL) }
            terminalViews.removeValue(forKey: key)
        }
    }

    /// Uygulama çıkarken senkron temizlik. tmux destekli terminaller HARİÇ:
    /// onların PTY'si kapanınca tmux istemcisi düşer, oturum yaşamaya devam eder.
    func terminateAllSync() {
        let running = terminalViews.values.filter { $0.process.running && $0.tmuxSession == nil }
        guard !running.isEmpty else { return }

        for view in running {
            let pid = view.process.shellPid
            view.process.send(data: ArraySlice([0x03]))   // PTY Ctrl+C → fg pgrp'a SIGINT
            _ = killpg(pid, SIGTERM)
        }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if running.allSatisfy({ !$0.process.running }) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }

        for view in running where view.process.running {
            _ = killpg(view.process.shellPid, SIGKILL)
        }
    }

    // MARK: - Ortam

    private nonisolated static func buildSpawnEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.userPath
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // Claude Code'un SwiftTerm'in kötü parse ettiği "flicker-free"
        // renderer'ını kapalı tut; açık `=0` yokluktan daha güçlü sinyal.
        env["TERM_PROGRAM"] = "Deck"
        env["CLAUDE_CODE_NO_FLICKER"] = "0"
        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - Readiness

    private func scheduleReadinessCheck(itemID: UUID, key: String, port: Int?) {
        let started = Date()
        let portTimeout: TimeInterval = 30
        let noPortGrace: TimeInterval = 1.5
        let pollInterval: TimeInterval = 0.3

        func tick() {
            guard let view = self.terminalViews[key], view.process.running else { return }
            guard self.statuses[itemID] == .starting else { return }

            if let port {
                if Self.isPortBound(port) {
                    self.statuses[itemID] = .running
                    self.feed(key: key, ansi: "\u{1B}[32m[ready]\u{1B}[0m :\(port) listening\r\n")
                    return
                }
                if Date().timeIntervalSince(started) > portTimeout {
                    self.statuses[itemID] = .running
                    self.feed(key: key, ansi: "\u{1B}[33m[ready]\u{1B}[0m :\(port) timeout waiting — assumed running\r\n")
                    return
                }
            } else if Date().timeIntervalSince(started) >= noPortGrace {
                self.statuses[itemID] = .running
                return
            }
            self.afterMain(pollInterval) { tick() }
        }
        afterMain(pollInterval) { tick() }
    }

    private nonisolated static func isPortBound(_ port: Int) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        _ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                Darwin.connect(sock, sptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private nonisolated static func killPortSync(_ port: Int) -> String {
        let r = Shell.run("/bin/sh", ["-c",
            "PIDS=$(lsof -ti tcp:\(port) 2>/dev/null); if [ -n \"$PIDS\" ]; then echo \"killing: $PIDS\"; echo $PIDS | xargs kill -9; else echo \"no process on :\(port)\"; fi"])
        return r.output
    }

    // MARK: - tmux metadata

    /// Oturum metadata'sını damgalar; `new-session` PTY içinde asenkron
    /// koştuğu için oturum görünene dek arka planda dener.
    private func stampTmuxOptions(session: String, projectShortID: String, number: Int,
                                  customName: String?, claudeSID: String?) {
        Task.detached(priority: .utility) {
            for _ in 0..<40 {
                if TmuxService.hasSession(session) {
                    TmuxService.setOption(session, key: "@deck_project", value: projectShortID)
                    TmuxService.setOption(session, key: "@deck_num", value: "\(number)")
                    TmuxService.setOption(session, key: "@deck_name", value: customName ?? "")
                    if let sid = claudeSID, !sid.isEmpty {
                        TmuxService.setOption(session, key: "@claude_sid", value: sid)
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Kısa winsize değişimi (±1 satır) tmux istemcisini tam repaint'e zorlar.
    private func nudgeRedraw(key: String) {
        guard let view = terminalViews[key], view.process.running else { return }
        let t = view.getTerminal()
        let c = max(4, t.cols)
        let r = max(4, t.rows)
        view.resize(cols: c, rows: r - 1)
        afterMain(0.12) { [weak self] in
            guard let self, let v = self.terminalViews[key], v.process.running else { return }
            v.resize(cols: c, rows: r)
        }
    }

    // MARK: - Pane başlıkları (2sn timer)

    private func startTitleTimer() {
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPaneTitles() }
        }
        RunLoop.main.add(timer, forMode: .common)
        titleTimer = timer
    }

    private func refreshPaneTitles() {
        guard TmuxService.isAvailable,
              terminalViews.values.contains(where: { $0.tmuxSession != nil }) else { return }
        Task.detached(priority: .utility) { [weak self] in
            let raw = TmuxService.paneTitles()
            var clean: [String: String] = [:]
            for (session, title) in raw {
                let t = Self.cleanPaneTitle(title)
                if !t.isEmpty { clean[session] = t }
            }
            await MainActor.run {
                guard let self, self.paneTitles != clean else { return }
                self.paneTitles = clean
            }
        }
    }

    /// Baştaki durum glifini (spinner, ✳ …) at; jenerik shell adlarını yok say.
    private nonisolated static func cleanPaneTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = s.first, !f.isLetter, !f.isNumber { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic: Set<String> = ["claude", "claude.exe", "zsh", "-zsh", "bash", "sh", "node", "tmux"]
        return generic.contains(s.lowercased()) ? "" : s
    }

    // MARK: - Attention watcher (claude-state hook köprüsü)

    private func startStateWatching() {
        let dir = DeckPaths.claudeStateDir
        let fm = FileManager.default
        // Ölü oturumların bayat dosyalarını sil; tmux'ta hâlâ yaşayanları
        // KORU ki bekleyen Claude açılışta hemen rozet göstersin.
        let liveIDs = Set(TmuxService.isAvailable ? TmuxService.listSessions().map(\.name) : [])
        if let leftovers = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in leftovers where f.pathExtension == "json" {
                let id = f.deletingPathExtension().lastPathComponent
                if !liveIDs.contains(id) { try? fm.removeItem(at: f) }
            }
        }

        // Anında tepki: dizin vnode kaynağı…
        let fd = open(dir.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                queue: .main
            )
            src.setEventHandler { [weak self] in
                Task { @MainActor in self?.rescanState() }
            }
            src.setCancelHandler { close(fd) }
            stateWatcher = src
            src.resume()
        }

        // …artı 1sn poll: atomik mv rename'leri tek vnode kaynağını kaçırabilir.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescanState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statePollTimer = timer

        rescanState()
    }

    private func rescanState() {
        let dir = DeckPaths.claudeStateDir
        var next: [UUID: ClaudeAttention] = [:]
        var meta: [UUID: (name: String, project: String)] = [:]

        if let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent),
                      let data = try? Data(contentsOf: f),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let state = obj["state"] as? String else { continue }
                next[id] = (state == "waiting") ? .waiting : .working
                meta[id] = (obj["name"] as? String ?? "", obj["project"] as? String ?? "")
                if let sid = obj["sid"] as? String, !sid.isEmpty {
                    recordClaudeSID(tabID: id, sid: sid)
                }
            }
        }

        guard next != attention else { return }

        // Notify only on the transition INTO waiting (session went idle). Sound
        // is played directly via NSSound (osascript's sound can be muted by the
        // user's notification settings). Gated by per-project settings.
        for (id, state) in next where state == .waiting && attention[id] != .waiting {
            let m = meta[id]
            let projectName = m?.project ?? ""
            let settings = settingsForProject(named: projectName)
            let title = projectName.isEmpty ? "Deck" : projectName
            if settings.soundOnSessionEnd {
                NotificationService.playSound(settings.soundName)
            }
            if settings.notifyOnSessionEnd {
                // Canlı sekme adını (kullanıcı yeniden adlandırdıysa) tercih et;
                // hook'un yazdığı `name` spawn anındaki DECK_TAB_NAME'de donmuştur.
                let liveName = workspaceStore?.displayName(forTab: id)
                NotificationService.notify(title: title,
                                           subtitle: liveName ?? m?.name ?? "",
                                           body: "Claude is waiting for you",
                                           sound: "")
            }
        }
        attention = next
        updateBadge()
    }

    /// Looks up a project's settings by its display name (DECK_PROJECT from the
    /// hook). Falls back to defaults if not found.
    private func settingsForProject(named name: String) -> ProjectSettings {
        projectStore?.projects.first { $0.name == name }?.settings ?? ProjectSettings()
    }

    private func updateBadge() {
        NotificationService.setBadge(attention.values.filter { $0 == .waiting }.count)
    }

    private func recordClaudeSID(tabID: UUID, sid: String) {
        guard tabSIDs[tabID] != sid else { return }
        tabSIDs[tabID] = sid
        guard TmuxService.isAvailable else { return }
        let session = terminalViews[tabID.uuidString]?.tmuxSession ?? tabID.uuidString
        Task.detached(priority: .utility) {
            if TmuxService.hasSession(session) {
                TmuxService.setOption(session, key: "@claude_sid", value: sid)
            }
        }
    }

    private func removeStateFile(_ key: String) {
        let file = DeckPaths.claudeStateDir.appendingPathComponent("\(key).json")
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Event monitörleri

    /// SwiftTerm'in `keyDown`'ı override edilemiyor (open değil); Shift+Enter /
    /// Option+Enter'ı iTerm2 gibi üretmek için lokal monitör.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let view = NSApp.keyWindow?.firstResponder as? LocalProcessTerminalView,
                      event.keyCode == 36 || event.keyCode == 76 else { return false }
                if event.modifierFlags.contains(.shift) {
                    view.process.send(data: ArraySlice([0x5C, 0x0D]))   // "\<CR>"
                    return true
                }
                if event.modifierFlags.contains(.option) {
                    view.process.send(data: ArraySlice([0x1B, 0x0D]))   // ESC+CR
                    return true
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    /// tmux destekli terminalde wheel'i copy-mode'a yönlendirir ve event'i
    /// yutar; diğer terminaller SwiftTerm'in normal scrollback'ini kullanır.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self,
                      event.scrollingDeltaY != 0,
                      let hit = event.window?.contentView?.hitTest(event.locationInWindow),
                      let term = Self.enclosingDeckTerminal(hit),
                      let session = term.tmuxSession else {
                    return false
                }
                let now = Date()
                if now.timeIntervalSince(self.lastScrollSend) >= 0.03 {
                    self.lastScrollSend = now
                    let up = event.scrollingDeltaY > 0
                    DispatchQueue.global(qos: .userInteractive).async {
                        TmuxService.scroll(session, lines: 3, up: up)
                    }
                }
                return true   // event'i yut — SwiftTerm'in boş scroll'u çalışmasın
            }
            return consumed ? nil : event
        }
    }

    private static func enclosingDeckTerminal(_ view: NSView) -> DeckTerminalView? {
        var v: NSView? = view
        while let cur = v {
            if let term = cur as? DeckTerminalView { return term }
            v = cur.superview
        }
        return nil
    }

    // MARK: - Yardımcılar

    private func feed(key: String, ansi: String) {
        terminalView(forKey: key).feed(text: ansi)
    }

    private func afterMain(_ delay: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            block()
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // LocalProcessTerminalView TIOCSWINSZ'i kendisi çağırıyor.
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Başlıklar tmux pane_title'dan okunuyor.
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let code = exitCode ?? -1
        Task { @MainActor [weak self] in
            guard let self,
                  let view = source as? DeckTerminalView,
                  let key = self.terminalViews.first(where: { $0.value === view })?.key else { return }
            self.handleExit(key: key, code: code)
        }
    }

    private func handleExit(key: String, code: Int32) {
        startingClaudeKeys.remove(key)
        feed(key: key, ansi: "\r\n\u{1B}[2m— done (code \(code)) —\u{1B}[0m\r\n")
        removeStateFile(key)
        guard let uuid = UUID(uuidString: key) else { return }
        statuses[uuid] = (code == 0) ? .stopped : .crashed(exitCode: code)

        // Arka plan komutu: kullanıcıya haber ver, görünmez terminali bırakma.
        if backgroundKeys.remove(key) != nil {
            let name = backgroundNames.removeValue(forKey: key) ?? "Command"
            NotificationService.playSound(code == 0 ? "Glass" : "Basso")
            NotificationService.notify(title: name,
                                       subtitle: "",
                                       body: code == 0 ? "Background command finished"
                                                       : "Command exited with an error (code \(code))",
                                       sound: "")
            terminalViews.removeValue(forKey: key)
        }
        if attention.removeValue(forKey: uuid) != nil {
            updateBadge()
        }
        if let pending = pendingRestart.removeValue(forKey: uuid) {
            afterMain(0.2) { [weak self] in
                self?.startService(pending.item, project: pending.project)
            }
        }
    }
}
