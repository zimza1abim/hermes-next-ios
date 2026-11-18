import Foundation

/// One Gemini Live websocket. The message cap is raised well past URLSession's 1 MB default:
/// a long answer arrives as many frames, and a small cap is how the tail of an answer used to vanish.
final class LiveSocket: @unchecked Sendable {
    /// URLSession retains its delegate. This stays weak so a closed socket can deinit.
    private final class Watcher: NSObject, URLSessionWebSocketDelegate {
        weak var owner: LiveSocket?
        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
            reason: Data?
        ) {
            let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            owner?.finish(code: closeCode.rawValue, reason: text, detail: "", definitive: true)
        }
    }

    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var closingByUs = false
    private var reported = false
    private var waiting = false
    private var bestCode = 0
    private var bestReason = ""
    private var bestDetail = ""
    private var ping: Timer?

    var onOpened: (() -> Void)?
    var onText: ((String) -> Void)?
    /// Close code, the server's close reason, and the URLSession error text. Quota looks at the first two only.
    var onClosed: ((Int, String, String) -> Void)?

    init() {
        let watcher = Watcher()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: watcher, delegateQueue: .main)
        watcher.owner = self
    }

    func connect(_ urlString: String) {
        close()
        lock.lock()
        closingByUs = false
        reported = false
        waiting = false
        bestCode = 0
        bestReason = ""
        bestDetail = ""
        lock.unlock()
        guard let url = URL(string: urlString) else { finish(code: 0, reason: "", detail: "bad url", definitive: true); return }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        lock.lock()
        self.task = task
        lock.unlock()
        task.resume()
        DispatchQueue.main.async { [weak self] in
            self?.onOpened?()
            self?.schedulePing(task)
        }
        receive(task)
    }

    func send(_ text: String) {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.send(.string(text)) { _ in }
    }

    func close() {
        lock.lock()
        closingByUs = true
        let task = self.task
        self.task = nil
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.ping?.invalidate()
            self?.ping = nil
        }
        task?.cancel(with: .normalClosure, reason: nil)
    }

    private func schedulePing(_ task: URLSessionWebSocketTask) {
        ping?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak task] _ in
            task?.sendPing { _ in }
        }
        ping = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            let current = self.task === task
            self.lock.unlock()
            guard current else { return }
            switch result {
            case .success(let message):
                let text: String?
                switch message {
                case .string(let value): text = value
                case .data(let data): text = String(data: data, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text { self.onText?(text) }
                self.receive(task)
            case .failure(let error):
                let (code, reason) = self.closeFields(task, error: error)
                self.finish(code: code, reason: reason, detail: error.localizedDescription, definitive: code != 0)
            }
        }
    }

    private func closeFields(_ task: URLSessionWebSocketTask, error: Error) -> (Int, String) {
        let fromTask = task.closeCode.rawValue
        let taskReason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if fromTask != 0 || !taskReason.isEmpty { return (fromTask, taskReason) }
        let info = (error as NSError).userInfo
        let code = (info["NSURLErrorWebSocketCloseCode"] as? NSNumber)?.intValue
            ?? (info["_NSURLErrorWebSocketCloseCode"] as? NSNumber)?.intValue
            ?? 0
        let reason = info["NSURLErrorWebSocketCloseReason"] as? String
            ?? (info["_NSURLErrorWebSocketCloseReason"] as? Data).flatMap { String(data: $0, encoding: .utf8) }
            ?? ""
        return (code, reason)
    }

    /// `definitive` is the delegate's close. A receive failure with no code waits briefly for that close.
    private func finish(code: Int, reason: String, detail: String, definitive: Bool) {
        lock.lock()
        if closingByUs || reported {
            lock.unlock()
            return
        }
        if code != 0 { bestCode = code }
        if !reason.isEmpty { bestReason = reason }
        if !detail.isEmpty { bestDetail = detail }
        let ready = definitive || bestCode != 0
        if !ready {
            if !waiting {
                waiting = true
                lock.unlock()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.finish(code: 0, reason: "", detail: "", definitive: true)
                }
            } else {
                lock.unlock()
            }
            return
        }
        reported = true
        let codeOut = bestCode
        let reasonOut = bestReason
        let detailOut = bestDetail
        lock.unlock()
        onClosed?(codeOut, reasonOut, detailOut)
    }
}

/// Mic audio is produced off the main thread. This is the only object that thread is allowed to touch.
final class SocketSend: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: LiveSocket?
    private var enabled = false

    func update(socket: LiveSocket?, enabled: Bool) {
        lock.lock()
        self.socket = socket
        self.enabled = enabled
        lock.unlock()
    }

    func send(_ text: String) {
        lock.lock()
        let socket = self.socket
        let enabled = self.enabled
        lock.unlock()
        guard enabled else { return }
        socket?.send(text)
    }
}
