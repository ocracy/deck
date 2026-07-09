import Foundation
import SwiftUI
import AppKit

/// GitHub Releases üzerinden güncelleme denetleyicisi. Yeni sürüm bulunca
/// `Deck.zip`'i indirir, ditto ile açar ve çalışan `Deck.app` bundle'ını
/// detached bir helper script ile değiştirip uygulamayı yeniden başlatır.
/// (Sparkle imzalı feed ister; ad-hoc imzalı Deck bunu üretemez.)
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String     // "1.2.0" — baştaki 'v' atılmış
        let tag: String         // "v1.2.0" — GitHub'daki orijinal tag
        let notes: String
        let zipURL: URL
        let publishedAt: Date
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)    // 0.0 — 1.0
        case installing
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheckedAt: Date?
    /// Kurulum sırasında UpdateView'da gösterilen adım adım log.
    /// Her indirme/kurulum döngüsünün başında sıfırlanır.
    @Published private(set) var installLog: [String] = []

    let currentVersion: String

    private let owner = "ocracy"
    private let repo = "deck"
    private let assetName = "deck.zip"      // küçük harfle kıyaslanır
    private let lastCheckKey = "Deck.UpdateChecker.lastCheck"
    private let throttle: TimeInterval = 24 * 60 * 60

    private var downloadCoordinator: DownloadCoordinator?

    private init() {
        self.currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        if let stored = UserDefaults.standard.object(forKey: lastCheckKey) as? Date {
            self.lastCheckedAt = stored
        }
    }

    // MARK: - Log

    /// `HH:mm:ss` önekiyle tek satır ekler; UI'da timeline gibi okunur.
    private func log(_ message: String) {
        let ts = Self.logFormatter.string(from: Date())
        Task { @MainActor in
            self.installLog.append("[\(ts)] \(message)")
        }
        NSLog("[Deck.Updater] %@", message)
    }

    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Check

    /// Sürüm kontrolü. `force: false` iken 24 saatlik throttle uygulanır
    /// (otomatik kontroller için); `force: true` kullanıcı tetiklemesidir.
    func checkNow(force: Bool) async {
        if !force, let last = lastCheckedAt, Date().timeIntervalSince(last) < throttle {
            return
        }
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        do {
            let release = try await fetchLatestRelease()
            lastCheckedAt = Date()
            UserDefaults.standard.set(lastCheckedAt, forKey: lastCheckKey)
            if isNewerVersion(release.version, than: currentVersion) {
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Deck/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError("Could not get a connection response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError("GitHub API \(http.statusCode)")
        }

        struct APIRelease: Decodable {
            let tag_name: String
            let body: String?
            let published_at: String?
            let assets: [Asset]
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
        }
        let decoded = try JSONDecoder().decode(APIRelease.self, from: data)
        let tag = decoded.tag_name
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let zipAsset = decoded.assets.first(where: { $0.name.lowercased() == assetName }),
              let zipURL = URL(string: zipAsset.browser_download_url) else {
            throw UpdateError("Deck.zip not found in this release")
        }
        let publishedAt: Date = {
            guard let str = decoded.published_at else { return Date() }
            return ISO8601DateFormatter().date(from: str) ?? Date()
        }()
        return Release(version: version,
                       tag: tag,
                       notes: (decoded.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                       zipURL: zipURL,
                       publishedAt: publishedAt)
    }

    /// `.numeric` kıyas "1.10.0" > "1.9.0" sıralamasını doğru yapar;
    /// düz string kıyası yapmaz.
    private func isNewerVersion(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    // MARK: - Download + install

    func downloadAndInstall() async {
        guard case .available(let release) = state else { return }
        installLog = []
        log("Starting download: \(release.zipURL.absoluteString)")
        state = .downloading(0)
        do {
            let zipURL = try await downloadZip(from: release.zipURL)
            log("Download complete: \(zipURL.lastPathComponent)")
            let stagedApp = try unzipStaged(zipURL: zipURL, version: release.version)
            log("Unzip complete: \(stagedApp.path)")
            try installAndRelaunch(stagedApp: stagedApp)
            log("Helper script started. Deck is closing…")
            state = .installing
            // Kullanıcı "Yeniden başlatılıyor…" mesajını görebilsin diye
            // kısa bir gecikmeyle terminate iste.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.log("Calling NSApp.terminate(nil)")
                NSApp.terminate(nil)
            }
            // Emniyet: terminate takılırsa (SIGTERM'e direnen PTY vb.)
            // 7 sn sonra hard-exit — helper script böylece devam edebilir.
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [weak self] in
                self?.log("Auto-fallback: still here after 7s → exit(0)")
                Darwin.exit(0)
            }
        } catch {
            log("Error: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }

    /// Süreci hemen sonlandırır. "Zorla Kapat ve Kur" butonunun yolu —
    /// helper script zaten çalışıyor, pid ölünce swap'ı tamamlar.
    func forceQuitNow() {
        log("forceQuitNow() → exit(0)")
        Darwin.exit(0)
    }

    private func downloadZip(from url: URL) async throws -> URL {
        let updatesDir = DeckPaths.appSupport.appendingPathComponent("Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: updatesDir, withIntermediateDirectories: true)
        let destination = updatesDir.appendingPathComponent("Deck-\(UUID().uuidString).zip")

        let coordinator = DownloadCoordinator(destination: destination) { [weak self] progress in
            Task { @MainActor in
                guard let self = self else { return }
                if case .downloading = self.state {
                    self.state = .downloading(progress)
                }
            }
        }
        self.downloadCoordinator = coordinator
        defer { self.downloadCoordinator = nil }

        return try await coordinator.download(url: url)
    }

    private func unzipStaged(zipURL: URL, version: String) throws -> URL {
        let stageDir = zipURL.deletingLastPathComponent()
            .appendingPathComponent("stage-\(version)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: stageDir)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zipURL.path, stageDir.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? "ditto unzip failed"
            throw UpdateError(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let entries = try FileManager.default.contentsOfDirectory(atPath: stageDir.path)
        guard let appName = entries.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError("Deck.app not found in the downloaded package")
        }
        return stageDir.appendingPathComponent(appName)
    }

    private func installAndRelaunch(stagedApp: URL) throws {
        let currentApp = Bundle.main.bundleURL
        log("Current bundle: \(currentApp.path)")
        guard currentApp.path.hasSuffix(".app") else {
            throw UpdateError("Deck isn't running from inside a .app bundle (\(currentApp.path)). The updater only works from the installed app.")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-update-\(pid).sh")
        log("Helper script: \(scriptURL.path)")

        let appQ = shellQuote(currentApp.path)
        let stagedQ = shellQuote(stagedApp.path)
        let stageParentQ = shellQuote(stagedApp.deletingLastPathComponent().path)
        let script = """
        #!/bin/bash
        # Deck güncelleme helper'ı: çalışan Deck (pid \(pid)) kapanınca kurulu
        # bundle'ı yeni indirilen kopyayla değiştirir ve yeniden başlatır.
        for i in $(seq 1 75); do
            kill -0 \(pid) 2>/dev/null || break
            sleep 0.2
        done
        sleep 0.4
        APP=\(appQ)
        STAGED=\(stagedQ)
        rm -rf "$APP"
        cp -R "$STAGED" "$APP" || { echo "cp failed" >&2; exit 1; }
        xattr -cr "$APP" 2>/dev/null || true
        open "$APP"
        rm -rf \(stageParentQ)
        rm -f "$0"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        log("Script written (\(script.count) bytes)")

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", scriptURL.path]
        try chmod.run()
        chmod.waitUntilExit()
        log("chmod +x exit: \(chmod.terminationStatus)")

        // nohup ile detach — helper bu süreçten uzun yaşamalı.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = ["-c", "nohup \(shellQuote(scriptURL.path)) </dev/null >/dev/null 2>&1 &"]
        try launcher.run()
        launcher.waitUntilExit()
        log("nohup launcher exit: \(launcher.terminationStatus)")
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Buton/rozet yardımcıları (HomeView'daki popover butonu için)

extension UpdateChecker {
    var buttonSystemImage: String {
        switch state {
        case .idle, .checking:          return "arrow.down.circle"
        case .upToDate:                 return "checkmark.circle"
        case .available:                return "arrow.down.circle.fill"
        case .downloading, .installing: return "arrow.down.circle"
        case .error:                    return "exclamationmark.triangle"
        }
    }

    var buttonTint: Color? {
        switch state {
        case .available:    return .accentColor
        case .error:        return .orange
        default:            return nil
        }
    }

    var buttonTooltip: String {
        switch state {
        case .idle:                 return "Check for updates"
        case .checking:             return "Checking…"
        case .upToDate:             return "Deck \(currentVersion) is the latest version"
        case .available(let r):     return "Deck \(r.version) available — click to update"
        case .downloading(let p):   return "Downloading… \(Int(p * 100))%"
        case .installing:           return "Restarting…"
        case .error(let m):         return "Update error: \(m)"
        }
    }

    var hasAvailableUpdate: Bool {
        if case .available = state { return true }
        return false
    }
}

// MARK: - Helpers

private struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Progress akışı veren URLSessionDownloadDelegate sarmalayıcısı; bitmiş
/// dosyayı async sonuç olarak döner.
private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            var req = URLRequest(url: url)
            req.setValue("Deck-Updater", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: req).resume()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
        session?.finishTasksAndInvalidate()
        session = nil
    }

    // URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            finish(.failure(error))
        }
    }
}
