import XCTest
@testable import HermesVoiceCore
#if canImport(AVFoundation)
import AVFoundation
#endif

final class AudioClockTests: XCTestCase {
    func testPlayedFramesStayZeroUntilASampleTimeExists() {
        XCTAssertEqual(PlaybackClock.frames(allowed: false, sampleTime: 48_000, headOffset: 0, enqueued: 48_000), 0)
        XCTAssertEqual(PlaybackClock.frames(allowed: true, sampleTime: nil, headOffset: 0, enqueued: 48_000), 0)
        XCTAssertEqual(PlaybackClock.frames(allowed: true, sampleTime: 1_200, headOffset: 1_000, enqueued: 500), 200)
        XCTAssertEqual(PlaybackClock.frames(allowed: true, sampleTime: 10, headOffset: 40, enqueued: 100), 0)
    }

    #if canImport(AVFoundation)
    /// An unattached player. `lastRenderTime` here is the device crash; these calls must not reach it.
    func testPlayedFramesAndStopPlaybackOnAnUnpreparedEngineDoNotCrash() {
        let playback = EnginePlayback()
        XCTAssertFalse(playback.ready(prepared: false, running: false))
        XCTAssertFalse(playback.ready(prepared: true, running: true))
        XCTAssertNil(playback.sampleTime(prepared: false, running: false))
        XCTAssertNil(playback.sampleTime(prepared: true, running: false))
        XCTAssertNil(playback.sampleTime(prepared: true, running: true))
        XCTAssertEqual(playback.playedFrames(prepared: false, running: false, headOffset: 0, enqueued: 24_000), 0)
        XCTAssertEqual(playback.playedFrames(prepared: true, running: false, headOffset: 0, enqueued: 24_000), 0)
        XCTAssertEqual(playback.playedFrames(prepared: true, running: true, headOffset: 100, enqueued: 24_000), 0)
        playback.stopPlayback(prepared: false, running: false)
        playback.stopPlayback(prepared: true, running: false)
        playback.stopPlayback(prepared: true, running: true)
        playback.play(prepared: true, running: true)
        XCTAssertFalse(playback.isPlaying(prepared: true, running: true))
        playback.setRate(1.25, prepared: false, running: false)
        playback.setPitch(0, prepared: true, running: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
        buffer.frameLength = 64
        XCTAssertFalse(playback.schedule(buffer, prepared: false, running: false) {})
        XCTAssertFalse(playback.schedule(buffer, prepared: true, running: true) {})
    }
    #endif
}
