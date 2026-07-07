import Foundation

/// Proje kökündeki `deck.json` ↔ canvas köprüsü.
///
/// Kanal: kullanıcı "AI ile Oluştur" der → Deck, spec'i gömülü bir prompt'la
/// yeni Claude sekmesi açar → Claude repo'yu inceleyip `deck.json` yazar/günceller
/// → Deck dosyayı izler ve öğeleri canvas'a aktarır (isme göre upsert, silme yok).
/// Konum bilgisi dosyada YOKTUR; Deck boş yuva atar, kullanıcı ekranda dizer.
enum DeckFileService {

    struct FileItem: Codable {
        var name: String
        var kind: String            // "service" | "command" | "shell" | "web"
        var command: String?
        var port: Int?
        var cwd: String?
        var url: String?
        var autoStart: Bool?
        var folder: String?         // yalnız servisler için: canvas klasör adı
        var icon: IconSpec?
    }

    struct FileFormat: Codable {
        var items: [FileItem]
    }

    static func fileURL(for project: Project) -> URL {
        URL(fileURLWithPath: (project.path as NSString).expandingTildeInPath)
            .appendingPathComponent("deck.json")
    }

    static func modificationDate(for project: Project) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL(for: project).path))?[.modificationDate] as? Date
    }

    /// deck.json'u okuyup projeye aktarır. Eşleme isme göredir (küçük/büyük
    /// harf duyarsız): var olan güncellenir, yeni eklenir, dosyada olmayan
    /// SİLİNMEZ (kullanıcının elle eklediklerine dokunma).
    /// Dönüş: (eklenen, güncellenen) sayısı.
    @MainActor
    @discardableResult
    static func sync(project: Project, store: ProjectStore) -> (added: Int, updated: Int) {
        guard let data = try? Data(contentsOf: fileURL(for: project)),
              let decoded = try? JSONDecoder().decode(FileFormat.self, from: data),
              var current = store.project(project.id) else { return (0, 0) }

        var added = 0, updated = 0

        for fi in decoded.items {
            guard let mapped = mapKind(fi.kind) else { continue }
            let (kind, mode) = mapped
            let key = fi.name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }

            // Klasör: yalnız servisler; ada göre bul/yarat (klasörler hep kökte).
            var parentID: UUID? = nil
            if mode == .service, let folderName = fi.folder?.trimmingCharacters(in: .whitespaces),
               !folderName.isEmpty {
                if let existing = current.items.first(where: {
                    $0.kind == .folder && $0.name.lowercased() == folderName.lowercased()
                }) {
                    parentID = existing.id
                } else {
                    var folder = CanvasItem(kind: .folder, name: folderName, icon: .defaultFolder)
                    let p = freeSpot(among: current.items.filter { $0.parentID == nil })
                    folder.x = p.x
                    folder.y = p.y
                    current.items.append(folder)
                    parentID = folder.id
                }
            }

            if let idx = current.items.firstIndex(where: {
                $0.kind == kind && $0.name.lowercased() == key
            }) {
                var item = current.items[idx]
                item.command = fi.command ?? item.command
                item.mode = (kind == .terminal) ? mode : nil
                item.port = fi.port ?? item.port
                item.cwd = fi.cwd ?? item.cwd
                item.url = fi.url ?? item.url
                item.autoStart = fi.autoStart ?? item.autoStart
                if let icon = fi.icon { item.icon = icon }
                if let parentID { item.parentID = parentID }
                if current.items[idx] != item {
                    current.items[idx] = item
                    updated += 1
                }
            } else {
                var item = CanvasItem(kind: kind, name: fi.name,
                                      icon: fi.icon ?? defaultIcon(kind: kind, mode: mode))
                item.command = fi.command
                item.mode = (kind == .terminal) ? mode : nil
                item.port = fi.port
                item.cwd = fi.cwd
                item.url = fi.url
                item.autoStart = fi.autoStart ?? false
                item.parentID = parentID
                let siblings = current.items.filter { $0.parentID == item.parentID }
                let p = freeSpot(among: siblings)
                item.x = p.x
                item.y = p.y
                current.items.append(item)
                added += 1
            }
        }

        if added > 0 || updated > 0 {
            store.updateProject(current)
        }
        return (added, updated)
    }

    private static func mapKind(_ raw: String) -> (ItemKind, TerminalMode?)? {
        switch raw.lowercased() {
        case "service": return (.terminal, .service)
        case "command", "oneshot", "quick": return (.terminal, .oneshot)
        case "shell", "terminal": return (.terminal, .shell)
        case "web", "browser": return (.web, nil)
        default: return nil
        }
    }

    private static func defaultIcon(kind: ItemKind, mode: TerminalMode?) -> IconSpec {
        switch kind {
        case .web: return .defaultWeb
        case .folder: return .defaultFolder
        default:
            switch mode {
            case .oneshot: return IconSpec(symbol: "bolt.fill", isEmoji: false, colorHex: "#B57BEE")
            case .shell: return IconSpec(symbol: "terminal", isEmoji: false, colorHex: "#8E8E93")
            default: return .defaultTerminal
            }
        }
    }

    /// İkonlarla çakışmayan ilk boş grid yuvası (CanvasView ile aynı ritim).
    static func freeSpot(among items: [CanvasItem]) -> CGPoint {
        let cols = 6
        for i in 0..<300 {
            let p = CGPoint(x: 96 + Double(i % cols) * 110,
                            y: 96 + Double(i / cols) * 124)
            let occupied = items.contains { abs($0.x - p.x) < 56 && abs($0.y - p.y) < 62 }
            if !occupied { return p }
        }
        return CGPoint(x: 120, y: 120)
    }

    // MARK: - Silme / yeniden adlandırma geri-yazımı

    /// Canvas'tan silinen öğeleri deck.json'dan da düşürür — yoksa bir sonraki
    /// sync (dosya değişimi / açılış) silinen ikonları diriltir.
    static func removeEntries(matching removed: [CanvasItem], projectPath: String) {
        let url = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
            .appendingPathComponent("deck.json")
        guard let data = try? Data(contentsOf: url),
              var decoded = try? JSONDecoder().decode(FileFormat.self, from: data) else { return }

        var keys: Set<String> = []
        var removedFolders: Set<String> = []
        for item in removed {
            switch item.kind {
            case .folder: removedFolders.insert(item.name.lowercased())
            case .claude: continue
            default: keys.insert(entryKey(kind: item.kind, mode: item.mode, name: item.name))
            }
        }

        let before = decoded.items.count
        decoded.items.removeAll { fi in
            guard let (kind, mode) = mapKind(fi.kind) else { return false }
            return keys.contains(entryKey(kind: kind, mode: mode, name: fi.name))
        }
        // Silinen klasörün adı dosyada kalırsa sync klasörü yeniden yaratır.
        for idx in decoded.items.indices {
            if let f = decoded.items[idx].folder, removedFolders.contains(f.lowercased()) {
                decoded.items[idx].folder = nil
            }
        }
        guard decoded.items.count != before || !removedFolders.isEmpty else { return }
        write(decoded, to: url)
    }

    /// Canvas'ta yeniden adlandırılan öğeyi dosyada da izler — yoksa eski
    /// adla yeni bir ikon türer.
    static func renameEntry(oldName: String, newName: String, kind: ItemKind,
                            mode: TerminalMode?, projectPath: String) {
        let url = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
            .appendingPathComponent("deck.json")
        guard let data = try? Data(contentsOf: url),
              var decoded = try? JSONDecoder().decode(FileFormat.self, from: data) else { return }
        let key = entryKey(kind: kind, mode: mode, name: oldName)
        var changed = false
        for idx in decoded.items.indices {
            guard let (k, m) = mapKind(decoded.items[idx].kind),
                  entryKey(kind: k, mode: m, name: decoded.items[idx].name) == key else { continue }
            decoded.items[idx].name = newName
            changed = true
        }
        // Klasör adı değiştiyse folder alanlarını da taşı.
        if kind == .folder {
            for idx in decoded.items.indices
            where decoded.items[idx].folder?.lowercased() == oldName.lowercased() {
                decoded.items[idx].folder = newName
                changed = true
            }
        }
        if changed { write(decoded, to: url) }
    }

    private static func entryKey(kind: ItemKind, mode: TerminalMode?, name: String) -> String {
        "\(kind.rawValue)|\(mode?.rawValue ?? "-")|\(name.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    private static func write(_ format: FileFormat, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(format) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - AI prompt

    /// "AI ile Oluştur" — yeni Claude sekmesine verilen görev. `note`:
    /// kullanıcının opsiyonel yönlendirmesi ("şunlara dikkat et...").
    static func aiPrompt(for project: Project, note: String? = nil) -> String {
        var prompt = """
        GÖREVİN: Bu projeyi baştan sona tarayıp geliştirme sırasında GERÇEKTEN kullanılan \
        en mantıklı servisleri ve komutları bulmak, sonra bunları proje kökünde `deck.json` \
        olarak yazmak. Deck uygulaması bu dosyayı otomatik içe aktarıp masaüstü ikonlarına çevirir.

        NASIL TARARSIN:
        - Kökü VE alt dizinleri gez: backend/, frontend/, api/, apps/*, packages/* gibi monorepo yapıları dahil.
        - Kaynaklar: package.json "scripts" (dev/start/watch/build), composer.json, artisan komutları \
        (serve, horizon, queue:work, reverb:start, schedule:work), Makefile hedefleri, docker-compose \
        servisleri, Procfile, README kurulum bölümleri.
        - Portları gerçek konfigürasyondan çıkar (vite.config, .env PORT/APP_URL, next.config...). \
        Varsayılanlar: Vite 5173, Next/Nuxt 3000, Astro 4321, Laravel serve 8000, Reverb 8080, ngrok panel 4040.

        NE ÜRETİRSİN:
        - "service" → sürekli çalışanlar: dev sunucuları (npm run dev, php artisan serve), worker'lar \
        (php artisan horizon, queue:work), websocket (reverb:start), docker compose up. \
        İlişkili servisleri "folder" ile grupla (ör. "Servisler", "Workers"). \
        autoStart'ı yalnız her gün ilk iş açılanlara ver.
        - "command" → tek seferlik işler: php artisan optimize, php artisan migrate, npm run build, \
        composer install, test komutu.
        - "web" → gerçekten var olan lokal URL'ler: uygulama, /horizon paneli, /telescope, Mailpit.
        - "shell" → yalnız kökten farklı, sık girilen bir dizin varsa (ör. backend/).
        - "cwd" → komut kökten çalışmıyorsa göreli dizin; kökse hiç yazma.

        İKON SEÇİMİ — her öğeye şu setten uygun ikonu ver \
        (format: "icon": {"symbol": "...", "isEmoji": false, "colorHex": "#..."}):
        - frontend dev sunucu: "play.display" #5E8DF7 · backend API: "server.rack" #3DDC84
        - worker/queue: "gearshape.2.fill" #E8874B · websocket: "dot.radiowaves.left.and.right" #B57BEE
        - docker/veritabanı: "shippingbox.fill" #38BDF8 · build: "hammer.fill" #E8B84B
        - optimize/temizlik: "sparkles" #B57BEE · migrate: "cylinder.split.1x2" #8E8E93
        - test: "checkmark.seal.fill" #3DDC84 · web panel: "globe" #38BDF8 · tünel/ngrok: "network" #E8874B

        FORMAT (konum bilgisi YOK — yerleşimi Deck yapar):
        {"items":[
          {"kind":"service","name":"Frontend","command":"npm run dev","port":5173,"cwd":"frontend","folder":"Servisler","icon":{"symbol":"play.display","isEmoji":false,"colorHex":"#5E8DF7"}},
          {"kind":"command","name":"Optimize","command":"php artisan optimize","icon":{"symbol":"sparkles","isEmoji":false,"colorHex":"#B57BEE"}},
          {"kind":"web","name":"Uygulama","url":"http://localhost:8000","icon":{"symbol":"globe","isEmoji":false,"colorHex":"#38BDF8"}}
        ]}

        KURALLAR:
        - Az ve öz: dosyalara dayanmayan, çalışacağından emin olmadığın komut EKLEME.
        - Var olan deck.json içeriğini koru; yalnız gerekeni ekle/güncelle. Deck isme göre eşler — \
        isim değiştirmek yeni ikon yaratır.
        - Bitince eklediklerini tek satırlık maddelerle özetle. Sonraki isteklerimde bu dosyayı \
        güncellemen yeterli; Deck değişikliği otomatik alır.
        """
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            prompt += "\n\nKULLANICI NOTU (bunlara öncelik ver):\n\(note)"
        }
        return prompt
    }
}
