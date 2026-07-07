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

    // MARK: - AI prompt

    /// "AI ile Oluştur" — yeni Claude sekmesine yapıştırılan, spec'i gömülü prompt.
    static func aiPrompt(for project: Project) -> String {
        """
        Bu projeyi incele (package.json, composer.json, Makefile, docker-compose, README vb.) \
        ve proje kökünde `deck.json` dosyasını oluştur ya da güncelle. Bu dosyayı Deck adlı \
        uygulama otomatik içe aktarır: geliştirme servislerini, sık kullanılan komutları ve \
        web adreslerini masaüstü ikonlarına çevirir.

        FORMAT (yalnız bu alanlar; konum bilgisi YOK — kullanıcı ikonları ekranda kendisi dizer):

        ```json
        {
          "items": [
            {"kind": "service", "name": "Frontend", "command": "npm run dev", "port": 5173, "folder": "Servisler", "autoStart": false},
            {"kind": "service", "name": "Backend", "command": "php artisan serve", "port": 8000, "cwd": "backend", "folder": "Servisler"},
            {"kind": "command", "name": "Optimize", "command": "php artisan optimize"},
            {"kind": "shell", "name": "Kök Terminal"},
            {"kind": "web", "name": "Önizleme", "url": "http://localhost:5173"},
            {"kind": "service", "name": "Özel Renk", "command": "...", "icon": {"symbol": "server.rack", "isEmoji": false, "colorHex": "#5E8DF7"}}
          ]
        }
        ```

        KURALLAR:
        - kind değerleri: service (kalıcı, start/stop), command (tek seferlik), shell (dizinde terminal), web (URL).
        - service'lerde biliniyorsa port yaz (Vite 5173, Next 3000, Astro 4321, Laravel 8000, Reverb 8080 ...); \
        port readiness kontrolünde kullanılır.
        - cwd proje köküne GÖRELİ ya da mutlak olabilir; kökse hiç yazma.
        - folder yalnız service'lerde çalışır; ilişkili servisleri aynı klasör adında grupla.
        - icon isteğe bağlı: SF Symbol adı (isEmoji=false) veya tek emoji (isEmoji=true) + hex renk.
        - Var olan deck.json'daki öğeleri koru; yalnız gerekli değişikliği yap. Deck isme göre eşler: \
        isim değiştirmek yeni ikon yaratır.
        - Çalıştırılabilir gerçek komutlar yaz (README'de doğrula), tahmin ettiklerini kısaca belirt.

        Dosyayı yazdıktan sonra eklediğin öğeleri tek satırlık maddelerle özetle. \
        Benden yeni servis/komut ekleme isteği gelirse aynı dosyayı güncellemen yeterli — Deck değişikliği otomatik alır.
        """
    }
}
