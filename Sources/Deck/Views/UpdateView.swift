import SwiftUI

/// Sağ üstteki güncelleme butonunun popover içeriği. `UpdateChecker`'ın her
/// state'ini yansıtır; popover açıldığında bekleyen bir işlem yoksa taze
/// kontrol tetikler.
struct UpdateView: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .padding(14)
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear {
            switch checker.state {
            case .idle, .upToDate, .error:
                Task { await checker.checkNow(force: true) }
            case .checking, .available, .downloading, .installing:
                break
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: headerIcon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(headerTint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    .font(.headline)
                Text("Yüklü sürüm: \(checker.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var headerIcon: String {
        switch checker.state {
        case .available:                return "arrow.down.circle.fill"
        case .downloading, .installing: return "arrow.down.circle"
        case .upToDate:                 return "checkmark.seal.fill"
        case .error:                    return "exclamationmark.triangle.fill"
        case .checking:                 return "arrow.triangle.2.circlepath"
        case .idle:                     return "arrow.down.circle"
        }
    }

    private var headerTint: Color {
        switch checker.state {
        case .available:    return .accentColor
        case .upToDate:     return .green
        case .error:        return .orange
        default:            return .secondary
        }
    }

    private var headerTitle: String {
        switch checker.state {
        case .available(let r):     return "Deck \(r.version) mevcut"
        case .downloading:          return "Güncelleme indiriliyor"
        case .installing:           return "Yeniden başlatılıyor"
        case .upToDate:             return "Deck güncel"
        case .checking:             return "Kontrol ediliyor"
        case .error:                return "Güncelleme hatası"
        case .idle:                 return "Güncellemeler"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch checker.state {
        case .idle, .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("GitHub release'leri kontrol ediliyor…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }

        case .upToDate:
            Label("Çalıştırdığın sürüm en güncel olanı. Yeni bir release yayınlandığında burada görünecek.",
                  systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

        case .available(let release):
            availableContent(release: release)

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                Text("Deck.zip indiriliyor…")
                    .font(.subheadline)
                ProgressView(value: progress)
                Text("%\(Int(progress * 100))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                installLogView
            }

        case .installing:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Yeni sürüm kuruluyor ve uygulama yeniden başlatılıyor…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                installLogView
                Text("Donduysa aşağıdaki \"Zorla Kapat ve Kur\" butonuna bas — Deck hemen kapanır, helper script kalan işlemi yapar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Text("İnternet bağlantını kontrol et veya github.com/ocracy/deck adresinden manuel indir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Güncelleyicinin attığı her adımın kaydırılabilir zaman çizelgesi;
    /// en son satır görünür kalsın diye otomatik alta kayar.
    @ViewBuilder
    private var installLogView: some View {
        if !checker.installLog.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(checker.installLog.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 120)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                .onChange(of: checker.installLog.count) { _ in
                    if let last = checker.installLog.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func availableContent(release: UpdateChecker.Release) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(release.tag)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Text("• \(release.publishedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !release.notes.isEmpty {
                Text("Sürüm notları")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(release.notes)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            switch checker.state {
            case .available:
                Button {
                    Task { await checker.downloadAndInstall() }
                } label: {
                    Label("Şimdi Güncelle", systemImage: "arrow.down.circle.fill")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)

            case .downloading:
                Text("İndirme sürüyor…")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .installing:
                Button {
                    checker.forceQuitNow()
                } label: {
                    Label("Zorla Kapat ve Kur", systemImage: "bolt.fill")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.orange)

            case .error:
                Button("Tekrar Dene") {
                    Task { await checker.checkNow(force: true) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)

            case .idle, .checking, .upToDate:
                Button("Tekrar Kontrol Et") {
                    Task { await checker.checkNow(force: true) }
                }
                .disabled({ if case .checking = checker.state { return true }; return false }())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
