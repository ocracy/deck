import SwiftUI

/// Workspace ↔ Servis paneli arasında hızlı geçiş segmenti.
/// Aktif olan vurgulanır; aktif segmente tekrar basmak paneli kapatıp
/// masaüstüne döndürür (⌘B/⌘J ile aynı toggle mantığı).
struct PanelSwitcher: View {
    let projectID: UUID
    @ObservedObject var workspace: WorkspaceStore

    private var isWorkspace: Bool { workspace.workspaceOpen[projectID] ?? false }
    private var isService: Bool { workspace.servicePanelOpen[projectID] ?? false }

    var body: some View {
        HStack(spacing: 2) {
            segment("Workspace", "rectangle.on.rectangle", active: isWorkspace,
                    tip: "Workspace (⌘B) — press again when open: desktop") {
                workspace.openWorkspace(projectID, !isWorkspace)
            }
            segment("Services", "bolt.horizontal.fill", active: isService,
                    tip: "Services (⌘J) — press again when open: desktop") {
                workspace.openServicePanel(projectID, !isService)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.10)))
    }

    private func segment(_ title: String, _ icon: String, active: Bool,
                         tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(active ? Color.accentColor.opacity(0.22) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}
