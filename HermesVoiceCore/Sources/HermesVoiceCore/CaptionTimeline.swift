import Foundation

/// 끼어들기 순간의 스냅샷. `revealedChars` 뒤는 "못 한 말"이다.
public struct InterruptMark: Equatable, Sendable {
    public var seq: Int
    public var text: String
    public var revealedChars: Int
    public var atMs: Double

    public init(seq: Int, text: String, revealedChars: Int, atMs: Double) {
        self.seq = seq
        self.text = text
        self.revealedChars = revealedChars
        self.atMs = atMs
    }
}

/// 봇 한 턴의 자막 글자 ↔ 오디오 시각.
///
/// 단어별 시각이 API에 없으므로 두 근거만 쓴다: 자막이 도착한 순간까지 받은 오디오 길이(앵커), 그리고
/// 글자당 발음 무게 하한. 둘 다 실제보다 늦거나 같은 쪽으로 틀리므로, 단어가 소리보다 먼저 나오지 않는다.
public final class CaptionTimeline {

    public struct Snapshot: Equatable, Sendable {
        public var text: String
        public var revealedChars: Int
    }

    private struct Anchor {
        var chars: Int
        var ms: Double
    }

    private let lock = NSLock()
    private let msPerWeight: Double
    private var text = ""
    private var anchors: [Anchor] = []
    private var weights: [Double] = [0]
    private var inTurn = false
    private var turnBase: Int64 = 0
    private var received: Int64 = 0
    private var rate: Int = 24_000

    public init(msPerWeight: Double = 105) {
        self.msPerWeight = msPerWeight
    }

    public func onAudio(frames: Int, sampleRate: Int, enqueuedBefore: Int64) {
        lock.lock(); defer { lock.unlock() }
        if !inTurn { begin(enqueuedBefore) }
        rate = sampleRate
        received += Int64(frames)
    }

    public func onTranscript(_ chunk: String, enqueuedNow: Int64) {
        lock.lock(); defer { lock.unlock() }
        if !inTurn { begin(enqueuedNow) }
        for ch in chunk {
            text.append(ch)
            weights.append(weights.last! + weight(ch))
        }
        anchors.append(Anchor(chars: text.count, ms: Double(received) * 1000 / Double(rate)))
    }

    public func endTurn() {
        lock.lock(); defer { lock.unlock() }
        inTurn = false
    }

    public func currentText() -> String {
        lock.lock(); defer { lock.unlock() }
        return text
    }

    public func revealedChars(playedFrames: Int64) -> Int {
        lock.lock(); defer { lock.unlock() }
        return revealedLocked(playedFrames)
    }

    public func estimatedStartMs(_ index: Int) -> Double {
        lock.lock(); defer { lock.unlock() }
        return startMs(index)
    }

    public func snapshot(playedFrames: Int64) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(text: text, revealedChars: revealedLocked(playedFrames))
    }

    private func begin(_ base: Int64) {
        inTurn = true
        turnBase = base
        received = 0
        text = ""
        anchors = []
        weights = [0]
    }

    private func revealedLocked(_ playedFrames: Int64) -> Int {
        let heardMs = Double(max(playedFrames - turnBase, 0)) * 1000 / Double(rate)
        var n = 0
        // 엄격한 부등호: 아직 아무 소리도 안 나왔으면(heardMs=0) 첫 글자도 나오면 안 된다.
        while n < text.count && startMs(n) < heardMs { n += 1 }
        return n
    }

    private func startMs(_ index: Int) -> Double {
        guard index < weights.count else { return .greatestFiniteMagnitude }
        let floor = weights[index] * msPerWeight
        var prevChars = 0
        var prevMs = 0.0
        for anchor in anchors {
            if index < anchor.chars {
                let span = Double(max(anchor.chars - prevChars, 1))
                let interp = prevMs + (anchor.ms - prevMs) * Double(index - prevChars) / span
                return max(interp, floor)
            }
            prevChars = anchor.chars
            prevMs = anchor.ms
        }
        return max(prevMs, floor)
    }

    private func weight(_ ch: Character) -> Double {
        if let scalar = ch.unicodeScalars.first, (0xAC00...0xD7A3).contains(scalar.value) { return 1 }
        if ch.isLetter { return 0.35 }
        if ch.isNumber { return 0.6 }
        return 0
    }
}
