import Foundation

/// One Gemini Live websocket. The message cap is raised well past URLSession's 1 MB default:
/// a long answer arrives as many frames, and a small cap is how the tail of an answer used to vanish.
final class LiveSocket: @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var closingByUs = false
    private var reported = false
    private var ping: Timer?

    var onOpened: (() -> Void)?
    var onText: ((String) -> Void)?
    var onClosed: ((String?) -> Void)?

    init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    func connect(_ urlString: String) {
        close()
        lock.lock()
        closingByUs = false
        reported = false
        lock.unlock()
        guard let url = URL(string: urlString) else { report("bad url"); return }
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
                self.report(error.localizedDescription)
            }
        }
    }

    private func report(_ reason: String) {
        lock.lock()
        if closingByUs || reported {
            lock.unlock()
            return
        }
        reported = true
        lock.unlock()
        onClosed?(reason)
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
