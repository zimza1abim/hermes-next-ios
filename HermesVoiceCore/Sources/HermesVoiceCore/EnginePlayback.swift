import Foundation

/// Played-frame math with the engine question already answered. A missing sample time is silence, not a guess.
public enum PlaybackClock {
    public static func frames(allowed: Bool, sampleTime: Int64?, headOffset: Int64, enqueued: Int64) -> Int64 {
        guard allowed, let sampleTime else { return 0 }
        let played = sampleTime - headOffset
        return min(max(played, 0), max(enqueued, 0))
    }
}

#if canImport(AVFoundation)
import AVFoundation

/// The player and the time-pitch unit. Every call that needs the engine checks
/// `prepared && player.engine != nil && running` first: `lastRenderTime` on a node
/// that is not attached raises an ObjC exception.
public final class EnginePlayback: @unchecked Sendable {
    public let player = AVAudioPlayerNode()
    public let pitch = AVAudioUnitTimePitch()

    public init() {}

    public func ready(prepared: Bool, running: Bool) -> Bool {
        prepared && player.engine != nil && running
    }

    /// Sample time of what the player has rendered, or nil when the node cannot be asked.
    public func sampleTime(prepared: Bool, running: Bool) -> Int64? {
        guard ready(prepared: prepared, running: running) else { return nil }
        guard let nodeTime = player.lastRenderTime,
              let time = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return time.sampleTime
    }

    public func playedFrames(prepared: Bool, running: Bool, headOffset: Int64, enqueued: Int64) -> Int64 {
        let sample = sampleTime(prepared: prepared, running: running)
        return PlaybackClock.frames(allowed: sample != nil, sampleTime: sample, headOffset: headOffset, enqueued: enqueued)
    }

    public func stopPlayback(prepared: Bool, running: Bool) {
        guard ready(prepared: prepared, running: running) else { return }
        player.stop()
    }

    public func play(prepared: Bool, running: Bool) {
        guard ready(prepared: prepared, running: running) else { return }
        player.play()
    }

    public func isPlaying(prepared: Bool, running: Bool) -> Bool {
        guard ready(prepared: prepared, running: running) else { return false }
        return player.isPlaying
    }

    public func setRate(_ rate: Float, prepared: Bool, running: Bool) {
        guard ready(prepared: prepared, running: running) else { return }
        pitch.rate = min(max(rate, 0.5), 2)
    }

    public func setPitch(_ cents: Float, prepared: Bool, running: Bool) {
        guard ready(prepared: prepared, running: running) else { return }
        pitch.pitch = cents
    }

    public func schedule(_ buffer: AVAudioPCMBuffer, prepared: Bool, running: Bool, completion: @escaping () -> Void) -> Bool {
        guard ready(prepared: prepared, running: running) else { return false }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
        return true
    }
}
#endif
