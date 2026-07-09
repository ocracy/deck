import SwiftUI
import AppKit

/// Servis paneli — workspace'ten ayrı, yalnız servislerin yaşadığı alan.
/// Sekmelerde çarpı YOKTUR: servis bir sekme değil süreçtir; kontroller
/// durdur/yeniden başlat'tır. Duran servisin sekmesi kendiliğinden düşer.
struct ServicePanelView: View {
    let project: Project
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var pm: ProcessManager

    /// "Servisler" başlığına basınca açılan genel bakış (tüm servisler grid).
    @State private var overview = false

    private var services: [CanvasItem] {
        project.items.filter { $0.kind == .terminal && $0.mode == .service }
    }

    /// Panelde sekmesi görünenler: durmuş olmayan her servis (çökmüş dahil —
    /// kullanıcı hata çıktısını görebilmeli).
    private var activeServices: [CanvasItem] {
        services.filter { pm.status(of: $0.id) != .stopped }
    }

    private var activeID: UUID? {
        if overview { return nil }
        if let id = workspace.activeService[project.id],
           activeServices.contains(where: { $0.id == id }) {
            return id
        }
        return activeServices.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            content
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Üst çubuk

    private var bar: some View {
        HStack(spacing: 8) {
            // "Servisler" başlığı: tıklanınca tüm servislere genel bakış.
            Button {
                overview = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(overview ? Color.accentColor : Color.green)
                    Text("All Services")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(overview ? Color.accentColor : .secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(overview ? Color.accentColor.opacity(0.15) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .help("Overview of all services")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(activeServices) { item in
                        servicePill(item)
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if activeServices.contains(where: { pm.status(of: $0.id).isRunning }) {
                Button {
                    for s in activeServices where pm.status(of: s.id).isRunning {
                        pm.stopService(s)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Stop All")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.12)))
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func servicePill(_ item: CanvasItem) -> some View {
        let status = pm.status(of: item.id)
        let isActive = item.id == activeID

        HStack(spacing: 7) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(item.name)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
            if let port = item.port {
                Text(verbatim: ":\(port)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Button {
                pm.restartService(item, project: project)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.plain)
            .help("Restart")

            if status.isRunning {
                Button {
                    pm.stopService(item)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.85))
                        .frame(width: 15, height: 15)
                }
                .buttonStyle(.plain)
                .help(status == .externalRunning ? "Stop (external process)" : "Stop")
            } else {
                Button {
                    pm.startService(item, project: project)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 15, height: 15)
                }
                .buttonStyle(.plain)
                .help("Start")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2),
                        lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            overview = false
            workspace.selectService(item.id, in: project.id)
        }
        .help("\(item.name) — \(status.label)")
    }

    // MARK: - İçerik

    /// Genel bakış: overview seçili, hiç aktif servis yok, ya da hiç
    /// servis çalışmıyorken açılışta doğrudan tüm servisler görünür.
    private var showsOverview: Bool {
        overview || activeServices.isEmpty
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            // Terminaller her zaman mount kalır (scrollback yaşasın); overview
            // üstlerine bindirilir.
            ForEach(activeServices) { item in
                TerminalHostView(key: item.id.uuidString, manager: pm)
                    .opacity(!showsOverview && item.id == activeID ? 1 : 0)
                    .allowsHitTesting(!showsOverview && item.id == activeID)
            }
            if showsOverview {
                overviewGrid
            }
        }
    }

    /// Tüm servisleri durumlarıyla gösteren grid — hem "genel bakış" hem
    /// boş durum. Çalışana tıkla → terminaline git; durmuşa tıkla → başlat.
    private var overviewGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 14)]
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(services.isEmpty ? "No services defined" : "Services")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if services.contains(where: { pm.status(of: $0.id) == .stopped }) {
                        Button {
                            for s in services where pm.status(of: s.id) == .stopped {
                                pm.startService(s, project: project)
                            }
                        } label: {
                            Label("Start All", systemImage: "play.fill")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.green)
                    }
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(services) { item in
                        overviewCard(item)
                    }
                }
                if services.isEmpty {
                    Text("Right-click on the desktop → “New Service” to add one,\nor choose “Create with AI”.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func overviewCard(_ item: CanvasItem) -> some View {
        let status = pm.status(of: item.id)
        return HStack(spacing: 11) {
            IconView(spec: item.icon, size: 34)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(status.color)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(status.label)
                        .font(.system(size: 10))
                        .foregroundStyle(status.color)
                    if let port = item.port {
                        Text(verbatim: ":\(port)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 4)

            if status.isRunning {
                cardButton("stop.fill", .red) { pm.stopService(item) }
            } else {
                cardButton("play.fill", .green) {
                    pm.startService(item, project: project)
                    overview = false
                    workspace.selectService(item.id, in: project.id)
                }
            }
            cardButton("arrow.clockwise", .secondary) {
                pm.restartService(item, project: project)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            // Çalışıyorsa terminaline git; değilse başlat + git.
            if !status.isRunning { pm.startService(item, project: project) }
            overview = false
            workspace.selectService(item.id, in: project.id)
        }
        .help("\(item.name) — \(status.label)")
    }

    private func cardButton(_ symbol: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.secondary.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}
