import SwiftUI
import AppKit

/// Proje dizinindeki geçmiş Claude oturumlarını listeleyen seçici.
/// `claude --resume` etkileşimli seçicisini andırır: arama kutusu, aktif satırda
/// `>` işareti, iki satırlık kayıt (önizleme + göreli zaman · boyut · kısa uuid).
struct ClaudeResumeSheet: View {
    let project: Project
    let onResume: (ClaudeResumeOptions) -> Void

    @Environment(\.dismiss) private var dismiss

    enum LoadPhase {
        case loading
        case loaded([ClaudeSession])
        case empty
    }

    @State private var phase: LoadPhase = .loading
    @State private var selectedID: String?
    @State private var forkSession = false
    @State private var initialPrompt = ""
    @State private var searchQuery = ""

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        f.includesUnit = true
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            content
            Divider()
            optionsAndFooter
        }
        .frame(width: 720, height: 620)
        .background(Color(NSColor.windowBackgroundColor))
        .task { await load() }
    }

    // MARK: - Başlık

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.purple.opacity(0.15))
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.purple)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Oturumu Sürdür")
                        .font(.system(size: 15, weight: .semibold))
                    Text(verbatim: countLabel)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(displayPath(project.path))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(project.path)
                    .onTapGesture {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: (project.path as NSString).expandingTildeInPath)]
                        )
                    }
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var countLabel: String {
        switch phase {
        case .loaded(let sessions):
            let filtered = filteredSessions(in: sessions).count
            return filtered == sessions.count ? "(\(sessions.count))" : "(\(filtered) / \(sessions.count))"
        case .empty:
            return "(0)"
        case .loading:
            return ""
        }
    }

    // MARK: - Arama

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Ara…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
    }

    // MARK: - Liste

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Oturum geçmişi okunuyor…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            placeholder(icon: "tray",
                        title: "Önceki oturum yok",
                        message: "Claude Code bu dizinde henüz bir oturum kaydetmemiş.")
        case .loaded(let sessions):
            let filtered = filteredSessions(in: sessions)
            if filtered.isEmpty {
                placeholder(icon: "magnifyingglass",
                            title: "Eşleşme yok",
                            message: "Bu dizinde \"\(searchQuery)\" ile eşleşen oturum bulunamadı.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { session in
                            sessionRow(session)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func placeholder(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func sessionRow(_ session: ClaudeSession) -> some View {
        let isSelected = (selectedID == session.id)
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: isSelected ? ">" : " ")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(isSelected ? Color.accentColor : .clear)
                .frame(width: 12, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.summary.isEmpty ? "(mesaj yok)" : session.summary)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(session.summary.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(relativeDate(session.lastActivity))
                    Text(verbatim: "·").foregroundStyle(.secondary.opacity(0.5))
                    Text(humanSize(session.fileSizeBytes))
                    Text(verbatim: "·").foregroundStyle(.secondary.opacity(0.5))
                    Text(verbatim: String(session.id.prefix(8)).lowercased())
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedID = session.id }
    }

    // MARK: - Seçenekler + alt bar

    @ViewBuilder
    private var optionsAndFooter: some View {
        VStack(spacing: 0) {
            if case .loaded = phase {
                HStack(alignment: .top, spacing: 16) {
                    Toggle(isOn: $forkSession) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Yeni oturum olarak çatalla")
                                .font(.system(size: 12, weight: .medium))
                            Text("Orijinal konuşma olduğu gibi kalır.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("İsteğe bağlı başlangıç mesajı")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.4)
                        TextField("(boş = sadece devam et)", text: $initialPrompt)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(NSColor.textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                            )
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                Divider()
            }

            HStack {
                Spacer()
                Button("Vazgeç", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sürdür") { confirmResume() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedID == nil)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color(NSColor.underPageBackgroundColor))
        }
    }

    // MARK: - Davranış

    private func confirmResume() {
        guard let id = selectedID else { return }
        let trimmed = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let opts = ClaudeResumeOptions(sessionID: id,
                                       fork: forkSession,
                                       initialPrompt: trimmed.isEmpty ? nil : trimmed)
        onResume(opts)
        dismiss()
    }

    private func load() async {
        phase = .loading
        let cwd = project.path
        let sessions = await Task.detached(priority: .userInitiated) {
            ClaudeSessionService.scan(cwd: cwd)
        }.value
        phase = sessions.isEmpty ? .empty : .loaded(sessions)
        if selectedID == nil {
            selectedID = sessions.first?.id
        }
    }

    private func filteredSessions(in sessions: [ClaudeSession]) -> [ClaudeSession] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter {
            $0.summary.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
    }

    // MARK: - Biçimleme

    private func relativeDate(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        fmt.locale = Locale(identifier: "tr_TR")
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    private func humanSize(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
