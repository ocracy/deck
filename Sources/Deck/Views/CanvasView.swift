import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Uygulama içi pano (⌘C/⌘V — projeler arası da çalışır)

@MainActor
enum CanvasClipboard {
    static var items: [CanvasItem] = []
}

// MARK: - Klavye köprüsü

/// SwiftUI canvas'ına masaüstü kısayolları taşır (⌘A/C/V/P, Enter, ⌘⌫, Esc).
/// Metin girişi (TextField/terminal) odaktayken hiçbir tuşa dokunmaz.
@MainActor
final class CanvasKeyController: ObservableObject {
    var enabled = false
    var onKey: ((NSEvent) -> Bool)?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if !self.enabled { return false }
                let responder = NSApp.keyWindow?.firstResponder
                if responder is NSTextView || responder is NSTextField { return false }
                // Terminal odaklıysa bile: enabled == workspace kapalı demek,
                // yani terminal GİZLİ — tuşların sahibi canvas'tır. (Gizli
                // terminale odak bırakmak Enter/kısayolları öldürüyordu;
                // ProjectView kapanışta odağı bırakır, bu ikinci emniyet.)
                return self.onKey?(event) ?? false
            }
            return consumed ? nil : event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

// MARK: - CanvasView

struct CanvasView: View {
    let project: Project
    /// Canvas görünür ve klavyenin sahibi mi (workspace kapalı + proje seçili)?
    let keyboardEnabled: Bool
    @ObservedObject var store: ProjectStore
    @ObservedObject var pm: ProcessManager
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var tabStore: ClaudeTabStore

    private struct EditorContext: Identifiable {
        let id = UUID()
        var item: CanvasItem?
        var spawn: CGPoint?
        var preset: ItemEditorKind = .service
    }

    @State private var editor: EditorContext?
    @State private var showResumeSheet = false
    @State private var hoveredItemID: UUID?

    // Seçim + sürükleme
    @State private var selectedIDs: Set<UUID> = []
    @State private var draggingIDs: Set<UUID> = []
    @State private var dragOffset: CGSize = .zero
    @State private var marqueeStart: CGPoint?
    @State private var marqueeRect: CGRect?
    @State private var pressedItemID: UUID?
    @State private var bgPressActive = false

    // Klasör gezinme
    @State private var currentFolderID: UUID?

    // Yeniden adlandırma + arama
    @State private var renamingItemID: UUID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    @State private var searchOpen = false
    @State private var showAISheet = false
    @State private var quickLookID: UUID?

    @StateObject private var keys = CanvasKeyController()

    /// store'daki güncel hali (parametre kopyası bayatlayabilir).
    private var liveProject: Project { store.project(project.id) ?? project }

    private var visibleItems: [CanvasItem] {
        liveProject.items.filter { $0.parentID == currentFolderID }
    }

    private var currentFolder: CanvasItem? {
        currentFolderID.flatMap { id in liveProject.items.first { $0.id == id } }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                background(size: geo.size)
                marqueeOverlay

                ForEach(visibleItems) { item in
                    itemView(item, canvasSize: geo.size)
                        .position(position(for: item))
                }

                if currentFolderID != nil {
                    folderBreadcrumb
                }
                if searchOpen {
                    SearchPalette(project: liveProject,
                                  onClose: { searchOpen = false },
                                  onPick: { openSearchResult($0) })
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 60)
                        .zIndex(10)
                }
                if let ql = quickLookItem {
                    QuickLookOverlay(item: ql, project: liveProject, status: pm.status(of: ql.id),
                                     onClose: { quickLookID = nil })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .zIndex(20)
                }

                // Alttan ince bilgi çubuğu: seçili objenin dizini + komutu.
                if let info = infoBarItem {
                    bottomInfoBar(info)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .zIndex(5)
                }
            }
            // Sürükleme ölçümü SABİT uzayda yapılmalı: ikonun kendi (local)
            // uzayı ikonla birlikte kaydığı için translation geri besleme
            // döngüsüne girer — "ileri geri kayma" glitch'inin kaynağı.
            .coordinateSpace(name: "deckCanvas")
            .sheet(item: $editor) { ctx in
                ItemEditorSheet(project: liveProject, item: ctx.item, presetKind: ctx.preset) { saved in
                    var out = saved
                    if ctx.item == nil {
                        let p = ctx.spawn ?? freeSpot(in: geo.size)
                        out.x = p.x
                        out.y = p.y
                        // Klasör içindeyken eklenen servis klasöre girer.
                        if out.kind == .terminal, out.mode == .service {
                            out.parentID = currentFolderID
                        }
                    }
                    // Çalışan servisin türü/komutu değişiyorsa eski süreci
                    // kontrolsüz bırakma — önce durdur.
                    if let old = ctx.item, old.kind == .terminal, old.mode == .service,
                       pm.status(of: old.id).isOwnedByDeck,
                       old.command != out.command || out.mode != .service || out.kind != .terminal {
                        pm.stopService(old)
                    }
                    store.upsertItem(out, in: project.id)
                }
            }
            .sheet(isPresented: $showResumeSheet) {
                ClaudeResumeSheet(project: liveProject) { opts in
                    ClaudeTabLauncher.open(project: liveProject, workspace: workspace,
                                           tabStore: tabStore, pm: pm, resume: opts)
                }
            }
            .sheet(isPresented: $showAISheet) {
                AIPromptSheet { note in
                    ClaudeTabLauncher.open(project: liveProject, workspace: workspace,
                                           tabStore: tabStore, pm: pm,
                                           customName: "AI Kurulum",
                                           initialCommand: DeckFileService.aiPrompt(for: liveProject, note: note),
                                           autoRun: true)
                }
            }
        }
        .clipped()
        // Menü fallback'leri: NSEvent monitörü tuşu tüketirse menü hiç tetiklenmez;
        // tetiklenirse (monitör devre dışı/es geçmiş) aynı işi buradan yaparız.
        .onReceive(NotificationCenter.default.publisher(for: .deckDeleteSelection)) { _ in
            guard keyboardEnabled, !selectedIDs.isEmpty else { return }
            deleteItems(selectedIDs)
        }
        .onReceive(NotificationCenter.default.publisher(for: .deckSearchCanvas)) { _ in
            guard keyboardEnabled else { return }
            searchOpen = true
        }
        .onAppear {
            keys.enabled = keyboardEnabled
            keys.onKey = { handleKey($0) }
            keys.install()
        }
        .onChange(of: keyboardEnabled) { _, on in
            keys.enabled = on
            if !on {
                searchOpen = false
                renamingItemID = nil
            }
        }
    }

    // MARK: - Zemin + marquee

    private func background(size: CGSize) -> some View {
        LinearGradient(colors: [Color(hex: "#101018"), Color(hex: "#1A1A28")],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .contentShape(Rectangle())
            .gesture(backgroundGesture)
            .contextMenu { emptyAreaMenu(size: size) }
    }

    /// Tek jest, sıfır gecikme: basar basmaz seçim temizlenir (masaüstü hissi),
    /// hareket kutu seçime dönüşür, çift tık `clickCount` ile mouse-up'ta
    /// yakalanır — tap-bekleme gecikmesi yok.
    private var backgroundGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("deckCanvas"))
            .onChanged { value in
                if !bgPressActive {
                    bgPressActive = true
                    if NSApp.currentEvent?.modifierFlags.contains(.command) != true {
                        selectedIDs = []
                    }
                    if renamingItemID != nil { commitPendingRename() }
                }
                let dx = value.location.x - value.startLocation.x
                let dy = value.location.y - value.startLocation.y
                guard marqueeStart != nil || abs(dx) > 4 || abs(dy) > 4 else { return }
                let start = marqueeStart ?? value.startLocation
                marqueeStart = start
                marqueeRect = CGRect(x: min(start.x, value.location.x),
                                     y: min(start.y, value.location.y),
                                     width: abs(value.location.x - start.x),
                                     height: abs(value.location.y - start.y))
            }
            .onEnded { value in
                bgPressActive = false
                if let rect = marqueeRect {
                    let hits = visibleItems.filter { item in
                        rect.intersects(CGRect(x: item.x - 40, y: item.y - 46, width: 80, height: 96))
                    }.map(\.id)
                    if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                        selectedIDs.formUnion(hits)
                    } else {
                        selectedIDs = Set(hits)
                    }
                } else if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                    editor = EditorContext(item: nil, spawn: value.startLocation)
                }
                marqueeStart = nil
                marqueeRect = nil
            }
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let rect = marqueeRect {
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(Rectangle().stroke(Color.accentColor.opacity(0.7), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func emptyAreaMenu(size: CGSize) -> some View {
        Button("AI ile Oluştur ✨") { createWithAI() }
        Divider()
        Button("Yeni Claude") { newItem(.claude, size: size) }
        Button("Yeni Servis") { newItem(.service, size: size) }
        Button("Yeni Komut") { newItem(.oneshot, size: size) }
        Button("Yeni Terminal") { newItem(.shell, size: size) }
        Button("Yeni Web") { newItem(.web, size: size) }
        if currentFolderID == nil {
            Button("Yeni Klasör") { createFolder(size: size) }
        }
        if !CanvasClipboard.items.isEmpty {
            Divider()
            Button("Yapıştır (\(CanvasClipboard.items.count))") { paste(size: size) }
        }
    }

    private func newItem(_ preset: ItemEditorKind, size: CGSize) {
        editor = EditorContext(item: nil, spawn: freeSpot(in: size), preset: preset)
    }

    private func createFolder(size: CGSize) {
        var folder = CanvasItem(kind: .folder, name: "Yeni Klasör", icon: .defaultFolder)
        let p = freeSpot(in: size)
        folder.x = p.x
        folder.y = p.y
        store.upsertItem(folder, in: project.id)
        selectedIDs = [folder.id]
        beginRename(folder)
    }

    private func createWithAI() {
        showAISheet = true
    }

    /// Claude ikonunun ayarlarıyla (başlangıç komutu + otomatik çalıştır +
    /// dizin) yeni bir Claude sekmesi açar.
    private func launchClaude(_ item: CanvasItem) {
        ClaudeTabLauncher.open(project: liveProject, workspace: workspace,
                               tabStore: tabStore, pm: pm,
                               customName: item.name == "Claude" ? nil : item.name,
                               initialCommand: item.command,
                               autoRun: item.autoStart,
                               cwd: item.cwd)
    }

    /// Mevcut ikonlarla çakışmayan ilk boş yuva (görünür katmanda).
    private func freeSpot(in size: CGSize) -> CGPoint {
        let cols = max(1, Int((max(size.width, 300) - 100) / 110))
        for i in 0..<300 {
            let p = CGPoint(x: 96 + Double(i % cols) * 110,
                            y: 96 + Double(i / cols) * 124)
            let occupied = visibleItems.contains { abs($0.x - p.x) < 56 && abs($0.y - p.y) < 62 }
            if !occupied { return p }
        }
        return CGPoint(x: 120, y: 120)
    }

    // MARK: - Klasör gezinme

    private var folderBreadcrumb: some View {
        HStack(spacing: 8) {
            Button {
                currentFolderID = nil
                selectedIDs = []
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Geri")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)

            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: currentFolder?.icon.colorHex ?? "#E8B84B"))
            Text(currentFolder?.name ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(12)
    }

    // MARK: - Quick Look + alt bilgi çubuğu

    private var quickLookItem: CanvasItem? {
        quickLookID.flatMap { id in liveProject.items.first { $0.id == id } }
    }

    private var infoBarItem: CanvasItem? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return liveProject.items.first { $0.id == id }
    }

    /// Objenin görsel çalışma dizini (kök ise proje yolu, göreli ise çözülmüş).
    private func displayCwd(_ item: CanvasItem) -> String {
        let resolved = item.resolvedCwd(projectPath: liveProject.path)
        return (resolved as NSString).abbreviatingWithTildeInPath
    }

    private func displayCommand(_ item: CanvasItem) -> String? {
        switch item.kind {
        case .web: return item.url
        case .folder: return nil
        case .claude:
            guard let c = item.command, !c.isEmpty else { return "claude (boş)" }
            return item.autoStart ? "claude → \(c)" : "claude, hazır: \(c)"
        case .terminal:
            guard let c = item.command, !c.isEmpty else { return nil }
            return c
        }
    }

    private func bottomInfoBar(_ item: CanvasItem) -> some View {
        HStack(spacing: 10) {
            if item.kind == .terminal, item.mode == .service {
                Circle().fill(pm.status(of: item.id).color).frame(width: 7, height: 7)
            }
            Text(item.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
            if let port = item.port {
                Text(verbatim: ":\(port)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: "#38BDF8"))
            }
            Divider().frame(height: 12)
            Image(systemName: "folder")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(displayCwd(item))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            if let cmd = displayCommand(item) {
                Divider().frame(height: 12)
                Image(systemName: item.kind == .web ? "link" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(cmd)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(hex: "#8FE388"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Text("Space: önizleme")
                .font(.system(size: 9))
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    // MARK: - İkon görünümü

    private func position(for item: CanvasItem) -> CGPoint {
        var p = CGPoint(x: item.x, y: item.y)
        if draggingIDs.contains(item.id) {
            p.x += dragOffset.width
            p.y += dragOffset.height
        }
        return p
    }

    private func folderChildren(_ folder: CanvasItem) -> [CanvasItem] {
        liveProject.items.filter { $0.parentID == folder.id }
    }

    @ViewBuilder
    private func itemView(_ item: CanvasItem, canvasSize: CGSize) -> some View {
        let isService = item.kind == .terminal && item.mode == .service
        let status = pm.status(of: item.id)
        let isSelected = selectedIDs.contains(item.id)

        VStack(spacing: 5) {
            iconBody(item, status: status, isService: isService)

            if renamingItemID == item.id {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.5)))
                    .frame(width: 100)
                    .focused($renameFocused)
                    .onSubmit { commitRename(item) }
                    .onExitCommand { cancelRename() }
            } else {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isSelected ? Color.accentColor.opacity(0.85) : Color.clear)
                    )
                    .frame(maxWidth: 104)
            }

            // Sabit yükseklikte kontrol yuvası: hover'da servis kontrolleri.
            ZStack {
                if isService, hoveredItemID == item.id, draggingIDs.isEmpty {
                    serviceControls(item, status: status)
                }
            }
            .frame(height: 22)
        }
        .frame(width: 108)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                .padding(.bottom, 20)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredItemID = item.id }
            else if hoveredItemID == item.id { hoveredItemID = nil }
        }
        .gesture(itemGesture(item, canvasSize: canvasSize))
        .contextMenu { contextMenu(for: item, status: status) }
    }

    @ViewBuilder
    private func iconBody(_ item: CanvasItem, status: ServiceStatus, isService: Bool) -> some View {
        Group {
            if item.kind == .claude {
                ClaudeIconView(size: 72)
            } else if item.kind == .folder {
                folderIcon(item)
            } else {
                IconView(spec: item.icon, size: 72)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isService {
                Circle()
                    .fill(status.color)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
                    .offset(x: 3, y: 3)
                    .help(status.label)
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.kind == .claude, waitingClaudeCount > 0 {
                Text("\(waitingClaudeCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red))
                    .offset(x: 7, y: -6)
            }
        }
    }

    private func folderIcon(_ folder: CanvasItem) -> some View {
        let children = folderChildren(folder)
        let running = children.filter { pm.status(of: $0.id).isRunning }.count
        // Diğer objelerle birebir aynı 72×72 dolu IconView zemini; klasör
        // olduğu sembol + içerik sayacı rozetiyle belli olur.
        return IconView(spec: folder.icon, size: 72)
            .overlay(alignment: .bottomTrailing) {
                if !children.isEmpty {
                    Text(running > 0 ? "\(running)/\(children.count)" : "\(children.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(running > 0 ? Color.green : Color.black.opacity(0.55)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                        .offset(x: 4, y: 4)
                }
            }
    }

    private func serviceControls(_ item: CanvasItem, status: ServiceStatus) -> some View {
        HStack(spacing: 6) {
            miniButton(status.isRunning ? "stop.fill" : "play.fill",
                       help: status.isRunning ? (status == .externalRunning ? "Durdur (dış süreç)" : "Durdur") : "Başlat") {
                pm.toggleService(item, project: liveProject)
            }
            miniButton("arrow.clockwise", help: "Yeniden başlat") {
                pm.restartService(item, project: liveProject)
            }
            if let port = item.port {
                miniButton("bolt.slash.fill", help: "Portu boşalt (\(port))") {
                    pm.killPort(port, feedbackKey: item.id.uuidString)
                }
            }
        }
    }

    private func miniButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.15)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var waitingClaudeCount: Int {
        workspace.tabs(for: project.id).filter {
            $0.kind == .claude && pm.attention[$0.id] == .waiting
        }.count
    }

    // MARK: - Seçim + sürükleme

    /// Tek birleşik jest — masaüstü hissi:
    /// mouse-DOWN anında seçim (bekleme yok), 3pt hareketle grup sürükleme,
    /// çift tık `clickCount` ile mouse-up'ta (tap-disambiguation gecikmesi yok).
    private func itemGesture(_ item: CanvasItem, canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("deckCanvas"))
            .onChanged { value in
                if pressedItemID != item.id {
                    pressedItemID = item.id
                    pressSelect(item)
                }
                let dx = value.translation.width
                let dy = value.translation.height
                if draggingIDs.isEmpty, abs(dx) < 3, abs(dy) < 3 { return }
                if draggingIDs.isEmpty { draggingIDs = selectedIDs }
                dragOffset = value.translation
            }
            .onEnded { value in
                pressedItemID = nil
                let moved = draggingIDs
                draggingIDs = []
                dragOffset = .zero
                guard !moved.isEmpty else {
                    releaseSelect(item)
                    return
                }

                // Obje(ler) bir klasörün üzerine bırakıldıysa içine taşı.
                if currentFolderID == nil,
                   let target = dropTargetFolder(at: CGPoint(x: item.x + value.translation.width,
                                                             y: item.y + value.translation.height),
                                                 excluding: moved),
                   movedItemsCanNest(moved) {
                    moveToFolder(ids: moved, folderID: target.id)
                    return
                }

                var proj = liveProject
                for id in moved {
                    guard let idx = proj.items.firstIndex(where: { $0.id == id }) else { continue }
                    let maxX = max(60.0, canvasSize.width - 60)
                    let maxY = max(56.0, canvasSize.height - 70)
                    proj.items[idx].x = min(max(proj.items[idx].x + value.translation.width, 60), maxX)
                    proj.items[idx].y = min(max(proj.items[idx].y + value.translation.height, 56), maxY)
                }
                store.updateProject(proj)
            }
    }

    /// Mouse-down: Finder davranışı — seçili değilse hemen seç (⌘ toggle);
    /// seçili çoklu grubun üyesiyse dokunma (grup sürüklenebilsin).
    private func pressSelect(_ item: CanvasItem) {
        if renamingItemID != nil { commitPendingRename() }
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
            else { selectedIDs.insert(item.id) }
        } else if !selectedIDs.contains(item.id) {
            selectedIDs = [item.id]
        }
    }

    /// Mouse-up (sürükleme olmadan): çift tık aç; tek tıkta çoklu seçim
    /// bu öğeye daraltılır (Finder gibi).
    private func releaseSelect(_ item: CanvasItem) {
        let event = NSApp.currentEvent
        if (event?.clickCount ?? 1) >= 2 {
            doubleClick(item)
            return
        }
        if event?.modifierFlags.contains(.command) != true,
           selectedIDs.count > 1, selectedIDs.contains(item.id) {
            selectedIDs = [item.id]
        }
    }

    private func dropTargetFolder(at point: CGPoint, excluding: Set<UUID>) -> CanvasItem? {
        visibleItems.first { candidate in
            candidate.kind == .folder && !excluding.contains(candidate.id) &&
            abs(candidate.x - point.x) < 52 && abs(candidate.y - point.y) < 58
        }
    }

    /// Klasöre girebilir mi? Klasörün kendisi ve sabit Claude ikonu hariç
    /// her obje (Claude, servis, komut, terminal, web) klasöre atılabilir;
    /// yalnız klasörün kendisi iç içe girmez.
    private func movedItemsCanNest(_ ids: Set<UUID>) -> Bool {
        !ids.isEmpty && ids.allSatisfy { id in
            liveProject.items.first { $0.id == id }.map { $0.kind != .folder } ?? false
        }
    }

    private func moveToFolder(ids: Set<UUID>, folderID: UUID?) {
        var proj = liveProject
        var freed: [CanvasItem] = []
        for id in ids {
            guard let idx = proj.items.firstIndex(where: { $0.id == id }) else { continue }
            proj.items[idx].parentID = folderID
            freed.append(proj.items[idx])
        }
        // Hedef katmanda çakışmayan yeni yuvalar ver.
        let layer = proj.items.filter { $0.parentID == folderID && !ids.contains($0.id) }
        var placed = layer
        for f in freed {
            guard let idx = proj.items.firstIndex(where: { $0.id == f.id }) else { continue }
            let p = DeckFileService.freeSpot(among: placed)
            proj.items[idx].x = p.x
            proj.items[idx].y = p.y
            placed.append(proj.items[idx])
        }
        store.updateProject(proj)
        selectedIDs = []
    }

    // MARK: - Çift tık aksiyonları

    private func doubleClick(_ item: CanvasItem) {
        switch item.kind {
        case .claude:
            launchClaude(item)
        case .web:
            openWebTab(item)
        case .folder:
            currentFolderID = item.id
            selectedIDs = []
        case .terminal:
            switch item.mode ?? .shell {
            case .service: openServiceTab(item, startIfStopped: true)
            case .oneshot: runOneshot(item)
            case .shell: openShellTab(item)
            }
        }
    }

    /// Servisler workspace'e SEKME OLARAK GİRMEZ — kendi panellerinde yaşarlar
    /// (sekme kapatma ≠ servis durdurma karışıklığını kökten kaldırır).
    private func openServiceTab(_ item: CanvasItem, startIfStopped: Bool) {
        if startIfStopped, !pm.status(of: item.id).isRunning {
            pm.startService(item, project: liveProject)
        }
        workspace.selectService(item.id, in: project.id)
        workspace.openServicePanel(project.id, true)
    }

    private func runOneshot(_ item: CanvasItem) {
        guard let command = item.command, !command.isEmpty else { return }
        let tab = WorkspaceTab(kind: .oneshot, title: item.name, itemID: item.id)
        workspace.addTab(tab, to: project.id, activate: true)
        pm.runOneshot(tabID: tab.id, command: command, cwd: item.resolvedCwd(projectPath: liveProject.path))
        workspace.openWorkspace(project.id, true)
    }

    private func openShellTab(_ item: CanvasItem) {
        if let tab = workspace.tabs(for: project.id).first(where: { $0.kind == .shell && $0.itemID == item.id }) {
            workspace.select(tab.id, in: project.id)
        } else {
            let tab = WorkspaceTab(kind: .shell, title: item.name, itemID: item.id)
            workspace.addTab(tab, to: project.id, activate: true)
            pm.startShell(tabID: tab.id, cwd: item.resolvedCwd(projectPath: liveProject.path))
        }
        workspace.openWorkspace(project.id, true)
    }

    private func openWebTab(_ item: CanvasItem) {
        if let tab = workspace.tabs(for: project.id).first(where: { $0.kind == .web && $0.itemID == item.id }) {
            workspace.select(tab.id, in: project.id)
        } else {
            workspace.addTab(WorkspaceTab(kind: .web, title: item.name, itemID: item.id, url: item.url),
                             to: project.id, activate: true)
        }
        workspace.openWorkspace(project.id, true)
    }

    // MARK: - Sağ tık menüleri

    @ViewBuilder
    private func contextMenu(for item: CanvasItem, status: ServiceStatus) -> some View {
        if selectedIDs.contains(item.id), selectedIDs.count > 1 {
            groupMenu
        } else {
            singleMenu(for: item, status: status)
        }
    }

    private var selectedItems: [CanvasItem] {
        liveProject.items.filter { selectedIDs.contains($0.id) }
    }

    @ViewBuilder
    private var groupMenu: some View {
        let items = selectedItems
        let services = items.filter { $0.kind == .terminal && $0.mode == .service }
        let oneshots = items.filter { $0.kind == .terminal && $0.mode == .oneshot }

        if !services.isEmpty {
            Button("Seçilenleri Başlat (\(services.count) servis)") {
                for s in services where !pm.status(of: s.id).isRunning {
                    pm.startService(s, project: liveProject)
                }
            }
            Button("Seçilenleri Durdur") {
                for s in services where pm.status(of: s.id).isRunning { pm.stopService(s) }
            }
            Button("Seçilenleri Yeniden Başlat") {
                for s in services { pm.restartService(s, project: liveProject) }
            }
        }
        if !oneshots.isEmpty {
            Button("Arka Planda Çalıştır (\(oneshots.count) komut)") {
                for o in oneshots { pm.runBackground(o, project: liveProject) }
            }
        }
        if currentFolderID == nil, movedItemsCanNest(selectedIDs) {
            moveToFolderMenu(ids: selectedIDs)
        }
        Divider()
        Button("Kopyala") { copySelection() }
        Button("Sil", role: .destructive) { deleteItems(selectedIDs) }
    }

    @ViewBuilder
    private func singleMenu(for item: CanvasItem, status: ServiceStatus) -> some View {
        switch item.kind {
        case .claude:
            Button("Yeni Claude Sekmesi") { launchClaude(item) }
            Button("Geçmişi Sürdür...") { showResumeSheet = true }
            Button("AI ile Oluştur ✨") { createWithAI() }
            closedTabsMenu
            Divider()
            if item.parentID == nil { moveToFolderMenu(ids: [item.id]) }
            Button("Düzenle...") { editor = EditorContext(item: item, spawn: nil) }
            Button("Kopyala") { selectedIDs = [item.id]; copySelection() }
            Button("Sil", role: .destructive) { deleteItems([item.id]) }
        case .web:
            Button("Aç") { openWebTab(item) }
            Divider()
            commonItemButtons(item)
        case .folder:
            Button("Aç") { currentFolderID = item.id; selectedIDs = [] }
            let children = folderChildren(item)
            if !children.isEmpty {
                Divider()
                Button("Tümünü Başlat (\(children.count))") {
                    for c in children where !pm.status(of: c.id).isRunning {
                        pm.startService(c, project: liveProject)
                    }
                }
                Button("Tümünü Durdur") {
                    for c in children where pm.status(of: c.id).isRunning { pm.stopService(c) }
                }
                Button("Tümünü Yeniden Başlat") {
                    for c in children { pm.restartService(c, project: liveProject) }
                }
            }
            Divider()
            Button("Yeniden Adlandır") { beginRename(item) }
            Button("Kopyala") { selectedIDs = [item.id]; copySelection() }
            Button("Sil", role: .destructive) { deleteItems([item.id]) }
        case .terminal:
            switch item.mode ?? .shell {
            case .service:
                Button("Aç") { openServiceTab(item, startIfStopped: false) }
                if status.isRunning {
                    Button(status == .externalRunning ? "Durdur (dış süreç)" : "Durdur") { pm.stopService(item) }
                } else {
                    Button("Başlat") { pm.startService(item, project: liveProject) }
                }
                Button("Yeniden Başlat") { pm.restartService(item, project: liveProject) }
                if let port = item.port {
                    Button("Portu Boşalt (\(port))") {
                        pm.killPort(port, feedbackKey: item.id.uuidString)
                    }
                }
                Divider()
                commonItemButtons(item)
            case .oneshot:
                Button("Çalıştır") { runOneshot(item) }
                Button("Arka Planda Çalıştır") { pm.runBackground(item, project: liveProject) }
                Divider()
                commonItemButtons(item)
            case .shell:
                Button("Aç") { openShellTab(item) }
                Divider()
                commonItemButtons(item)
            }
        }
    }

    @ViewBuilder
    private func moveToFolderMenu(ids: Set<UUID>) -> some View {
        let folders = liveProject.items.filter { $0.kind == .folder }
        if !folders.isEmpty {
            Menu("Klasöre Taşı") {
                ForEach(folders) { f in
                    Button(f.name) { moveToFolder(ids: ids, folderID: f.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func commonItemButtons(_ item: CanvasItem) -> some View {
        if item.parentID == nil {
            moveToFolderMenu(ids: [item.id])
        } else {
            Button("Klasörden Çıkar") { moveToFolder(ids: [item.id], folderID: nil) }
        }
        Button("Yeniden Adlandır") { beginRename(item) }
        Button("Düzenle...") { editor = EditorContext(item: item, spawn: nil) }
        Button("Kopyala") { selectedIDs = [item.id]; copySelection() }
        Button("Sil", role: .destructive) { deleteItems([item.id]) }
    }

    @ViewBuilder
    private var closedTabsMenu: some View {
        let closedTabs = tabStore.closed[project.id] ?? []
        if !closedTabs.isEmpty {
            Divider()
            Menu("Kapatılmış Sekmeler") {
                ForEach(closedTabs) { ct in
                    Button(closedLabel(ct)) { reopenClosed(ct) }
                }
                Divider()
                Button("Listeyi Temizle") { tabStore.clearClosed(for: project.id) }
            }
        }
    }

    private func closedLabel(_ ct: ClaudeTabStore.ClosedTab) -> String {
        var label = ct.name ?? "Claude \(ct.number)"
        if let title = ct.title, !title.isEmpty {
            label += " — \(title)"
        }
        return label
    }

    private func reopenClosed(_ ct: ClaudeTabStore.ClosedTab) {
        tabStore.removeClosed(number: ct.number, for: project.id)
        let resume = ct.claudeSID.map { ClaudeResumeOptions(sessionID: $0) }
        ClaudeTabLauncher.open(project: liveProject, workspace: workspace, tabStore: tabStore,
                               pm: pm, resume: resume, customName: ct.name)
    }

    // MARK: - Kopyala / yapıştır / sil

    private func copySelection() {
        var out: [CanvasItem] = []
        for item in selectedItems {
            out.append(item)
            if item.kind == .folder {
                out.append(contentsOf: folderChildren(item))
            }
        }
        CanvasClipboard.items = out
    }

    private func paste(size: CGSize) {
        guard !CanvasClipboard.items.isEmpty else { return }
        var proj = liveProject
        var idMap: [UUID: UUID] = [:]
        var newIDs: Set<UUID> = []
        let existingNames = Set(proj.items.map { $0.name.lowercased() })

        // Önce klasörler (id eşlemesi çocuklardan önce kurulmalı).
        let src = CanvasClipboard.items
        let ordered = src.filter { $0.kind == .folder } + src.filter { $0.kind != .folder }
        var placedLayer = proj.items.filter { $0.parentID == currentFolderID }

        for src in ordered {
            var copy = src
            let newID = UUID()
            idMap[src.id] = newID
            copy.id = newID
            if existingNames.contains(copy.name.lowercased()) {
                copy.name += " kopyası"
            }
            if let oldParent = src.parentID, let mapped = idMap[oldParent] {
                copy.parentID = mapped   // kopyalanan klasörün içinde kal
            } else if copy.kind == .terminal, copy.mode == .service {
                copy.parentID = currentFolderID
            } else {
                // Klasör olmayanlar klasör içine yapıştırılamaz.
                copy.parentID = nil
                if copy.kind == .folder, currentFolderID != nil { continue }
            }
            if copy.parentID == currentFolderID {
                let p = DeckFileService.freeSpot(among: placedLayer)
                copy.x = p.x
                copy.y = p.y
                placedLayer.append(copy)
            }
            proj.items.append(copy)
            newIDs.insert(newID)
        }
        store.updateProject(proj)
        selectedIDs = newIDs
    }

    private func deleteItems(_ ids: Set<UUID>) {
        var proj = liveProject
        var toDelete = ids
        // Klasör silinirse çocukları köke bırak.
        for id in ids {
            guard let folder = proj.items.first(where: { $0.id == id }), folder.kind == .folder else { continue }
            for idx in proj.items.indices where proj.items[idx].parentID == id {
                proj.items[idx].parentID = nil
            }
        }

        for id in toDelete {
            guard let item = proj.items.first(where: { $0.id == id }) else { continue }
            if item.kind == .terminal, item.mode == .service, pm.status(of: item.id).isOwnedByDeck {
                pm.stopService(item)
            }
            for tab in workspace.tabs(for: project.id) where tab.itemID == id {
                pm.closeTab(tabID: tab.id, killTmux: false)
                workspace.closeTab(tab.id, in: project.id)
            }
        }
        let removed = proj.items.filter { toDelete.contains($0.id) }
        proj.items.removeAll { toDelete.contains($0.id) }
        store.updateProject(proj)
        selectedIDs = []

        // deck.json'dan da düşür — yoksa bir sonraki sync silinenleri diriltir.
        let path = proj.path
        Task.detached(priority: .utility) {
            DeckFileService.removeEntries(matching: removed, projectPath: path)
        }
    }

    // MARK: - Yeniden adlandırma

    private func beginRename(_ item: CanvasItem) {
        renamingItemID = item.id
        renameText = item.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            renameFocused = true
        }
    }

    private func commitRename(_ item: CanvasItem) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != item.name {
            var updated = item
            updated.name = trimmed
            store.upsertItem(updated, in: project.id)
            // deck.json'daki adı da taşı — yoksa eski adla ikon türer.
            let path = liveProject.path
            let old = item.name
            Task.detached(priority: .utility) {
                DeckFileService.renameEntry(oldName: old, newName: trimmed, kind: item.kind,
                                            mode: item.mode, projectPath: path)
            }
        }
        renamingItemID = nil
        renameText = ""
    }

    private func commitPendingRename() {
        guard let id = renamingItemID,
              let item = liveProject.items.first(where: { $0.id == id }) else {
            renamingItemID = nil
            return
        }
        commitRename(item)
    }

    private func cancelRename() {
        renamingItemID = nil
        renameText = ""
    }

    // MARK: - Klavye

    private func handleKey(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if cmd {
            switch chars {
            case "a":
                selectedIDs = Set(visibleItems.map(\.id))
                return true
            case "c":
                guard !selectedIDs.isEmpty else { return false }
                copySelection()
                return true
            case "v":
                guard !CanvasClipboard.items.isEmpty else { return false }
                paste(size: CGSize(width: 1200, height: 800))
                return true
            case "p":
                searchOpen = true
                return true
            default:
                if event.keyCode == 51 { // ⌘⌫
                    guard !selectedIDs.isEmpty else { return false }
                    deleteItems(selectedIDs)
                    return true
                }
                return false
            }
        }

        switch event.keyCode {
        case 49: // Space — Quick Look önizleme (aç/kapat)
            if quickLookID != nil { quickLookID = nil; return true }
            guard selectedIDs.count == 1, let id = selectedIDs.first,
                  liveProject.items.contains(where: { $0.id == id }) else { return false }
            quickLookID = id
            return true
        case 36, 76: // Enter — seçiliyi yeniden adlandır
            guard selectedIDs.count == 1,
                  let item = liveProject.items.first(where: { $0.id == selectedIDs.first! })
            else { return false }
            beginRename(item)
            return true
        case 53: // Esc
            if quickLookID != nil { quickLookID = nil; return true }
            if searchOpen { searchOpen = false; return true }
            if renamingItemID != nil { cancelRename(); return true }
            if !selectedIDs.isEmpty { selectedIDs = []; return true }
            if currentFolderID != nil { currentFolderID = nil; return true }
            return false
        default:
            return false
        }
    }

    // MARK: - Arama sonucu

    private func openSearchResult(_ item: CanvasItem) {
        searchOpen = false
        if let parent = item.parentID {
            currentFolderID = parent
        } else if item.kind != .folder {
            currentFolderID = nil
        }
        selectedIDs = [item.id]
        doubleClick(item)
    }
}

// MARK: - Quick Look önizleme (Space)

private struct QuickLookOverlay: View {
    let item: CanvasItem
    let project: Project
    let status: ServiceStatus
    let onClose: () -> Void

    private var kindLabel: String {
        switch item.kind {
        case .folder: return "Klasör"
        case .web: return "Web"
        case .claude: return "Claude"
        case .terminal:
            switch item.mode ?? .shell {
            case .service: return "Servis"
            case .oneshot: return "Komut"
            case .shell: return "Terminal"
            }
        }
    }

    private var resolvedCwd: String {
        (item.resolvedCwd(projectPath: project.path) as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        ZStack {
            // Karartılmış zemin — tıklayınca kapanır.
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    if item.kind == .claude {
                        ClaudeIconView(size: 44)
                    } else {
                        IconView(spec: item.icon, size: 44)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.system(size: 17, weight: .bold))
                        HStack(spacing: 6) {
                            Text(kindLabel)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.2)))
                            if item.kind == .terminal, item.mode == .service {
                                HStack(spacing: 4) {
                                    Circle().fill(status.color).frame(width: 7, height: 7)
                                    Text(status.label)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(status.color)
                                }
                            }
                        }
                    }
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    infoRow("Çalışma dizini", systemImage: "folder", value: resolvedCwd)
                    if let port = item.port {
                        infoRow("Port", systemImage: "network", value: ":\(port)",
                                tint: Color(hex: "#38BDF8"))
                    }
                    if item.kind == .web, let url = item.url {
                        infoRow("Adres", systemImage: "link", value: url, tint: Color(hex: "#38BDF8"))
                    }
                    if item.kind == .terminal, let cmd = item.command, !cmd.isEmpty {
                        infoRow("Komut", systemImage: "chevron.right", value: cmd,
                                tint: Color(hex: "#8FE388"), mono: true)
                    }
                    if item.kind == .claude {
                        if let cmd = item.command, !cmd.isEmpty {
                            infoRow("Başlangıç komutu", systemImage: "chevron.right", value: cmd,
                                    tint: Color(hex: "#8FE388"), mono: true)
                            infoRow("Otomatik çalıştır", systemImage: "play.circle",
                                    value: item.autoStart ? "Evet — açılınca hemen gönderilir"
                                                          : "Hayır — girdi kutusuna yazılır")
                        } else {
                            infoRow("Başlangıç komutu", systemImage: "chevron.right",
                                    value: "yok — boş açılır")
                        }
                    }
                    if item.kind == .terminal, item.mode == .service {
                        HStack(spacing: 8) {
                            Image(systemName: status.isRunning ? "checkmark.circle.fill" : "pause.circle.fill")
                                .foregroundStyle(status.isRunning ? .green : .secondary)
                            Text(status.isRunning
                                 ? (item.port != nil ? "Çalışıyor — :\(item.port!) dinleniyor" : "Çalışıyor")
                                 : "Şu an çalışmıyor")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(status.isRunning ? .green : .secondary)
                        }
                    }
                }
                .padding(16)

                Text("Kapatmak için Space veya Esc")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 12)
            }
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThickMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
    }

    private func infoRow(_ label: String, systemImage: String, value: String,
                         tint: SwiftUI.Color = .primary, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - AI ile Oluştur — opsiyonel yönlendirme notu

private struct AIPromptSheet: View {
    let onStart: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ClaudeIconView(size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI ile Oluştur")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Claude projeyi tarar, servis ve komutları deck.json'a yazar; Deck ikonlara çevirir.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Claude'a not (opsiyonel)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("ör. sadece backend servislerine odaklan, testleri ekleme…",
                          text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .focused($focused)
            }

            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Başlat") {
                    dismiss()
                    onStart(note.isEmpty ? nil : note)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { focused = true }
    }
}

// MARK: - ⌘P arama paleti

private struct SearchPalette: View {
    let project: Project
    let onClose: () -> Void
    let onPick: (CanvasItem) -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [CanvasItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = project.items
        guard !q.isEmpty else { return Array(all.prefix(8)) }
        return Array(all.filter { $0.name.lowercased().contains(q) }.prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Öğe ara…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit {
                        if let first = results.first { onPick(first) } else { onClose() }
                    }
                    .onExitCommand { onClose() }
            }
            .padding(12)

            if !results.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(results) { item in
                        Button {
                            onPick(item)
                        } label: {
                            HStack(spacing: 10) {
                                if item.kind == .claude {
                                    ClaudeIconView(size: 22)
                                } else if item.kind == .folder {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(item.icon.color)
                                        .frame(width: 22)
                                } else {
                                    IconView(spec: item.icon, size: 22)
                                }
                                Text(item.name)
                                    .font(.system(size: 13))
                                Spacer()
                                Text(kindLabel(item))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThickMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .onAppear { focused = true }
    }

    private func kindLabel(_ item: CanvasItem) -> String {
        switch item.kind {
        case .folder: return "klasör"
        case .web: return "web"
        case .claude: return "claude"
        case .terminal:
            switch item.mode ?? .shell {
            case .service: return "servis"
            case .oneshot: return "komut"
            case .shell: return "terminal"
            }
        }
    }
}
