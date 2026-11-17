import Foundation
import Network
import Observation
import UIKit

/// Everything the screens show, and the one gateway socket behind it. Main actor only.
@MainActor
@Observable
final class Store {
    static let allTab = "*"

    // MARK: Server and link

    var serverURL: String = UserDefaults.standard.string(forKey: "server_url") ?? ""
    var link: Link = .idle
    private var endpoint: Endpoint? { Endpoint(serverURL) }
    var hasServer: Bool { endpoint != nil }
    var pageURL: URL? { endpoint?.pageURL }

    // MARK: Lists

    var chats: [ChatRow] = []
    var chatsLoading = false
    var profiles: [Profile] = []
    var avatars: [String: UIImage] = [:]
    /// `allTab` for every chat, nil for the main bot, else a bot's profile name.
    var tab: String? = Store.allTab
    var notice: String?

    // MARK: The open chat

    var openRow: ChatRow?
    var title: String?
    /// The bot of the open chat; nil is the server's own profile.
    var profile: String?
    var messages: [Message] = []
    var opening = false
    var approvals: [ApprovalRequest] = []
    var draft = UserDefaults.standard.string(forKey: "draft") ?? ""
    private var runtimeId: String?
    private var storedId: String?
    private var openedId: String?

    var busy: Bool { messages.contains { $0.status == .sending || $0.status == .writing } }
    var own: Profile? { profiles.first { $0.own } }
    var bots: [Profile] { profiles.filter { !$0.own } }
    var tabs: [String?] { [Store.allTab, nil] + bots.map { Optional($0.name) } }
    var openBot: Profile? { profiles.first { $0.name == profile } ?? own }

    // MARK: Menu lists

    var cron: [CronJob] = []
    var skills: [Capability] = []
    var toolsets: [Capability] = []
    var mcp: [Capability] = []
    var plugins: [Installable] = []
    var mcpCatalog: [Installable] = []
    var archived: [ChatRow] = []
    var installing = Set<String>()
    var menuLoading = false

    // MARK: Socket

    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var authority = false
    private var nextId = 1
    private var pending: [Int: (JSON?, String?) -> Void] = [:]
    private var attempt = 0
    private var active = false
    private var lastLines: [String: String] = (UserDefaults.standard.dictionary(forKey: "last_lines") as? [String: String]) ?? [:]
    private let session = URLSession(configuration: .default)

    private let network = NWPathMonitor()
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var sleeping: Task<Void, Never>?

    init() {
        // The sign-in cookies of the last run, before anything is sent.
        CookieVault.restore()
        loadAvatars()
        network.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.active, self.link == .offline || self.link == .idle else { return }
                self.reconnect()
            }
        }
        network.start(queue: .main)
    }

    func setServer(_ url: String) {
        serverURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(serverURL, forKey: "server_url")
        chats = []
        profiles = []
        newChat(profile: nil)
        reconnect()
    }

    /// The app came to the front or went to the background. A quick trip away (the app switcher, another
    /// app for a moment) keeps the socket: iOS gives a backgrounded app some seconds, and the socket is
    /// closed only when they run out.
    func setActive(_ now: Bool) {
        active = now
        sleeping?.cancel()
        sleeping = nil
        if now {
            endBackground()
            if link != .online && link != .connecting { reconnect() }
            Task { await refreshChats() }
            return
        }
        background = UIApplication.shared.beginBackgroundTask(withName: "socket") { [weak self] in
            Task { @MainActor in
                self?.drop(to: .idle)
                self?.endBackground()
            }
        }
        sleeping = Task {
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, !active else { return }
            drop(to: .idle)
            endBackground()
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    func reconnect() {
        attempt = 0
        drop(to: .idle)
        connect()
    }

    private func drop(to state: Link) {
        generation += 1
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        pending.values.forEach { $0(nil, "연결이 끊겼어요") }
        pending = [:]
        runtimeId = nil
        approvals = []
        link = state
        // A question without a receipt may or may not have arrived; it is never sent again by itself.
        for index in messages.indices where messages[index].status == .sending {
            messages[index].status = .failed("연결이 끊겨 보냈는지 알 수 없어요")
            messages.removeAll { $0.role == .assistant && $0.status == .writing && $0.text.isEmpty }
        }
    }

    private func connect() {
        guard active, let endpoint, let socketURL = endpoint.socketURL else { return }
        generation += 1
        let gen = generation
        link = .connecting
        Task {
            let result = await Server.shared.ticket(endpoint)
            guard gen == generation else { return }
            switch result {
            case .signedOut: link = .signedOut
            case .unsupported: link = .unsupported
            case .failed: retryLater(gen)
            case .ticket(let ticket):
                var request = URLRequest(url: socketURL)
                request.setValue(endpoint.origin, forHTTPHeaderField: "Origin")
                request.setValue("hermes-gateway-v1, hermes-gateway-ticket.\(ticket)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
                if let page = endpoint.pageURL, let cookies = HTTPCookieStorage.shared.cookies(for: page), !cookies.isEmpty {
                    request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
                }
                let task = session.webSocketTask(with: request)
                socket = task
                task.resume()
                receive(task, gen)
                ping(task, gen)
                // A socket that opens but never says it is ready is tried again.
                Task {
                    try? await Task.sleep(for: .seconds(20))
                    guard gen == generation, link == .connecting else { return }
                    drop(to: .offline)
                    retryLater(generation)
                }
            }
        }
    }

    private func retryLater(_ gen: Int) {
        link = .offline
        socket = nil
        attempt += 1
        let delay = min(30.0, pow(2.0, Double(min(attempt, 5))))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if gen == generation, active { connect() }
        }
    }

    private func ping(_ task: URLSessionWebSocketTask, _ gen: Int) {
        Task {
            while gen == generation {
                try? await Task.sleep(for: .seconds(15))
                guard gen == generation else { return }
                task.sendPing { _ in }
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, _ gen: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure:
                    self.drop(to: .offline)
                    self.retryLater(self.generation)
                case .success(let message):
                    if case .string(let text) = message, let frame = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? JSON {
                        self.handle(frame)
                    }
                    self.receive(task, gen)
                }
            }
        }
    }

    private func sendRaw(_ text: String) {
        socket?.send(.string(text)) { _ in }
    }

    /// One gateway call. `profile` routes it to another profile the server serves.
    private func call(_ method: String, _ params: JSON, profile: String? = nil) async -> (JSON?, String?) {
        // A call made while the socket comes up waits for it rather than failing at once.
        if method != "client.capabilities", link != .online, !(await waitOnline()) { return (nil, "연결되지 않았어요") }
        guard let socket else { return (nil, "연결되지 않았어요") }
        let id = nextId
        nextId += 1
        var all = params
        if let profile, !profile.isEmpty { all["profile"] = profile }
        let frame: JSON = ["jsonrpc": "2.0", "id": id, "method": method, "params": all]
        guard let data = try? JSONSerialization.data(withJSONObject: frame), let text = String(data: data, encoding: .utf8) else { return (nil, "보내지 못했어요") }
        // A reply that never comes ends the wait instead of leaving a spinner forever.
        Task {
            try? await Task.sleep(for: .seconds(45))
            pending.removeValue(forKey: id)?(nil, "서버가 답하지 않아요")
        }
        return await withCheckedContinuation { done in
            pending[id] = { result, error in done.resume(returning: (result, error)) }
            socket.send(.string(text)) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in self?.pending.removeValue(forKey: id)?(nil, "보내지 못했어요") }
            }
        }
    }

    /// Waits up to `seconds` for the socket, starting it when nothing is trying.
    private func waitOnline(_ seconds: Double = 15) async -> Bool {
        if link == .idle || link == .offline { attempt = 0; connect() }
        let deadline = Date().addingTimeInterval(seconds)
        while link != .online {
            if link == .signedOut || link == .unsupported || Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return true
    }

    private static let windowOwned: Set<String> = ["preview.read", "preview.act", "terminal.read", "window.read", "tour"]

    private func handle(_ frame: JSON) {
        guard let method = frame["method"] as? String else {
            guard let id = (frame["id"] as? NSNumber)?.intValue, let done = pending.removeValue(forKey: id) else { return }
            if let error = frame.object("error") { done(nil, error.text("message") ?? "오류가 났어요") } else { done(frame.object("result") ?? [:], nil) }
            return
        }
        let params = frame.object("params") ?? [:]
        if Store.windowOwned.contains(method) {
            // Only a window showing the session can answer these.
            if let id = rpcId(frame["id"]) { sendRaw("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"error\":{\"code\":4090,\"message\":\"No app window shows this session\"}}") }
            return
        }
        if method == "approval" {
            guard let id = rpcId(frame["id"]), let sessionId = params.text("session_id"), sessionId == runtimeId else { return }
            let choices = (params["choices"] as? [Any])?.compactMap { $0 as? String } ?? []
            let command = params.text("command") ?? params.text("description") ?? params.text("tool_name") ?? "명령"
            if !approvals.contains(where: { $0.id == id }) {
                approvals.append(ApprovalRequest(id: id, sessionId: sessionId, command: command, choices: choices.isEmpty ? ["once", "deny"] : choices))
            }
            return
        }
        guard method == "event" else { return }
        let payload = params.object("payload") ?? [:]
        let sessionId = params.text("session_id") ?? payload.text("session_id")
        switch params.text("type") {
        case "gateway.ready":
            authority = payload.flag("session_authority") == true
            link = .online
            attempt = 0
            Task { await ready() }
        case "message.start":
            guard sessionId == runtimeId, sessionId != nil else { return }
            if messages.last?.status != .writing { messages.append(Message(id: UUID().uuidString, role: .assistant, text: "", status: .writing)) }
            markRunning()
        case "message.delta":
            guard sessionId == runtimeId, let chunk = payload["text"] as? String, !chunk.isEmpty,
                  let index = messages.lastIndex(where: { $0.status == .writing }) else { return }
            append(chunk, segment: (payload["segment"] as? NSNumber)?.intValue, offset: (payload["offset"] as? NSNumber)?.intValue, to: index)
        case "message.complete":
            guard sessionId == runtimeId, let index = messages.lastIndex(where: { $0.status == .writing }) else { return }
            if let text = payload.text("text") { messages[index].text = text }
            switch payload.text("status") ?? "complete" {
            case "error": messages[index].status = .failed(payload.text("error") ?? payload.text("failure_reason") ?? "답변을 받지 못했어요")
            case "interrupted": messages[index].status = .stopped
            default: messages[index].status = .done
            }
            approvals = []
            rememberLastLine()
            markRunning()
            Task { await refreshChats() }
        case "session.title":
            if sessionId == runtimeId, let name = payload.text("title") { title = name }
        case "request.cancel":
            if let id = rpcId(payload["id"]) { approvals.removeAll { $0.id == id } }
        case "approval.cancelled":
            if sessionId == runtimeId { approvals = [] }
        default: break
        }
    }

    /// A JSON-RPC id as JSON text: a number as it is, a string quoted.
    private func rpcId(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        if let text = value as? String, let data = try? JSONSerialization.data(withJSONObject: [text]), let json = String(data: data, encoding: .utf8) {
            return String(json.dropFirst().dropLast())
        }
        return nil
    }

    private func append(_ chunk: String, segment: Int?, offset: Int?, to index: Int) {
        var segments = messages[index].segments
        let key = segment ?? segments.keys.max() ?? 0
        let current = segments[key] ?? ""
        let length = current.utf16.count
        let at = offset ?? length
        if at >= length {
            segments[key] = current + chunk
        } else if at + chunk.utf16.count > length {
            // Part of this chunk was already shown: only the new tail is added.
            let fresh = String(chunk.utf16.dropFirst(length - at)) ?? ""
            segments[key] = current + fresh
        }
        messages[index].segments = segments
        messages[index].text = segments.keys.sorted().compactMap { segments[$0] }.joined(separator: "\n\n")
    }

    private func ready() async {
        _ = await call("client.capabilities", ["server_requests": true])
        async let roster: Void = refreshProfiles()
        if let stored = storedId { await resume(stored) }
        await roster
    }

    // MARK: Profiles and pictures

    func refreshProfiles() async {
        let (result, _) = await call("profiles.list", ["include_sessions": true])
        guard let result, result["profiles"] is [Any] else { return }
        profiles = Parse.profiles(result.rows("profiles"))
        if let profile, !profiles.contains(where: { $0.name == profile }) { self.profile = nil }
        for row in profiles where row.hasAvatar {
            let (asset, _) = await call("profiles.get_asset", ["asset": "avatar", "name": row.name])
            guard let asset, asset.flag("found") == true, let url = asset["data"] as? String, url.hasPrefix("data:image/"),
                  let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
                  data.count <= 8 * 1024 * 1024, let image = UIImage(data: data) else { continue }
            avatars[row.name] = image
            try? FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
            try? data.write(to: avatarFile(row.name))
        }
    }

    private var avatarDir: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("bot-avatars") }
    private func avatarFile(_ profile: String) -> URL { avatarDir.appendingPathComponent(profile.urlEncoded + ".img") }

    private func loadAvatars() {
        let files = (try? FileManager.default.contentsOfDirectory(at: avatarDir, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            guard let name = file.deletingPathExtension().lastPathComponent.removingPercentEncoding, let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { continue }
            avatars[name] = image
        }
    }

    func avatar(for row: ChatRow) -> UIImage? { avatars[row.profile ?? own?.name ?? "default"] }

    // MARK: Chats list

    func refreshChats() async {
        guard let endpoint else { return }
        chatsLoading = true
        let reply = await Server.shared.call(endpoint, "GET", Parse.sidebarPath)
        chatsLoading = false
        if let rows = Parse.sidebar(reply) { chats = decorate(rows) }
    }

    private func runningIds() -> Set<String> {
        messages.contains { $0.status == .writing || $0.status == .sending } ? Set([storedId, openedId].compactMap { $0 }) : []
    }

    /// Each row's newest line, and whether an answer is being written in it.
    private func decorate(_ rows: [ChatRow]) -> [ChatRow] {
        let running = runningIds()
        return rows.map { row in
            var next = row
            if let line = lastLines[row.id] { next.preview = line }
            next.running = running.contains(row.id)
            return next
        }
    }

    private func markRunning() { chats = decorate(chats) }

    /// The server's preview is the head of the first question and never changes; the newest line of
    /// every chat shown here is kept instead.
    private func rememberLastLine() {
        guard !busy, let text = messages.last?.text, !text.isEmpty else { return }
        let line = String(Markdown.plain(text).prefix(160))
        let ids = [storedId, openedId].compactMap { $0 }
        guard !line.isEmpty, !ids.isEmpty else { return }
        ids.forEach { lastLines[$0] = line }
        if lastLines.count > 300 { lastLines.keys.prefix(lastLines.count - 300).forEach { lastLines.removeValue(forKey: $0) } }
        UserDefaults.standard.set(lastLines, forKey: "last_lines")
        chats = decorate(chats)
    }

    func isGeneral(_ row: ChatRow) -> Bool {
        if let own { return row.profile == nil || row.profile == own.name }
        return row.defaultProfile
    }

    /// One tab's chats in sections. The full list is one run, the newest at the top.
    func sections(tab: String?, query: String) -> [(String, [ChatRow])] {
        let standing: [ChatRow] = tab == Store.allTab ? profiles.compactMap(\.chat) : [profiles.first { tab == nil ? $0.own : $0.name == tab }?.chat].compactMap { $0 }
        let needle = query.trimmingCharacters(in: .whitespaces)
        let rows = (standing + chats.filter { row in
            (tab == Store.allTab || (tab == nil ? isGeneral(row) : row.profile == tab)) && !standing.contains { $0.id == row.id && $0.profile == row.profile }
        }).filter { needle.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(needle) || ($0.preview ?? "").localizedCaseInsensitiveContains(needle) }
        if tab == Store.allTab { return rows.isEmpty ? [] : [("전체", rows.sorted { ($0.lastActiveAt ?? 0) > ($1.lastActiveAt ?? 0) })] }
        var out: [(String, [ChatRow])] = [("봇 채팅", rows.filter { $0.kind == .bot }),
                                          ("대화", rows.filter { $0.kind == .chat }.sorted { $0.pinned && !$1.pinned })]
        let messaging = Dictionary(grouping: rows.filter { $0.kind == .messaging }) { $0.source ?? "messaging" }
        out += messaging.keys.sorted().map { (platformLabel($0), messaging[$0] ?? []) }
        out.append(("크론 작업", rows.filter { $0.kind == .cron }))
        return out.filter { !$0.1.isEmpty }
    }

    // MARK: Opening and sending

    /// A new chat with `profile`'s bot. An answer being written in the chat on screen goes on at the server.
    func newChat(profile: String?) {
        self.profile = profile
        openRow = nil
        runtimeId = nil
        storedId = nil
        openedId = nil
        title = nil
        messages = []
        approvals = []
        opening = false
        markRunning()
    }

    func open(_ row: ChatRow) {
        if row.id == openedId, runtimeId != nil || opening { return }
        let ownName = own?.name
        profile = (row.profile == ownName || (ownName == nil && row.defaultProfile)) ? nil : row.profile
        openRow = row
        runtimeId = nil
        storedId = row.id
        openedId = row.id
        title = row.title
        messages = []
        approvals = []
        opening = true
        markRunning()
        Task {
            await resume(row.id)
            await markRead(row)
        }
    }

    private func resume(_ stored: String) async {
        var params: JSON = ["session_id": stored]
        if !authority { params["inline_images"] = false }
        let (result, _) = await call("session.resume", params, profile: profile)
        guard storedId == stored else { return }
        opening = false
        guard let result, let live = result.text("session_id") else {
            if link == .online, messages.isEmpty { notice = "대화를 열지 못했어요" }
            return
        }
        runtimeId = live
        storedId = result.text("stored_session_id") ?? result.text("session_key") ?? result.object("info")?.text("stored_session_id") ?? stored
        let history = result["messages"] is [Any] ? Parse.history(result.rows("messages")) : nil
        let running = result.flag("running") ?? result.object("info")?.flag("running") ?? false
        // The transcript already holds this screen's own messages after a reconnect.
        if messages.isEmpty, let history { messages = history }
        if running, messages.last?.status != .writing { messages.append(Message(id: UUID().uuidString, role: .assistant, text: "", status: .writing)) }
        if !running, let index = messages.lastIndex(where: { $0.status == .writing }) {
            // The answer finished while the socket was away: the transcript has all of it.
            if let whole = history?.last(where: { $0.role == .assistant })?.text, whole.count >= messages[index].text.count { messages[index].text = whole }
            messages[index].status = .done
        }
        rememberLastLine()
        markRunning()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        draft = ""
        let question = Message(id: UUID().uuidString, role: .user, text: text, status: .sending)
        messages.append(question)
        // The answer's place is there at once: its first words can arrive before the server's receipt.
        messages.append(Message(id: UUID().uuidString, role: .assistant, text: "", status: .writing))
        UserDefaults.standard.set("", forKey: "draft")
        markRunning()
        let target = openedId
        Task {
            if runtimeId == nil {
                var params: JSON = [:]
                if authority { params["request_id"] = UUID().uuidString }
                let (result, error) = await call("session.create", params, profile: profile)
                guard openedId == target else { return }
                guard let result, let live = result.text("session_id") else { return fail(question.id, error ?? "새 대화를 만들지 못했어요") }
                runtimeId = live
                storedId = result.text("stored_session_id") ?? result.text("session_key") ?? result.object("info")?.text("stored_session_id")
                openedId = storedId
            }
            guard let live = runtimeId else { return }
            var params: JSON = ["session_id": live, "text": text]
            if authority { params["submission_id"] = UUID().uuidString }
            let (result, error) = await call("prompt.submit", params, profile: profile)
            guard runtimeId == live else { return }
            if result == nil { return fail(question.id, error ?? "보내지 못했어요") }
            if let index = messages.firstIndex(where: { $0.id == question.id }) { messages[index].status = .done }
        }
    }

    private func fail(_ id: String, _ reason: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].status = .failed(reason) }
        // The empty answer that waited for it goes.
        messages.removeAll { $0.role == .assistant && $0.status == .writing && $0.text.isEmpty }
        markRunning()
    }

    func stop() {
        guard let live = runtimeId else { return }
        Task { _ = await call("session.interrupt", ["session_id": live], profile: profile) }
    }

    func answer(_ request: ApprovalRequest, allow: Bool) {
        let choice = allow ? (request.choices.contains("once") ? "once" : request.choices.first { $0 != "deny" }) : (request.choices.contains("deny") ? "deny" : nil)
        guard let choice else { return }
        sendRaw("{\"jsonrpc\":\"2.0\",\"id\":\(request.id),\"result\":{\"choice\":\"\(choice)\"}}")
        approvals.removeAll { $0.id == request.id }
    }

    // MARK: Changing a chat

    /// The server commits a change only with a request id and the revision the client last saw, so each
    /// one first reads the chat's snapshot.
    private func revision(_ row: ChatRow) async -> (exists: Bool, revision: Int, generation: Int?)? {
        guard let endpoint else { return nil }
        let scope = row.profile.map { "?profile=" + $0.urlEncoded } ?? ""
        guard let reply = await Server.shared.call(endpoint, "GET", "/api/sessions/\(row.id.urlEncoded)/mutation-snapshot\(scope)") as? JSON else { return nil }
        return (reply.flag("exists") == true, Int(reply.number("runtime_revision") ?? 0), reply.number("runtime_generation").map { Int($0) })
    }

    private func change(_ row: ChatRow, _ fields: JSON) async -> Bool {
        guard let endpoint, let at = await revision(row), at.exists else { return false }
        var body = fields
        body["request_id"] = UUID().uuidString
        body["expected_revision"] = at.revision
        if let generation = at.generation { body["expected_generation"] = generation }
        if let profile = row.profile { body["profile"] = profile }
        let reply = await Server.shared.call(endpoint, "PATCH", "/api/sessions/\(row.id.urlEncoded)", body: body) as? JSON
        return reply != nil && reply?.flag("ok") != false
    }

    private func edit(_ row: ChatRow, _ change: (inout ChatRow) -> Bool) {
        chats = chats.compactMap { current in
            guard current.id == row.id, current.profile == row.profile else { return current }
            var next = current
            return change(&next) ? next : nil
        }
    }

    private func settled(_ text: String) async {
        notice = text
        await refreshChats()
    }

    func markRead(_ row: ChatRow) async {
        guard row.kind != .bot else { return }
        edit(row) { $0.unread = false; return true }
        _ = await change(row, ["unread": false])
    }

    func rename(_ row: ChatRow, to name: String) async {
        edit(row) { $0.title = name; return true }
        if openedId == row.id { title = name }
        await settled(await change(row, ["title": name]) ? "이름을 바꿨어요" : "이름을 바꾸지 못했어요")
    }

    func pin(_ row: ChatRow, _ pinned: Bool) async {
        edit(row) { $0.pinned = pinned; return true }
        let ok = await change(row, ["pinned": pinned])
        await settled(!ok ? "바꾸지 못했어요" : pinned ? "맨 위에 고정했어요" : "고정을 풀었어요")
    }

    func archive(_ row: ChatRow) async {
        edit(row) { _ in false }
        await settled(await change(row, ["archived": true]) ? "보관했어요. 메뉴의 보관한 대화에 있어요" : "보관하지 못했어요")
    }

    func unarchive(_ row: ChatRow) async {
        archived.removeAll { $0.id == row.id && $0.profile == row.profile }
        notice = await change(row, ["archived": false]) ? "대화 목록으로 꺼냈어요" : "꺼내지 못했어요"
        await refreshArchived()
        await refreshChats()
    }

    func delete(_ row: ChatRow) async {
        if openedId == row.id { newChat(profile: profile) }
        edit(row) { _ in false }
        guard let endpoint, let at = await revision(row) else { return await settled("지우지 못했어요") }
        if !at.exists { return await settled("대화를 지웠어요") }
        var path = "/api/sessions/\(row.id.urlEncoded)?request_id=\(UUID().uuidString)&expected_revision=\(at.revision)"
        if let generation = at.generation { path += "&expected_generation=\(generation)" }
        if let profile = row.profile { path += "&profile=" + profile.urlEncoded }
        let gone = await Server.shared.call(endpoint, "DELETE", path) != nil
        await settled(gone ? "대화를 지웠어요" : "지우지 못했어요. 실행 중인 대화일 수 있어요")
    }

    // MARK: Menu

    private var tabProfile: String? { tab == Store.allTab ? nil : tab }
    private var scope: String { tabProfile.map { "?profile=" + $0.urlEncoded } ?? "" }

    func refreshCron() async {
        guard let endpoint else { return }
        menuLoading = true
        if let rows = Parse.cron(await Server.shared.call(endpoint, "GET", "/api/cron/jobs?profile=all")) { cron = rows }
        menuLoading = false
    }

    func cronAct(_ job: CronJob, _ verb: String, done: String) async {
        guard let endpoint else { return }
        let scope = job.profile.map { "?profile=" + $0.urlEncoded } ?? ""
        let reply = await Server.shared.call(endpoint, "POST", "/api/cron/jobs/\(job.id.urlEncoded)/\(verb)\(scope)")
        notice = reply == nil ? "요청하지 못했어요" : done
        await refreshCron()
    }

    func refreshCapabilities() async {
        guard let endpoint else { return }
        menuLoading = true
        if let rows = Parse.toolsets(await Server.shared.call(endpoint, "GET", "/api/tools/toolsets\(scope)")) { toolsets = rows }
        if let rows = Parse.mcpServers(await Server.shared.call(endpoint, "GET", "/api/mcp/servers\(scope)")) { mcp = rows }
        if let rows = Parse.skills(await Server.shared.call(endpoint, "GET", "/api/skills\(scope)")) { skills = rows }
        menuLoading = false
    }

    func refreshCatalogs() async {
        guard let endpoint else { return }
        menuLoading = true
        if let rows = Parse.pluginCatalog(await Server.shared.call(endpoint, "GET", "/api/dashboard/plugins/catalog")) { plugins = rows }
        if let rows = Parse.mcpCatalog(await Server.shared.call(endpoint, "GET", "/api/mcp/catalog\(scope)")) { mcpCatalog = rows }
        menuLoading = false
    }

    func refreshArchived() async {
        guard let endpoint else { return }
        menuLoading = true
        if let rows = Parse.archived(await Server.shared.call(endpoint, "GET", Parse.archivedPath)) { archived = rows }
        menuLoading = false
    }

    /// Installs `item` on the server and switches it on. A plugin is code that runs on the Hermes machine.
    func install(_ item: Installable) async {
        guard let endpoint, !item.installed, item.blocked == nil, !installing.contains(item.id) else { return }
        installing.insert(item.id)
        let reply: JSON?
        if item.plugin {
            reply = await Server.shared.call(endpoint, "POST", "/api/dashboard/agent-plugins/install", body: ["identifier": "", "catalog_name": item.name, "enable": true]) as? JSON
        } else {
            var body: JSON = ["name": item.name, "env": JSON(), "enable": true]
            if let tabProfile { body["profile"] = tabProfile }
            reply = await Server.shared.call(endpoint, "POST", "/api/mcp/catalog/install\(scope)", body: body) as? JSON
        }
        installing.remove(item.id)
        if reply == nil { notice = "\(item.title): 설치하지 못했어요" }
        else if reply?.flag("ok") == false { notice = reply?.flag("consent_required") == true ? "\(item.title): 권한 동의가 필요해요. Webapp에서 설치해 주세요" : "\(item.title): 설치가 거부됐어요" }
        else { notice = "\(item.title): 설치했어요" }
        await refreshCatalogs()
    }
}
