# Deck — Tasarım Spesifikasyonu

Çoklu proje geliştirme kokpiti. macOS native (Swift 6 + SwiftUI + SwiftTerm), referans: Heart (stoker).

## Temel Fikir

- **Proje** = isim + dizin + masaüstü canvas'ı. Uygulama birden fazla proje yönetir.
- Her projenin **masaüstü ekranı** vardır: kullanıcı ikonları serbestçe sürükleyip istediği yere koyar (klasörleme yok).
- Her projenin **workspace**'i vardır: üstte sekmeler olan tam ekran alan. Terminal, Claude ve Web sekmeleri burada yaşar.
- Her şey **tmux** üzerinde çalışır → uygulama kapansa bile servisler ve Claude oturumları yaşar; tekrar açınca sekmeler geri gelir.

## İkon (CanvasItem) Türleri

| Tür | Davranış |
|---|---|
| `claude` | Her projede sabit, silinemez. Çift tık → proje dizininde yeni tmux-kalıcı Claude sekmesi. Sağ tık → geçmiş Claude oturumları listesi, `claude --resume <id>` ile devam. |
| `terminal` (mode: `service`) | Kalıcı servis (npm run dev, php artisan serve...). İkon üzerinde play/stop/restart; durum noktası (yeşil/sarı/kırmızı). Çift tık → workspace'te çıktısına bağlan. |
| `terminal` (mode: `oneshot`) | Tek seferlik komut (php artisan optimize...). Çift tık → workspace'te çalışır, bitince "[bitti]" gösterir. |
| `terminal` (mode: `shell`) | Belirli dizinde boş interaktif terminal açar. |
| `web` | Kayıtlı URL'yi workspace'te gömülü WKWebView sekmesinde açar (isInspectable → Web Inspector). |

Her ikonun adı ve görseli (SF Symbol veya emoji + renk) özelleştirilebilir.

## Veri Modeli (Codable, `~/Library/Application Support/Deck/projects.json`)

```swift
struct Project { id: UUID; name: String; path: String; icon: IconSpec; items: [CanvasItem] }
struct IconSpec { symbol: String; isEmoji: Bool; colorHex: String }
struct CanvasItem {
  id: UUID; kind: ItemKind; name: String; icon: IconSpec
  x: Double; y: Double                    // canvas pozisyonu
  command: String?; mode: TerminalMode?; port: Int?; autoStart: Bool; cwd: String?  // terminal
  url: String?                            // web
}
enum ItemKind: String { case claude, terminal, web }
enum TerminalMode: String { case service, oneshot, shell }
enum ServiceStatus { case stopped, starting, running, stopping, crashed }  // runtime, persist edilmez
```

Şema: `{"version": 1, "projects": [...]}`. Bilinmeyen alanlar decode'da default ile geçer.

## tmux Oturum Adlandırma

- Servis: `deck-svc-<item-uuid-ilk8>`
- Claude: `deck-cl-<proj-uuid-ilk8>-<epoch>`
- Shell/oneshot: `deck-sh-<rastgele8>` (oneshot kalıcı olmak zorunda değil ama aynı altyapı)

Uygulama açılışında `tmux list-sessions` ile `deck-` öneklileri keşfet → servis durumları ve açık Claude/shell sekmeleri geri gelir. Servis durumu: session var + pane_dead=0 → running (port varsa port açık olana kadar starting); pane_dead=1 → crashed.

## Servis Yaşam Döngüsü

- start: `tmux new-session -d -s <s> -c <cwd>` + `remain-on-exit on` + komutu `/bin/zsh -l -i -c` ile çalıştır (login+interactive şart — PATH/alias için).
- stop: pane'e Ctrl+C → 3sn → SIGTERM → 3sn → kill-session.
- restart: stop + start. KILL PORT: `lsof -ti tcp:<port> | xargs kill -9`.
- Uygulama kapanınca servisler ÖLDÜRÜLMEZ (tmux'ta yaşar); kullanıcı isterse ikondan durdurur.

## Claude Entegrasyonu

- Yeni sekme: proje dizininde tmux içinde `claude` başlat.
- Sekme başlığı: tmux pane/window title'ından canlı alınır (Claude kendi başlığını set eder).
- Oturum keşfi: `~/.claude/projects/<dizin-slug>/*.jsonl` dosyalarından sessionId + ilk kullanıcı mesajı/özet + tarih çıkar → resume listesi.
- Hook'lar: `~/.claude/settings.json`'a Stop/Notification hook'u kur → ses çal + Dock badge + ilgili ikonda rozet.

## UI Akışı

1. **HomeView**: proje kartları grid'i. Yeni proje → isim + `NSOpenPanel` ile dizin. Kartta çalışan servis sayısı.
2. **ProjectView**: masaüstü canvas. Boş alana sağ tık → "Yeni Terminal / Yeni Web". İkon sürükle → pozisyon kaydet. Çift tık → aksiyon. Üst barda: geri, proje adı, workspace'i aç.
3. **WorkspaceView**: tam ekran, üstte sekme çubuğu (+ → Yeni Claude / Yeni Terminal), içerik SwiftTerm veya WKWebView. Esc/buton → canvas'a dön. Geçişler anlık (view'lar yaşamaya devam eder, yeniden yaratılmaz).

## Hız İlkeleri

- Sekme içerikleri (terminal/web) `ZStack` + opacity ile canlı tutulur; sekme değiştirmek re-render değil.
- tmux komutları async, UI'yi asla bloklamaz; durumlar @MainActor'da güncellenir.
- Tek pencere, tek NavigationStack; ağır sheet yok.

## Dosya Yapısı

```
Sources/Deck/
├── DeckApp.swift
├── Models/{Models.swift}
├── Services/{ProjectStore, TmuxService, ServiceManager, ClaudeSessionService, HookInstaller, NotificationService, Shell}.swift
└── Views/{HomeView, ProjectView, CanvasView, ItemEditorSheet, IconPicker, WorkspaceView, TerminalHostView, WebTabView, ClaudeResumeSheet}.swift
build.sh / install.sh / dist.sh  # stoker ile aynı akış, isimler Deck
```
