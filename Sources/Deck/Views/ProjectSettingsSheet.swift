import SwiftUI
import AppKit

/// Per-project settings: root directory and Claude behaviour.
struct ProjectSettingsSheet: View {
    let project: Project
    let onSave: (Project) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var path: String
    @State private var notifyOnEnd: Bool
    @State private var soundOnEnd: Bool
    @State private var soundName: String

    private static let sounds = ["Glass", "Ping", "Pop", "Hero", "Submarine", "Blow", "Funk", "Tink"]

    init(project: Project, onSave: @escaping (Project) -> Void) {
        self.project = project
        self.onSave = onSave
        _path = State(initialValue: project.path)
        _notifyOnEnd = State(initialValue: project.settings.notifyOnSessionEnd)
        _soundOnEnd = State(initialValue: project.settings.soundOnSessionEnd)
        _soundName = State(initialValue: project.settings.soundName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                IconView(spec: project.icon, size: 30)
                Text("\(project.name) — Settings")
                    .font(.system(size: 15, weight: .semibold))
            }

            // Root directory
            section("Root directory") {
                HStack(spacing: 8) {
                    TextField("/path/to/project", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button {
                        pickDirectory()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Choose directory")
                }
                Text("Used as the working directory for terminals, services and Claude.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Claude
            section("Claude") {
                Toggle("Notify when a session goes idle", isOn: $notifyOnEnd)
                    .font(.system(size: 12))
                Toggle("Play a sound when a session goes idle", isOn: $soundOnEnd)
                    .font(.system(size: 12))
                if soundOnEnd {
                    HStack(spacing: 8) {
                        Text("Sound")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $soundName) {
                            ForEach(Self.sounds, id: \.self) { s in
                                Text(s).tag(s)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        Button {
                            NotificationService.playSound(soundName)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Preview")
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func save() {
        var updated = project
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { updated.path = trimmed }
        updated.settings.notifyOnSessionEnd = notifyOnEnd
        updated.settings.soundOnSessionEnd = soundOnEnd
        updated.settings.soundName = soundName
        onSave(updated)
        dismiss()
    }
}
