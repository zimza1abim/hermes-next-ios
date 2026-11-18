import Foundation
import os

/// The last few voice failures, so a device log can be copied from the settings screen.
enum VoiceDiagnostics {
    private static let key = "voice_last_error"
    private static let log = Logger(subsystem: "dev.hermes.next", category: "voice")

    static func record(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(text)"
        var lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        lines.append(line)
        if lines.count > 8 { lines.removeFirst(lines.count - 8) }
        UserDefaults.standard.set(lines, forKey: key)
        log.error("\(line, privacy: .public)")
    }

    static var last: String? {
        let lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
