import SwiftUI

/// Workspace ↔ Servis paneli arasında hızlı geçiş segmenti.
/// Her iki panelin üst barında aynı görünür; aktif olan vurgulanır,
/// masaüstü ise her ikisini kapatır.
struct PanelSwitcher: View {
    let projectID: UUID
    @ObservedObject var workspace: WorkspaceStore

    private var isWorkspace: Bool { workspace.workspaceOpen[projectID] ?? false }
    private var isService: Bool { workspace.servicePanelOpen[projectID] ?? false }

    var body: some View {
        HStack(spacing: 2) {
            segment("Masaüstü", "square.grid.2x2", active: !isWorkspace && !isService) {
                workspace.openWorkspace(projectID, false)
                workspace.openServicePanel(projectID, false)
            }
            segment("Workspace", "rectangle.on.rectangle", active: isWorkspace) {
                workspace.openWorkspace(projectID, true)
            }
            segment("Servisler", "bolt.horizontal.fill", active: isService) {
                workspace.openServicePanel(projectID, true)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.10)))
    }

    private func segment(_ title: String, _ icon: String, active: Bool,
                         _ action: @escaping () -> Void) -> some View {
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
    }
}
