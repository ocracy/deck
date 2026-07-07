import Foundation

/// Süreç çalıştırma yardımcıları. GUI uygulamaları launchd'den minimal PATH
/// aldığı için kullanıcının gerçek PATH'i bir kez login+interactive zsh'ten
/// alınıp (`userPath`) spawn edilen her sürece enjekte edilir.
enum Shell {
    /// `/bin/zsh -l -i -c 'print -rn -- $PATH'` — ilk erişimde bir kez alınır.
    static let userPath: String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-i", "-c", "print -rn -- $PATH"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}
        return ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }()

    /// Adaylardan ilk çalıştırılabilir olanı döndürür.
    static func findExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Tek tırnakla sarar; içteki `'` → `'\''`.
    static func singleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Senkron çalıştırır; stdout+stderr birleşik döner.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        // waitUntilExit'ten ÖNCE oku — pipe dolarsa süreç bloklanır.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func runAsync(_ launchPath: String, _ args: [String],
                         completion: (@Sendable (Int32, String) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let result = run(launchPath, args)
            completion?(result.status, result.output)
        }
    }

    /// `/bin/zsh -c <command>` — çıktısı atılır, beklenmez.
    static func runDetached(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
