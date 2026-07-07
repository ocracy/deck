# Deck — Tasarım Spesifikasyonu

Çoklu proje geliştirme kokpiti. macOS native (Swift 6 + SwiftUI + SwiftTerm), referans: Heart (stoker).

## Temel Fikir

- **Proje** = isim + dizin + masaüstü canvas'ı. Uygulama birden fazla proje yönetir.
- Her projenin **masaüstü ekranı** vardır: kullanıcı ikonları serbestçe sürükleyip istediği yere koyar (klasörleme yok).
- Her projenin **workspace**'i vardır: üstte sekmeler olan tam ekran alan. Terminal, Claude ve Web sekmeleri burada yaşar.
- **Claude sekmeleri tmux üzerinde** çalışır → uygulama kapansa bile yaşar; tekrar açınca sekmeler geri gelir. Servis/shell/oneshot terminalleri doğrudan PTY'de çalışır (SwiftTerm scrollback + exit code tespiti için) ve uygulama kapanırken temiz kapatılır.

## İkon (CanvasItem) Türleri

| Tür | Davranış |
|---|---|
| `claude` | Her projede sabit, silinemez. Çift tık → proje dizininde yeni tmux-kalıcı Claude sekmesi. Sağ tık → geçmiş Claude oturumları listesi, `claude --resume <id>` ile devam. |
| `terminal` (mode: `service`) | Kalıcı servis (npm run dev, php artisan serve...). İkon üzerinde play/stop/restart; durum noktası (yeşil/sarı/kırmızı). Çift tık → workspace'te çıktısına bağlan. |
| `terminal` (mode: `oneshot`) | Tek seferlik komut (php artisan optimize...). Çift tık → workspace'te çalışır, bitince "[bitti]" gösterir. |
| `terminal` (mode: `shell`) | Belirli dizinde boş interaktif terminal açar. |
| `web` | Kayıtlı URL'yi workspace'te gömülü WKWebView sekmesinde açar (isInspectable → Web Inspector). |

| `folder` | Yalnız servisleri gruplar (tek seviye). Çift tık → içine gir; sağ tık → Tümünü Başlat/Durdur/Yeniden Başlat. Servisler sürüklenerek içine atılır. |

Her ikonun adı ve görseli (SF Symbol veya emoji + renk) özelleştirilebilir. Claude ikonu marka görünümünü (krem zemin + mercan sunburst) kullanır.

## Canvas Etkileşimi

- Tek tık seç, ⌘+tık çoklu seç, boş alanda sürükle = kutu seçim, ⌘A tümü.
- Seçili grup birlikte sürüklenir; grup sağ tık → Seçilenleri Başlat/Durdur/Yeniden Başlat, Arka Planda Çalıştır, Klasöre Taşı, Kopyala, Sil.
- ⌘C/⌘V kopyala-yapıştır (projeler arası da), Enter yeniden adlandır, ⌘⌫ sil, Esc seçim/klasör/aramadan çık, ⌘P arama paleti.
- Komutlarda sağ tık → "Arka Planda Çalıştır": sekme açılmaz, bitince ses + bildirim.

## AI Kanalı (deck.json)

Proje kökündeki `deck.json` Deck'in içe aktarma kanalıdır: `{"items":[{kind,name,command,port,cwd,url,folder,icon,autoStart}]}` — konum bilgisi YOK, Deck boş yuva atar. Boş alan sağ tık → "AI ile Oluştur": spec'i gömülü prompt ile yeni Claude sekmesi açılır; Claude repo'yu inceleyip dosyayı yazar/günceller, Deck 2sn'lik mtime izleyicisiyle isme-göre-upsert eder (silme yapmaz). Kullanıcı Claude'a "şunu ekle" diyerek arayüzü genişletebilir.

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

## tmux (yalnız Claude sekmeleri)

- Sabit socket: `-S /tmp/deck-tmux-<uid>.sock` (`-L` KULLANMA — GUI launchd ile login shell farklı TMUX_TMPDIR görür).
- Minimal config `deck-tmux.conf`: status off, mouse off, screen-256color + RGB, escape-time 0, history 50000, set-clipboard off, focus-events off.
- Oturum adı: sekme UUID'si; metadata tmux user option'ları ile: `@deck_project`, `@deck_num`, `@deck_name`, `@claude_sid`.
- Oluştur-veya-bağlan tek komut: `new-session -A -D -s <ad> -x <cols> -y <rows> -e K=V ... '<inner>'` (`zsh -l -i -c "exec ..."` içinde).
- Sekme başlığı: `list-panes -a -F '#{session_name}\t#{pane_title}'` (Claude OSC title set eder).
- Scroll: SwiftTerm scrollback'i tmux'ta boştur → NSEvent wheel monitörü `copy-mode -e` + `send-keys -X scroll-up/down` sürer.

## Servis Yaşam Döngüsü (doğrudan PTY, stoker deseni)

- Spawn: `/bin/zsh -l -i -c "stty cols C rows R 2>/dev/null; cd '<cwd>' && <cmd>"`; env: PATH snapshot (`zsh -l -i -c 'print -rn -- $PATH'` bir kere), TERM=xterm-256color, COLORTERM=truecolor, TERM_PROGRAM=Deck, CLAUDE_CODE_NO_FLICKER=0, COLUMNS/LINES.
- stop: PTY'ye 0x03 → 3sn → SIGTERM → 3sn → SIGKILL. Uygulama çıkışında terminateAllSync (killpg; tmux-backed hariç).
- Readiness: port varsa 0.3sn TCP connect poll (100ms timeout, 30sn'de vazgeç), yoksa 1.5sn grace → running.
- KILL PORT: `lsof -ti tcp:<port> | xargs kill -9`. Harici çalışan servis tespiti: stopped iken port bağlıysa `externalRunning`.

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
