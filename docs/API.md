# Deck — API Sözleşmesi (implementasyon kontratı)

Bu dosya paralel yazılan dosyaların birbirine uymasını sağlayan KESİN sözleşmedir.
İmzaları birebir uygula; ekleme yapabilirsin ama burada geçen isim/imzaları DEĞİŞTİRME.
Modeller `Sources/Deck/Models/Models.swift` içinde HAZIR (Project, IconSpec, CanvasItem,
ItemKind, TerminalMode, ServiceStatus, TabKind, WorkspaceTab, ClaudeSession) — oku ve kullan.

Genel kurallar:
- Swift 5.9, macOS 14+, tek modül `Deck`. Dış bağımlılık yalnız SwiftTerm.
- UI metinleri Türkçe; kod tanımlayıcıları İngilizce. Yorum yalnız gerekli yerde.
- Tüm ObservableObject'ler `@MainActor`. Disk/proses işleri arka planda, @Published güncellemeleri main'de.

## ServiceStatus — Models.swift'te güncellenecek hali (canvas rozetleri için)

`ServiceStatus`'a `externalRunning` ve `crashed(exitCode: Int32)` dahildir:
```swift
enum ServiceStatus: Equatable {
    case stopped, starting, running, externalRunning, stopping
    case crashed(exitCode: Int32)
    var isRunning: Bool   // running/starting/stopping/externalRunning
    var isOwnedByDeck: Bool
    var color: Color      // yeşil/açık yeşil(external)/sarı/gri/kırmızı
    var label: String     // Türkçe
}
enum ClaudeAttention: Equatable { case working, waiting }
```

## DeckPaths.swift (Services/)

```swift
enum DeckPaths {
    static let appSupport: URL        // ~/Library/Application Support/Deck (init'te create)
    static let projectsFile: URL      // appSupport/projects.json
    static let claudeTabsFile: URL    // appSupport/claude-tabs.json
    static let claudeStateDir: URL    // appSupport/claude-state (create)
    static let tmuxConfig: URL        // appSupport/deck-tmux.conf
    static let hookScript: URL        // ~/.claude/hooks/deck-hook.sh
    static let claudeSettings: URL    // ~/.claude/settings.json
}
```

## Shell.swift (Services/)

```swift
enum Shell {
    static let userPath: String                       // lazy: /bin/zsh -l -i -c 'print -rn -- $PATH'; hata → ProcessInfo PATH
    static func findExecutable(_ candidates: [String]) -> String?
    static func singleQuoted(_ s: String) -> String   // 'abc' sarma; içteki ' → '\''
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String)   // sync, stdout+stderr birleşik
    static func runAsync(_ launchPath: String, _ args: [String], completion: (@Sendable (Int32, String) -> Void)? = nil)
    static func runDetached(_ command: String)        // /bin/zsh -c, fire-and-forget
}
```

## TmuxService.swift (Services/)

```swift
enum TmuxService {
    static let socketPath: String            // "/tmp/deck-tmux-\(getuid()).sock"
    static var tmuxPath: String?             // findExecutable: /opt/homebrew/bin, /usr/local/bin, /opt/local/bin, /usr/bin
    static var isAvailable: Bool
    static func ensureConfig()               // deck-tmux.conf'u yaz (DESIGN.md'deki minimal içerik)

    struct Session: Identifiable, Equatable {
        var id: String { name }
        let name: String; let projectID: String; let number: Int
        let customName: String?; let claudeSID: String?; let attached: Bool
    }
    static func listSessions() -> [Session]                       // @deck_project dolu olanlar
    static func hasSession(_ name: String) -> Bool
    static func kill(_ name: String)
    static func setOption(_ session: String, key: String, value: String)   // set-option -t <s> @key value
    static func paneTitles() -> [String: String]                  // session_name → pane_title
    static func scroll(_ session: String, lines: Int, up: Bool)   // copy-mode -e + send-keys -X
    /// zsh -l -i -c ile çalıştırılacak tam string üretir:
    /// exec '<tmux>' -S '<sock>' -f '<conf>' new-session -A -D -s '<name>' -x <cols> -y <rows> [-e K=V]... ['<inner>']
    static func attachCommand(session: String, cols: Int, rows: Int, env: [String: String], inner: String?) -> String
}
```

## ProjectStore.swift (Services/)

```swift
@MainActor final class ProjectStore: ObservableObject {
    @Published var projects: [Project]
    init()                                        // load; dosya yoksa []
    func project(_ id: UUID) -> Project?
    func addProject(name: String, path: String) -> Project   // canvas'a otomatik sabit Claude ikonu ekler (kind: .claude, name: "Claude", icon: .claude, x:40 y:40)
    func updateProject(_ p: Project)
    func deleteProject(_ id: UUID)
    func upsertItem(_ item: CanvasItem, in projectID: UUID)
    func removeItem(_ itemID: UUID, from projectID: UUID)
    func moveItem(_ itemID: UUID, in projectID: UUID, to point: CGPoint)  // x/y güncelle + save (save debounce'lu olabilir)
    func save()                                   // atomik: tmp + move; {"version":1,"projects":[...]}
}
```

## ClaudeTabStore.swift (Services/)

claude-tabs.json: `{ "<projectID>": { "counter": Int, "closed": [ClosedTab] } }`

```swift
@MainActor final class ClaudeTabStore: ObservableObject {
    struct ClosedTab: Codable, Equatable, Identifiable {
        var id: Int { number }
        let number: Int; var name: String?; var claudeSID: String?; var title: String?
    }
    @Published private(set) var closed: [UUID: [ClosedTab]]
    func nextNumber(for projectID: UUID) -> Int          // monoton sayaç, kalıcı
    func bumpCounter(for projectID: UUID, atLeast n: Int)
    func recordClosed(_ tab: ClosedTab, for projectID: UUID)   // başa ekle, max 30
    func removeClosed(number: Int, for projectID: UUID)
    func clearClosed(for projectID: UUID)
}
```

## ClaudeSessionService.swift (Services/)

```swift
enum ClaudeSessionService {
    /// ~/.claude/projects/<encoded>/*.jsonl tara. encoded = mutlak yolda '/' → '-'.
    /// UUID adlı dosyalar; preview: type=="user" ilk gerçek mesaj (envelope filtreli), 200 kr;
    /// 64KB chunk, max 4MB, max 10 aday. mtime sıralı (yeni → eski). Arka planda çağrılır (sync API yeterli).
    static func scan(cwd: String) -> [ClaudeSession]     // ClaudeSession: Models.swift (id, summary, lastActivity, fileSizeBytes ekle)
    /// "claude --resume '<id>'" [--fork-session] + opsiyonel son argüman initial prompt (hepsi singleQuoted)
    static func resumeCommand(_ opts: ClaudeResumeOptions) -> String
}
struct ClaudeResumeOptions: Equatable {
    var sessionID: String; var fork: Bool = false; var initialPrompt: String? = nil
}
```

## HookInstaller.swift (Services/)

```swift
enum HookInstaller {
    /// deck-hook.sh'ı yaz (0755) + ~/.claude/settings.json'a idempotent merge.
    /// Eventler stoker'daki gibi (PreToolUse/PostToolUse/UserPromptSubmit → working,
    /// Notification/Stop → waiting, SessionStart → working, SessionEnd → dosya sil).
    /// Script: DECK_TAB_ID yoksa exit 0; stdin'i TAMAMEN oku; session_id'yi sed ile çek;
    /// claude-state/<DECK_TAB_ID>.json'a atomik yaz: {"state","name","project","sid","ts"}.
    /// Parse edilemeyen settings.json'a DOKUNMA. Arka plan kuyruğunda çağır.
    static func installIfNeeded()
}
```

## NotificationService.swift (Services/)

```swift
enum NotificationService {
    /// osascript display notification (UNUserNotificationCenter KULLANMA — ad-hoc imzalı app).
    static func notify(title: String, subtitle: String, body: String, sound: String)  // default sound "Glass"
    static func setBadge(_ count: Int)    // NSApp.dockTile.badgeLabel; 0 → nil. MainActor.
    static func playSound(_ name: String) // NSSound(named:)
}
```

## ProcessManager.swift (Services/)

Kalbi. SwiftTerm `LocalProcessTerminalView` cache'i + servis yaşam döngüsü + claude tmux + attention watcher.

```swift
final class DeckTerminalView: LocalProcessTerminalView { var tmuxSession: String? }

@MainActor final class ProcessManager: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published var statuses: [UUID: ServiceStatus] = [:]        // servis item id
    @Published var attention: [UUID: ClaudeAttention] = [:]     // workspace tab id
    @Published var paneTitles: [String: String] = [:]           // tmux session → başlık (2sn timer)
    weak var projectStore: ProjectStore?
    weak var tabStore: ClaudeTabStore?

    func status(of itemID: UUID) -> ServiceStatus               // default .stopped
    /// Anahtar: servisler için item.id.uuidString, sekmeler için tab.id.uuidString.
    func terminalView(forKey key: String) -> DeckTerminalView   // yoksa yarat (frame 1200x720, mono 12pt, scrollback 10k, processDelegate=self)
    func hasTerminalView(forKey key: String) -> Bool

    // Servisler (doğrudan PTY — stoker ProcessManager deseni birebir)
    func startService(_ item: CanvasItem, project: Project)
    func stopService(_ item: CanvasItem)
    func restartService(_ item: CanvasItem, project: Project)
    func toggleService(_ item: CanvasItem, project: Project)
    func killPort(_ port: Int, feedbackKey: String?)
    func scanExternalServices(projects: [Project])              // stopped + port bağlı → .externalRunning

    // Sekme terminalleri
    func startShell(tabID: UUID, cwd: String)                   // exec zsh -l -i (stty+cd wrapped)
    func runOneshot(tabID: UUID, command: String, cwd: String)  // bitince exit banner, process ölür
    /// Claude: tmux create-or-attach. session boşsa yeni ad üret (tab uuid). resume != nil ise inner "claude --resume ..."
    /// Env: DECK_TAB_ID=<tabID>, DECK_TAB_NAME, DECK_PROJECT. setOption ile @deck_project/@deck_num/@deck_name yazılır.
    func startClaude(tabID: UUID, project: Project, number: Int, customName: String?, resume: ClaudeResumeOptions?, existingSession: String?)
    func closeTab(tabID: UUID, killTmux: Bool)                  // view'i öldür/temizle; killTmux=true → tmux kill-session
    func sendInput(key: String, data: [UInt8])
    func repaint(key: String)                                   // softReset + refresh (reset DEĞİL)

    func terminateAllSync()                                     // tmux-backed HARİÇ; 0x03+killpg(SIGTERM)→2sn poll→SIGKILL
    // LocalProcessTerminalViewDelegate: processTerminated → exit 0 ise .stopped, değilse .crashed; pendingRestart 0.2sn sonra start
}
```

Detaylar (stoker'dan birebir port et):
- Spawn wrapper: `stty cols C rows R 2>/dev/null; cd '<escCwd>' && <cmd>`; `/bin/zsh -l -i -c`.
- Env: Shell.userPath, TERM=xterm-256color, COLORTERM=truecolor, LANG (yoksa en_US.UTF-8), TERM_PROGRAM=Deck, CLAUDE_CODE_NO_FLICKER=0, COLUMNS/LINES.
- Readiness: 0.3sn poll; port TCP connect 100ms timeout (SO_SNDTIMEO/RCVTIMEO); 30sn timeout → yine .running; portsuz 1.5sn grace.
- claude-state watcher: DispatchSource vnode + 1sn Timer poll; dosya `<tabID>.json` → attention güncelle; "waiting"e geçişte NotificationService.notify + ses + badge (badge = toplam waiting sayısı). SessionEnd dosyayı siler → attention temizle.
- Scroll monitörü: NSEvent.addLocalMonitorForEvents(.scrollWheel); hedef view DeckTerminalView ve tmuxSession != nil ise TmuxService.scroll'a yönlendir, event'i yut.
- startService başında stale state dosyasını sil; başlangıç/exit/ready ANSI banner'ları stoker'daki gibi.

## WorkspaceStore.swift (Services/)

```swift
@MainActor final class WorkspaceStore: ObservableObject {
    @Published var tabs: [UUID: [WorkspaceTab]] = [:]        // projectID → sekmeler
    @Published var activeTab: [UUID: UUID] = [:]             // projectID → tab id
    @Published var workspaceOpen: [UUID: Bool] = [:]         // projectID → workspace görünür mü
    func tabs(for projectID: UUID) -> [WorkspaceTab]
    func addTab(_ tab: WorkspaceTab, to projectID: UUID, activate: Bool)
    func closeTab(_ tabID: UUID, in projectID: UUID)
    func select(_ tabID: UUID, in projectID: UUID)
    func renameTab(_ tabID: UUID, in projectID: UUID, to name: String?)
    /// Açılışta tmux'tan @deck_project == proje shortID olan oturumları sekme olarak geri getir.
    func adoptTmuxSessions(for project: Project, tabStore: ClaudeTabStore)
    func openWorkspace(_ projectID: UUID, _ open: Bool)
}
```

`WorkspaceTab`'a Models.swift'te şunlar dahil: `id, kind, title, tmuxSession?, itemID?, url?, number: Int?` (claude sekme numarası), `customName: String?`.

## Views — sahiplik ve ana imzalar

- `DeckApp.swift`: `@main struct DeckApp: App` + `AppDelegate: NSObject, NSApplicationDelegate` (activationPolicy .regular + activate; applicationWillTerminate → processManager.terminateAllSync; hookInstaller arka planda; applicationShouldTerminateAfterLastWindowClosed true). Tüm store'lar burada @StateObject: `ProjectStore, ProcessManager, WorkspaceStore, ClaudeTabStore, BrowserManager`. Root: `RootView(...)` — `@Published selectedProjectID: UUID?` bir `AppRouter: ObservableObject` içinde; nil → HomeView, dolu → ProjectView. Pencere: min 1000x640, titleBar.
- `HomeView.swift`: proje grid'i (LazyVGrid, kart: ikon+isim+path+çalışan servis rozeti; tek tık → aç). Yeni/düzenle proje sheet'i (isim, NSOpenPanel dizin, ikon seçimi). Sağ tık: Düzenle/Sil (onaylı).
- `ProjectView.swift`: üst bar (← Projeler, proje ikon+adı, "Workspace" butonu Cmd+B, çalışan servis özeti) + CanvasView + workspace overlay: `if/opacity ile ZStack — workspace AÇIKKEN de canvas mount kalır`. Workspace tüm tab içeriklerini canlı tutar.
- `CanvasView.swift`: koyu degrade zemin; ikonlar mutlak pozisyonda (`.position`), DragGesture ile taşınır (bırakınca store.moveItem). İkon: 72x72 rounded-rect renkli zemin + SF Symbol/emoji + altında isim + durum noktası (servis) / waiting rozeti (claude). Çift tık aksiyonları; servis ikonunda hover'da mini play/stop/restart bar. Sağ tık: Aç / Başlat-Durdur-Yeniden Başlat / KILL PORT / Düzenle / Sil (claude ikonu: Yeni Claude Sekmesi / Geçmişi Sürdür → ClaudeResumeSheet / kapatılmış sekmeler listesi). Boş alan sağ tık: "Yeni Servis / Yeni Komut / Yeni Terminal / Yeni Web". Boş alan çift tık da editör açar.
- `ItemEditorSheet.swift`: `struct ItemEditorSheet: View` — yeni/düzenleme; tür picker en üstte; alanlar türe göre (service: komut+port+autoStart+cwd; oneshot: komut+cwd; shell: cwd; web: url); isim + IconPicker.
- `IconPicker.swift`: kürate SF Symbol grid'i + serbest sembol adı + emoji alanı + renk paleti (8-10 hazır renk). `IconView(spec: IconSpec, size: CGFloat)` yardımcı view'ı da burada (her yerde kullanılır).
- `WorkspaceView.swift`: üst sekme çubuğu (sol: ← geri; pill'ler: durum noktası/attention + başlık [claude: customName ?? paneTitle ?? "Claude N"] + x; sağ: "+ Claude" Cmd+T, "+ Terminal" menü, "+ Web"); içerik: TÜM sekmeler ZStack'te, aktif olmayan opacity(0)+allowsHitTesting(false). Claude pill çift tık → rename. Web sekmesi → WebTabView, diğerleri → TerminalHostView.
- `TerminalHostView.swift`: `struct TerminalHostView: NSViewRepresentable { let key: String; let manager: ProcessManager }` — stoker OutputView portu: TerminalContainerView bir kez mount, attach idempotent, eski parent'tan removeFromSuperview, t=0 + t=350ms çift refresh, 80ms debounce'lu resize, makeFirstResponder.
- `WebTabView.swift` + `BrowserManager`: stoker BrowserView portu. `@MainActor final class BrowserManager: ObservableObject { func model(forKey key: String, initialURL: String) -> BrowserModel; func clearAll() }`; BrowserModel: WKWebView sahibi, developerExtrasEnabled KVC + macOS 13.3+ isInspectable=true İKİSİ de, persistent dataStore, KVO url/canGoBack/canGoForward/isLoading, adres çubuğu, back/forward/reload/stop, mobil UA toggle, Chrome'da aç, createWebViewWith → aynı view'de load, getUserMedia .grant. Container attach deseni.
- `ClaudeResumeSheet.swift`: proje cwd'sindeki geçmiş oturum listesi (arama, preview + relatif zaman + boyut + kısa uuid), fork toggle, opsiyonel başlangıç mesajı; seçim → `onResume(ClaudeResumeOptions)`.

## Akış örnekleri

- Canvas'ta claude ikonuna çift tık → `tabStore.nextNumber` → `WorkspaceTab(kind: .claude, title: "Claude N", tmuxSession: tabID.uuidString, number: N)` → `workspace.addTab` → `pm.startClaude(...)` → `workspace.openWorkspace(true)`.
- Servis ikonuna çift tık → servis çalışmıyorsa başlat; her durumda workspace'te o servisin sekmesi yoksa `WorkspaceTab(kind: .service, itemID:)` ekle + aç (terminal key = item id → aynı PTY view).
- Web ikonu çift tık → var olan web sekmesi varsa seç, yoksa ekle (key = item id).
- Proje açılışta: `workspace.adoptTmuxSessions(project:)` + autoStart servisleri başlat + `pm.scanExternalServices`.
- Claude sekmesi x → önce `@claude_sid` oku, `tabStore.recordClosed(number, name, claudeSID, title)`, sonra closeTab(killTmux: true). Kapatılan sekmeye dönüş = canvas'ta claude sağ-tık → kapatılmışlar → yeni sekmede `claude --resume '<sid>'`. Uygulama kapanıp açılınca AÇIK sekmeler tmux'tan geri gelir (adoptTmuxSessions).
