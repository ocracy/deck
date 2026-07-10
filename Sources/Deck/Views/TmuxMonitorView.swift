import SwiftUI

/// Sistemde açık tmux oturumlarını gösterir ve temizlemeyi sağlar.
/// Bir Claude sekmesi = bir tmux oturumu; uygulama kapansa da yaşarlar,
/// bu yüzden zamanla birikip sistemi yorabilirler. Buradan görülür/temizlenir.
struct TmuxMonitorView: View {
    let projects: [Project]
    /// Bir oturum öldürüldüğünde HomeView'daki rozeti tazelemek için.
    var onChange: () -> Void = {}

    @State private var sessions: [TmuxService.Session] = []
    @State private var rawCount = 0
    @State private var confirmKillAll = false

    /// shortID → proje adı; oturumu bir projeye bağlamak için.
    private var projectNames: [String: String] {
        Dictionary(projects.map { ($0.shortID, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// Deck-etiketli ama açık bir projeye eşleşmeyen oturumlar (silinmiş projeler).
    private var orphans: [TmuxService.Session] {
        sessions.filter { projectNames[$0.projectID] == nil }
    }

    /// Açık projelere ait oturumlar, proje adına göre gruplu.
    private var grouped: [(name: String, sessions: [TmuxService.Session])] {
        let known = sessions.filter { projectNames[$0.projectID] != nil }
        let byProject = Dictionary(grouping: known) { projectNames[$0.projectID] ?? "?" }
        return byProject
            .map { (name: $0.key, sessions: $0.value.sorted { $0.number < $1.number }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// listSessions'ın göremediği etiketsiz ham oturumlar.
    private var untagged: Int { max(0, rawCount - sessions.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)

            if sessions.isEmpty && untagged == 0 {
                Text("Açık tmux oturumu yok.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(grouped, id: \.name) { group in
                            sectionView(title: group.name, sessions: group.sessions, orphan: false)
                        }
                        if !orphans.isEmpty {
                            sectionView(title: "Silinmiş projeler", sessions: orphans, orphan: true)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 300)
            }

            Divider().opacity(0.3)
            footer
        }
        .frame(width: 320)
        .onAppear(perform: reload)
    }

    // MARK: - Bölümler

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("tmux Oturumları")
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Yenile")
        }
        .padding(12)
    }

    private var subtitle: String {
        var s = "\(rawCount) oturum"
        if untagged > 0 { s += " · \(untagged) etiketsiz" }
        return s
    }

    private func sectionView(title: String, sessions: [TmuxService.Session], orphan: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(orphan ? Color.orange : .secondary)
                    .textCase(.uppercase)
                Spacer()
                if orphan {
                    Button("Temizle") { sessions.forEach { TmuxService.kill($0.name) }; reload() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.orange)
                }
            }
            .padding(.horizontal, 12)

            ForEach(sessions) { session in
                row(session)
            }
        }
    }

    private func row(_ session: TmuxService.Session) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.attached ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(session.customName ?? "Claude \(session.number)")
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            Button {
                TmuxService.kill(session.name)
                reload()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Bu oturumu kapat")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private var footer: some View {
        HStack {
            if confirmKillAll {
                Text("Tüm oturumlar kapatılacak.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Vazgeç") { confirmKillAll = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                Button("Onayla") {
                    TmuxService.killServer()
                    confirmKillAll = false
                    reload()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
            } else {
                Button {
                    confirmKillAll = true
                } label: {
                    Label("Tümünü kapat", systemImage: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .disabled(rawCount == 0)
                .help("tmux sunucusunu tamamen kapatır — açık Claude sekmeleri de dahil")
                Spacer()
            }
        }
        .padding(12)
    }

    // MARK: - Veri

    private func reload() {
        sessions = TmuxService.listSessions()
        rawCount = TmuxService.rawSessionNames().count
        onChange()
    }
}
