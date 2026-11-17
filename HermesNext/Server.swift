import Foundation

/// The addresses of one Hermes Webapp server.
struct Endpoint {
    let origin: String
    let base: String

    init?(_ serverURL: String) {
        guard let url = URLComponents(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host else { return nil }
        let authority = url.port.map { "\(host):\($0)" } ?? host
        origin = "\(scheme)://\(authority)"
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        base = origin + path
    }

    func api(_ path: String) -> URL? { URL(string: base + path) }
    var ticketURL: URL? { api("/api/webapp/socket-ticket?socket=gateway") }
    var socketURL: URL? { URL(string: (base + "/api/ws?native_dial=browser").replacingOccurrences(of: "http", with: "ws", options: .anchored)) }
    var pageURL: URL? { URL(string: base.isEmpty ? origin : base) }
}

enum TicketResult {
    case ticket(String), signedOut, unsupported, failed
}

/// Every signed HTTP request of the app, one at a time.
///
/// The sign-in rotates a single-use refresh token on a request that refreshes, and refuses the whole
/// sign-in when a spent token is replayed. So each request starts only after the one before it has
/// stored its cookies. `URLSession` keeps the rotated cookies in the shared cookie store by itself.
actor Server {
    static let shared = Server()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()
    private var tail: Task<Void, Never>?

    private func inOrder<T>(_ work: @escaping () async -> T) async -> T {
        let before = tail
        let task = Task { () -> T in
            await before?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    func ticket(_ endpoint: Endpoint) async -> TicketResult {
        guard let url = endpoint.ticketURL else { return .failed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(endpoint.origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = session
        return await inOrder {
            guard let (data, reply) = try? await session.data(for: request), let http = reply as? HTTPURLResponse else { return .failed }
            CookieVault.save(endpoint.pageURL)
            switch http.statusCode {
            case 401, 403: return .signedOut
            case 404, 405: return .unsupported
            case 200..<300:
                let ticket = ((try? JSONSerialization.jsonObject(with: data)) as? JSON)?.text("ticket")
                return ticket.map { .ticket($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? .failed
            default: return .failed
            }
        }
    }

    /// Any server API call. The reply's JSON value (an object or an array), or nil on failure.
    func call(_ endpoint: Endpoint, _ method: String = "GET", _ path: String, body: JSON? = nil) async -> Any? {
        guard let url = endpoint.api(path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(endpoint.origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        }
        let session = session
        return await inOrder {
            guard let (data, reply) = try? await session.data(for: request), let http = reply as? HTTPURLResponse else { return nil }
            CookieVault.save(endpoint.pageURL)
            guard (200..<300).contains(http.statusCode) else { return nil }
            let value = try? JSONSerialization.jsonObject(with: data)
            return (value is JSON || value is [Any]) ? value : nil
        }
    }
}

/// The server's lists as the app's rows. Pure parsing.
enum Parse {
    /// What the Webapp leaves out of its own chat list: editor, cron, kanban, one-shot, subagent and tool
    /// runs, and every messaging platform's threads.
    private static let notChats = ["acp", "cron", "kanban", "oneshot", "subagent", "tool", "telegram", "discord", "slack", "mattermost",
        "matrix", "signal", "whatsapp", "bluebubbles", "photon", "homeassistant", "email", "sms", "webhook", "api_server", "weixin",
        "wecom", "qqbot", "yuanbao", "dingtalk", "feishu"]
    private static let notMessaging = ["cron", "acp", "cli", "codex", "desktop", "gateway", "kanban", "local", "oneshot", "tui"]

    static let sidebarPath = "/api/profiles/sessions/sidebar?recents_profile=all&recents_limit=200&cron_limit=50&messaging_limit=100"
        + "&recents_exclude=" + notChats.joined(separator: ",") + "&messaging_exclude=" + notMessaging.joined(separator: ",")
    static let archivedPath = "/api/profiles/sessions?archived=only&profile=all&limit=200&min_messages=1"

    static func chatRows(_ rows: [JSON], kind: ChatKind) -> [ChatRow] {
        rows.compactMap { row in
            guard let id = row.text("id") else { return nil }
            return ChatRow(
                id: id, title: row.text("title"), preview: row.text("preview").map(Markdown.plain).map { String($0.prefix(160)) },
                lastActiveAt: row.number("last_active") ?? row.number("started_at"),
                // The server's `is_active` only says the chat was used in the last five minutes.
                running: false, pinned: row.flag("pinned") == true, profile: row.text("profile"),
                defaultProfile: row.flag("is_default_profile") != false, kind: kind,
                source: kind == .messaging ? row.text("source") : nil, unread: row.flag("unread") == true)
        }
    }

    static func sidebar(_ reply: Any?) -> [ChatRow]? {
        guard let reply = reply as? JSON, let recents = reply.object("recents"), recents["sessions"] is [Any] else { return nil }
        func slice(_ name: String, _ kind: ChatKind) -> [ChatRow] { chatRows(reply.object(name)?.rows("sessions") ?? [], kind: kind) }
        var seen = Set<String>()
        return (slice("recents", .chat) + slice("messaging", .messaging) + slice("cron", .cron)).filter { seen.insert("\($0.profile ?? "")/\($0.id)").inserted }
    }

    static func archived(_ reply: Any?) -> [ChatRow]? {
        guard let reply = reply as? JSON, reply["sessions"] is [Any] else { return nil }
        return chatRows(reply.rows("sessions"), kind: .chat).sorted { ($0.lastActiveAt ?? 0) > ($1.lastActiveAt ?? 0) }
    }

    static func profiles(_ rows: [JSON]) -> [Profile] {
        var seen = Set<String>()
        return rows.enumerated().compactMap { index, row in
            guard let name = row.text("name"), seen.insert(name).inserted else { return nil }
            let title = row.object("ui_meta")?.object("hermes-bots")?.text("title") ?? row.text("display_name") ?? name
            var standing: ChatRow?
            if let chat = row.object("canonical_session"), let id = chat.text("id") {
                let active = chat.number("last_active").flatMap { $0 > 0 ? $0 : nil }
                standing = ChatRow(id: id, title: title, preview: chat.text("preview").map(Markdown.plain).map { String($0.prefix(160)) },
                                   lastActiveAt: active, pinned: true, profile: name, defaultProfile: index == 0, kind: .bot)
            }
            return Profile(name: name, title: title, own: index == 0, hasAvatar: row.flag("has_avatar") != false, chat: standing)
        }
    }

    static func history(_ rows: [JSON]) -> [Message] {
        rows.enumerated().compactMap { index, row in
            let role: MessageRole
            switch row["role"] as? String {
            case "user": role = .user
            case "assistant": role = .assistant
            default: return nil
            }
            guard let text = row.text("text") ?? row.text("content") else { return nil }
            return Message(id: "history-\(index)", role: role, text: text)
        }
    }

    static func cron(_ reply: Any?) -> [CronJob]? {
        guard let rows = (reply as? [Any])?.compactMap({ $0 as? JSON }) ?? (reply as? JSON).flatMap({ $0["jobs"] is [Any] ? $0.rows("jobs") : nil }) else { return nil }
        return rows.compactMap { row in
            guard let id = row.text("id") ?? row.text("job_id") else { return nil }
            let name = row.text("name") ?? row.text("prompt").flatMap { $0.split(separator: "\n").first.map { String($0.prefix(60)) } } ?? id
            return CronJob(id: id, name: name, schedule: row.text("schedule_display"), nextRun: row.text("next_run_at"), lastStatus: row.text("last_status"),
                           paused: row.flag("enabled") == false || (row["state"] as? String) == "paused", profile: row.text("profile") ?? row.text("profile_name"))
        }
    }

    static func skills(_ reply: Any?) -> [Capability]? {
        guard let rows = reply as? [Any] else { return nil }
        return rows.compactMap { $0 as? JSON }.compactMap { row in
            row.text("name").map { Capability(name: $0, detail: row.text("description").map { String($0.prefix(160)) }, enabled: row.flag("enabled") != false, note: row.text("category")) }
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func toolsets(_ reply: Any?) -> [Capability]? {
        guard let rows = reply as? [Any] else { return nil }
        return rows.compactMap { $0 as? JSON }.compactMap { row in
            guard let name = row.text("name") else { return nil }
            let needsSetup = row.flag("enabled") == true && row.flag("configured") == false
            return Capability(name: row.text("label") ?? name, detail: row.text("description").map { String($0.prefix(160)) },
                              enabled: row.flag("enabled") == true, note: needsSetup ? "설정 필요" : nil)
        }
    }

    static func mcpServers(_ reply: Any?) -> [Capability]? {
        guard let reply = reply as? JSON, reply["servers"] is [Any] else { return nil }
        return reply.rows("servers").compactMap { row in
            row.text("name").map { Capability(name: $0, detail: row.text("url") ?? row.text("command"), enabled: row.flag("enabled") != false, note: row.text("transport")) }
        }
    }

    static func pluginCatalog(_ reply: Any?) -> [Installable]? {
        guard let reply = reply as? JSON, reply["entries"] is [Any] else { return nil }
        return reply.rows("entries").compactMap { row in
            guard let name = row.text("name") else { return nil }
            return Installable(name: name, title: row.text("title") ?? name, detail: (row.text("capability_summary") ?? row.text("description")).map { String($0.prefix(400)) },
                               source: row.text("repo"), installed: row.flag("installed") == true, plugin: true)
        }
    }

    static func mcpCatalog(_ reply: Any?) -> [Installable]? {
        guard let reply = reply as? JSON, reply["entries"] is [Any] else { return nil }
        return reply.rows("entries").compactMap { row in
            guard let name = row.text("name") else { return nil }
            let needsKeys = row.rows("required_env").contains { $0.flag("required") != false }
            let auth = row.text("auth_type") ?? "none"
            let blocked: String? = needsKeys ? "키 입력이 필요해요" : (auth != "none" && auth != "env") ? "로그인이 필요해요" : nil
            let args = (row["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            let command = row.text("command").map { String(([$0] + args).joined(separator: " ").prefix(160)) }
            return Installable(name: name, title: name, detail: row.text("description").map { String($0.prefix(400)) },
                               source: row.text("url") ?? row.text("install_url") ?? command, installed: row.flag("installed") == true, plugin: false, blocked: blocked)
        }
    }
}

extension String {
    var urlEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

/// The sign-in cookies, kept in the keychain. `HTTPCookieStorage` drops session cookies when the app
/// quits, and the sign-in rotates its token on use, so the newest cookies are written after every reply.
enum CookieVault {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.hermes.next.cookies",
                                               kSecAttrAccount as String: "server"]

    static func save(_ url: URL?) {
        guard let url, let cookies = HTTPCookieStorage.shared.cookies(for: url) else { return }
        let rows = cookies.compactMap { cookie in cookie.properties.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) } }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0) else { return }
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(update) { $1 } as CFDictionary, nil)
        }
    }

    static func restore() {
        var read = query
        read[kSecReturnData as String] = true
        var value: AnyObject?
        guard SecItemCopyMatching(read as CFDictionary, &value) == errSecSuccess, let data = value as? Data,
              let rows = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]] else { return }
        for row in rows {
            let properties = Dictionary(uniqueKeysWithValues: row.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            if let cookie = HTTPCookie(properties: properties) { HTTPCookieStorage.shared.setCookie(cookie) }
        }
    }
}
