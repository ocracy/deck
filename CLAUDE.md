# CLAUDE.md

Bu dosya Claude Code için proje rehberidir.

## Proje Özeti

**Deck** — çoklu proje geliştirme kokpiti (macOS, Swift 6 + SwiftUI + SwiftTerm).
Her proje bir "masaüstü" ekranıdır: serbestçe yerleştirilen ikonlar (Claude / Servis / Komut / Terminal / Web).
Claude sekmeleri tmux ile kalıcıdır; servisler PTY'de start/stop/restart edilir; web WKWebView'de gömülü açılır.

Mimari ve kesin API sözleşmesi: `docs/DESIGN.md` ve `docs/API.md` — değişiklik yaparken önce bunlara bak, sapma olursa güncelle.

## Komutlar

```bash
./build.sh     # release build + Deck.app paketle
./install.sh   # build + /Applications/Deck.app'e kur
./dist.sh      # universal binary + ad-hoc imza + Deck.zip
swift build    # hızlı derleme kontrolü (debug)
```

### Kullanıcı komutları (Türkçe)

- "kur", "yükle", "install et" → `./install.sh`
- "deploy", "son halini ver", "uygulamayı çıkar" → `./dist.sh` (çıktıyı boyut+mimariyle raporla)
- "release yap", "yayınla" → VERSION'ı build.sh + dist.sh'ta artır → `./dist.sh` → commit + push → `gh release create v<VERSION> Deck.zip --title "Deck v<VERSION>" --notes "<değişiklikler>"`
- VERSION build.sh ve dist.sh'ta senkron tutulmalı; uygulama içi güncelleyici (UpdateChecker)
  CFBundleShortVersionString'i GitHub release tag'iyle (`v<VERSION>`) kıyaslar — repo: `ocracy/deck`,
  release asset adı MUTLAKA `Deck.zip`.

## Klasör Yapısı

```
Sources/Deck/
├── DeckApp.swift            # @main + AppDelegate (terminate cleanup, tmux hariç)
├── Models/Models.swift      # Project, CanvasItem, IconSpec, ServiceStatus, WorkspaceTab...
├── Services/                # DeckPaths, Shell, TmuxService, ProcessManager, ProjectStore,
│                            # ClaudeTabStore, ClaudeSessionService, HookInstaller,
│                            # NotificationService, WorkspaceStore
└── Views/                   # HomeView, ProjectView, CanvasView, WorkspaceView,
                             # TerminalHostView, WebTabView, ItemEditorSheet, IconPicker,
                             # ClaudeResumeSheet
```

## Kritik Kurallar (stoker/Heart'tan miras tuzaklar)

- **tmux**: her zaman sabit socket `-S /tmp/deck-tmux-<uid>.sock`; `-L` KULLANMA (GUI/login shell farklı TMUX_TMPDIR görür). Config'de `mouse off` şart (SwiftTerm seçimi bozulur).
- **Spawn**: her zaman `/bin/zsh -l -i -c` (login + interactive; `.zshrc` PATH'i için `-i` zorunlu). Başına `stty cols C rows R`. Env'e PATH snapshot + `TERM_PROGRAM=Deck` + `CLAUDE_CODE_NO_FLICKER=0`.
- **Stop**: PTY'ye 0x03 → 3sn → SIGTERM → 3sn → SIGKILL. App çıkışında killpg; tmux-backed hariç.
- **SwiftTerm**: terminal view'ları ProcessManager'a aittir, view katmanı sadece host eder; container'ı remount ETME (scroll sıfırlanır); `softReset()` kullan, `reset()` değil (scrollback siler); resize 80ms debounce.
- **Bildirim**: `osascript display notification` kullan; UNUserNotificationCenter ad-hoc imzalı app'te çalışmaz.
- **Depolama**: `~/Library/Application Support/Deck/` — projects.json atomik yazılır (tmp+move). Decode'lar `decodeIfPresent` + default ile toleranslı.
- Port rozetlerini `Text(verbatim:)` ile bas (Türkçe locale "8 000" gruplaması).
