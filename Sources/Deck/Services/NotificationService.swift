import Foundation
import AppKit

/// Sistem bildirimi + ses + Dock badge.
///
/// Deck ad-hoc imzalı dağıtıldığından `UNUserNotificationCenter` güvenilmezdir
/// (provizyonlu bundle ve izin ister). `osascript display notification` hiçbir
/// entitlement gerektirmeden banner + sesi tek fire-and-forget çağrıyla verir.
enum NotificationService {

    static func notify(title: String, subtitle: String, body: String, sound: String = "Glass") {
        var script = "display notification \(quote(body)) with title \(quote(title))"
        if !subtitle.isEmpty {
            script += " subtitle \(quote(subtitle))"
        }
        if !sound.isEmpty {
            script += " sound name \(quote(sound))"
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        // Fire-and-forget: osascript bu Process nesnesinden uzun yaşar.
        try? proc.run()
    }

    /// Dock badge — 0 için temizlenir.
    @MainActor
    static func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    static func playSound(_ name: String) {
        NSSound(named: name)?.play()
    }

    /// AppleScript string literal'i olarak alıntıla.
    private static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
