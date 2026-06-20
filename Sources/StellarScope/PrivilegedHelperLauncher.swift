import Foundation
import AppKit

struct PrivilegedHelperLauncher {
    static let outputPath = "/tmp/stellarscope-powermetrics.json"
    static let logPath = "/tmp/stellarscope-powermetrics-agent.log"
    static let pidPath = "/tmp/stellarscope-powermetrics.pid"
    static let launchdLabel = "com.lmz.StellarScope.PowermetricsAgent"
    static let launchdPlistPath = "/Library/LaunchDaemons/com.lmz.StellarScope.PowermetricsAgent.plist"

    static func startPowermetricsAgent(intervalMS: Int = 5000) throws {
        let scriptPath = try embeddedAgentPath()
        let plist = launchdPlist(agentPath: scriptPath, intervalMS: intervalMS).replacingOccurrences(of: "\n", with: "")

        // v7: Use a temporary LaunchDaemon instead of nohup/background shell hacks.
        // This is more reliable for a self-use privileged sampler launched from a GUI.
        let inner = [
            "/bin/rm -f \(shellQuote(outputPath)) \(shellQuote(pidPath))",
            ": > \(shellQuote(logPath))",
            "/bin/chmod 644 \(shellQuote(logPath))",
            "/usr/bin/printf %s \(shellQuote(plist)) > \(shellQuote(launchdPlistPath))",
            "/usr/sbin/chown root:wheel \(shellQuote(launchdPlistPath))",
            "/bin/chmod 644 \(shellQuote(launchdPlistPath))",
            "echo \"[StellarScope] bootstrapping LaunchDaemon at $(/bin/date)\" >> \(shellQuote(logPath))",
            "/bin/launchctl bootout system/\(launchdLabel) 2>/dev/null || true",
            "/bin/launchctl bootstrap system \(shellQuote(launchdPlistPath))",
            "/bin/launchctl kickstart -k system/\(launchdLabel) || true"
        ].joined(separator: "; ")
        let command = "/bin/zsh -lc \(shellQuote(inner))"
        try runAsAdministrator(command)
    }

    static func stopPowermetricsAgent() throws {
        let inner = [
            "/bin/launchctl bootout system/\(launchdLabel) 2>/dev/null || true",
            "if [ -f \(shellQuote(pidPath)) ]; then oldpid=$(/bin/cat \(shellQuote(pidPath)) 2>/dev/null || true); if [ -n \"$oldpid\" ]; then /bin/kill \"$oldpid\" 2>/dev/null || true; fi; fi",
            "/bin/rm -f \(shellQuote(pidPath)) \(shellQuote(launchdPlistPath))"
        ].joined(separator: "; ")
        let command = "/bin/zsh -lc \(shellQuote(inner))"
        try runAsAdministrator(command)
    }

    static func openLogFile() {
        let url = URL(fileURLWithPath: logPath)
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(url)
        }
    }

    static func diagnose() -> String {
        let fm = FileManager.default
        let outputExists = fm.fileExists(atPath: outputPath)
        let pid = (try? String(contentsOfFile: pidPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let log = readLogTail(maxBytes: 1600)
        let runningSchema = runningAgentSchemaVersion()
        let bundledSchema = bundledAgentSchemaVersion()

        if outputExists {
            let mod = (try? fm.attributesOfItem(atPath: outputPath)[.modificationDate]) as? Date
            let ageText: String
            if let mod {
                ageText = String(format: "%.1fs ago", Date().timeIntervalSince(mod))
            } else {
                ageText = "unknown age"
            }
            if let runningSchema, let bundledSchema, runningSchema < bundledSchema {
                return "Advanced helper is running old schema \(runningSchema); bundled schema \(bundledSchema) is available. Use Update Helper to reinstall and restart it."
            }
            let schemaText = runningSchema.map { ", schema \($0)" } ?? ""
            if let pid, !pid.isEmpty {
                return "Advanced helper is producing JSON (pid \(pid), updated \(ageText)\(schemaText))."
            }
            return "Advanced helper is producing JSON (updated \(ageText)\(schemaText))."
        }

        if !log.isEmpty {
            return "No JSON yet. Last helper log: \(log)"
        }
        return "No JSON yet and the helper log is empty. Try Start Advanced Helper again, or run scripts/start_advanced_helper.command once."
    }

    static func bundledAgentSchemaVersion() -> Int? {
        guard let path = try? embeddedAgentPath(),
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"AGENT_SCHEMA_VERSION\s*=\s*(\d+)"#) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let versionRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[versionRange])
    }

    static func runningAgentSchemaVersion() -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: outputPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flat = object["flat"] as? [String: Any],
              let value = flat["agent.schema_version"] else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    static func helperNeedsInstallOrRestart() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: outputPath) else { return true }
        if let runningSchema = runningAgentSchemaVersion(),
           let bundledSchema = bundledAgentSchemaVersion(),
           runningSchema < bundledSchema {
            return true
        }
        guard let attributes = try? fm.attributesOfItem(atPath: outputPath),
              let modified = attributes[.modificationDate] as? Date else {
            return true
        }
        return Date().timeIntervalSince(modified) > 30
    }

    static func readLogTail(maxBytes: Int = 4000) -> String {
        guard let handle = FileHandle(forReadingAtPath: logPath) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .suffix(8)
            .joined(separator: " | ") ?? ""
    }

    private static func embeddedAgentPath() throws -> String {
        // Packaged .app: Contents/Resources/agent/...
        if let resourceURL = Bundle.main.resourceURL {
            let appBundled = resourceURL
                .appendingPathComponent("agent")
                .appendingPathComponent("stellarscope_powermetrics_agent.py")
            if FileManager.default.fileExists(atPath: appBundled.path) {
                return appBundled.path
            }
        }

        // SwiftPM/Xcode fallback.
        if let url = Bundle.module.url(forResource: "stellarscope_powermetrics_agent", withExtension: "py") {
            return url.path
        }

        throw HelperError.missingEmbeddedAgent
    }

    private static func runAsAdministrator(_ shellCommand: String) throws {
        let appleScript = "do shell script \"\(escapeForAppleScript(shellCommand))\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HelperError.privilegeCommandFailed(message ?? "osascript exited with \(process.terminationStatus)")
        }
    }

    private static func launchdPlist(agentPath: String, intervalMS: Int) -> String {
        let agent = xmlEscape(agentPath)
        let log = xmlEscape(logPath)
        let label = xmlEscape(launchdLabel)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/python3</string>
                <string>\(agent)</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>STELLARSCOPE_INTERVAL_MS</key>
                <string>\(intervalMS)</string>
                <key>PYTHONUNBUFFERED</key>
                <string>1</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(log)</string>
            <key>StandardErrorPath</key>
            <string>\(log)</string>
            <key>ProcessType</key>
            <string>Background</string>
        </dict>
        </plist>
        """
    }

    private static func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escapeForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    enum HelperError: LocalizedError {
        case missingEmbeddedAgent
        case privilegeCommandFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingEmbeddedAgent:
                return "Embedded powermetrics agent was not found in the app resources."
            case .privilegeCommandFailed(let message):
                return message
            }
        }
    }
}

@MainActor
final class PrivilegedHelperController: ObservableObject {
    @Published var status: String = "Advanced helper not started."
    @Published var isBusy: Bool = false

    func start(intervalMS: Int = 5000) {
        guard !isBusy else { return }
        isBusy = true
        status = "Requesting administrator permission…"
        Task.detached {
            do {
                try PrivilegedHelperLauncher.startPowermetricsAgent(intervalMS: intervalMS)
                await MainActor.run {
                    self.status = "Advanced helper launched. Waiting for first sample…"
                    self.isBusy = false
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let diagnosis = PrivilegedHelperLauncher.diagnose()
                await MainActor.run {
                    self.status = diagnosis
                }
            } catch {
                await MainActor.run {
                    self.status = "Failed to launch helper: \(error.localizedDescription)"
                    self.isBusy = false
                }
            }
        }
    }

    func update(intervalMS: Int = 5000) {
        guard !isBusy else { return }
        isBusy = true
        let bundled = PrivilegedHelperLauncher.bundledAgentSchemaVersion()
        status = bundled.map { "Requesting administrator permission to install helper schema \($0)…" }
            ?? "Requesting administrator permission to update helper…"
        Task.detached {
            do {
                try PrivilegedHelperLauncher.startPowermetricsAgent(intervalMS: intervalMS)
                await MainActor.run {
                    self.status = "Advanced helper updated. Waiting for restarted helper…"
                    self.isBusy = false
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let diagnosis = PrivilegedHelperLauncher.diagnose()
                await MainActor.run {
                    self.status = diagnosis
                }
            } catch {
                await MainActor.run {
                    self.status = "Failed to update helper: \(error.localizedDescription)"
                    self.isBusy = false
                }
            }
        }
    }

    func stop() {
        guard !isBusy else { return }
        isBusy = true
        status = "Requesting administrator permission to stop helper…"
        Task.detached {
            do {
                try PrivilegedHelperLauncher.stopPowermetricsAgent()
                await MainActor.run {
                    self.status = "Advanced helper stopped."
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.status = "Failed to stop helper: \(error.localizedDescription)"
                    self.isBusy = false
                }
            }
        }
    }

    func refreshDiagnosis() {
        status = PrivilegedHelperLauncher.diagnose()
    }

    func openLog() {
        PrivilegedHelperLauncher.openLogFile()
    }
}
