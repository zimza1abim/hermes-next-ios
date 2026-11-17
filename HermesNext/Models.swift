import Foundation

/// What kind of chat a row of the list is.
enum ChatKind: String { case bot, chat, messaging, cron }

/// One chat of the list, as the server's sidebar feed gives it.
struct ChatRow: Identifiable, Hashable {
    var id: String
    var title: String?
    var preview: String?
    /// Unix seconds.
    var lastActiveAt: Double?
    var running = false
    var pinned = false
    var profile: String?
    var defaultProfile = true
    var kind: ChatKind = .chat
    /// A messaging thread's platform (`telegram`, `discord`, ...).
    var source: String?
    /// Something was written in it after it was last read, on any device.
    var unread = false

    var key: String { "\(kind.rawValue)/\(profile ?? "")/\(id)" }
    var shownTitle: String { title?.isEmpty == false ? title! : "제목 없는 대화" }
}

/// A bot: one profile the server serves. The first one is the server's own.
struct Profile: Identifiable, Hashable {
    var name: String
    var title: String
    var own: Bool
    var hasAvatar: Bool
    /// The bot's standing chat, which the recent chats do not list.
    var chat: ChatRow?
    var id: String { name }
}

enum MessageRole { case user, assistant }

enum MessageStatus: Equatable {
    case done, sending, writing, stopped
    case failed(String)
}

struct Message: Identifiable, Equatable {
    let id: String
    var role: MessageRole
    var text: String
    var status: MessageStatus = .done
    /// A streamed answer's text by segment, so a chunk the server sends twice is dropped.
    var segments: [Int: String] = [:]
}

/// A command Hermes asks to run.
struct ApprovalRequest: Identifiable, Equatable {
    /// The JSON-RPC id, already encoded as JSON (a number or a quoted string).
    let id: String
    let sessionId: String
    let command: String
    let choices: [String]
}

struct CronJob: Identifiable, Hashable {
    var id: String
    var name: String
    var schedule: String?
    var nextRun: String?
    var lastStatus: String?
    var paused: Bool
    var profile: String?
}

/// A skill, a toolset or an MCP server, and whether it is on.
struct Capability: Identifiable, Hashable {
    var name: String
    var detail: String?
    var enabled: Bool
    var note: String?
    var id: String { name }
}

/// Something the server can install: a catalog plugin or a catalog MCP server.
struct Installable: Identifiable, Hashable {
    var name: String
    var title: String
    var detail: String?
    var source: String?
    var installed: Bool
    var plugin: Bool
    /// Why this screen cannot install it (it needs keys or a sign-in).
    var blocked: String?
    var id: String { (plugin ? "p/" : "m/") + name }
}

enum Link: Equatable {
    case idle, connecting, online, offline, signedOut, unsupported

    var label: String {
        switch self {
        case .idle: "STANDBY"
        case .connecting: "CONNECTING"
        case .online: "ONLINE"
        case .offline: "OFFLINE"
        case .signedOut: "SIGN-IN NEEDED"
        case .unsupported: "NO GATEWAY"
        }
    }
}

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    /// A non-blank string field.
    func text(_ name: String) -> String? {
        guard let value = self[name] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    func flag(_ name: String) -> Bool? { self[name] as? Bool }
    func number(_ name: String) -> Double? { (self[name] as? NSNumber)?.doubleValue }
    func object(_ name: String) -> JSON? { self[name] as? JSON }
    func rows(_ name: String) -> [JSON] { (self[name] as? [Any])?.compactMap { $0 as? JSON } ?? [] }
}

/// How long ago `seconds` (Unix time) was, in the short form a list row has room for.
func ago(_ seconds: Double, now: Date = Date()) -> String {
    let minutes = Int((now.timeIntervalSince1970 - seconds) / 60)
    switch minutes {
    case ..<1: return "방금"
    case ..<60: return "\(minutes)분 전"
    case ..<(24 * 60): return "\(minutes / 60)시간 전"
    case ..<(7 * 24 * 60): return "\(minutes / (24 * 60))일 전"
    default:
        let format = DateFormatter()
        format.locale = Locale(identifier: "ko_KR")
        format.dateFormat = "M월 d일"
        return format.string(from: Date(timeIntervalSince1970: seconds))
    }
}

func platformLabel(_ source: String) -> String {
    switch source {
    case "telegram": "텔레그램"
    case "discord": "디스코드"
    case "slack": "슬랙"
    case "whatsapp": "왓츠앱"
    case "email": "이메일"
    case "sms": "문자"
    default: source.prefix(1).uppercased() + source.dropFirst()
    }
}
