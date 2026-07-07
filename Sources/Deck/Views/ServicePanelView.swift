import SwiftUI
import AppKit

/// Servis paneli — workspace'ten ayrı, yalnız servislerin yaşadığı alan.
/// Sekmelerde çarpı YOKTUR: servis bir sekme değil süreçtir; kontroller
/// durdur/yeniden başlat'tır. Duran servisin sekmesi kendiliğinden düşer.
struct ServicePanelView: View {
    let project: Project
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var pm: ProcessManager

    private var services: [CanvasItem] {
        project.items.filter { $0.kind == .terminal && $0.mode == .service }
    }

    /// Panelde sekmesi görünenler: durmuş olmayan her servis (çökmüş dahil —
    /// kullanıcı hata çıktısını görebilmeli).
    private var activeServices: [CanvasItem] {
        services.filter { pm.status(of: $0.id) != .stopped }
    }

    private var activeID: UUID? {
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
            Button {
                workspace.openServicePanel(project.id, false)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
            .help("Masaüstüne dön")

            HStack(spacing: 5) {
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.green)
                Text("Servisler")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.trailing, 4)

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
                        Text("Tümünü Durdur")
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
            .help("Yeniden başlat")

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
                .help(status == .externalRunning ? "Durdur (dış süreç)" : "Durdur")
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
                .help("Başlat")
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
            workspace.selectService(item.id, in: project.id)
        }
        .help("\(item.name) — \(status.label)")
    }

    // MARK: - İçerik

    @ViewBuilder
    private var content: some View {
        if activeServices.isEmpty {
            emptyState
        } else {
            ZStack {
                ForEach(activeServices) { item in
                    TerminalHostView(key: item.id.uuidString, manager: pm)
                        .opacity(item.id == activeID ? 1 : 0)
                        .allowsHitTesting(item.id == activeID)
                }
            }
        }
    }

    /// Hiç servis çalışmıyorsa: tanımlı servisleri hızlı-başlat listesi olarak sun.
    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "bolt.horizontal")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Çalışan servis yok")
                .font(.title3)
                .foregroundStyle(.secondary)

            if !services.isEmpty {
                VStack(spacing: 6) {
                    ForEach(services) { item in
                        Button {
                            pm.startService(item, project: project)
                            workspace.selectService(item.id, in: project.id)
                        } label: {
                            HStack(spacing: 10) {
                                IconView(spec: item.icon, size: 26)
                                Text(item.name)
                                    .font(.system(size: 13, weight: .medium))
                                if let port = item.port {
                                    Text(verbatim: ":\(port)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(width: 320)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
