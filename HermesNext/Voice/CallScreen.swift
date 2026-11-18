import SwiftUI
import UIKit
import HermesVoiceCore

/// The call, drawn over the chat. The aura's display link is the only per-frame work; this body
/// changes when the phase, the captions or a control changes.
struct CallScreen: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var controller: LiveController
    var progress: CGFloat
    var onMinimize: () -> Void
    @State private var animator = AuraAnimator(mood: .connecting)
    @State private var revealed = 0
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var settings = false
    @State private var moodKey = ""
    @State private var phaseKey = ""
    @State private var interruptSeq = 0

    var body: some View {
        let state = controller.state
        let booting = controller.booting && isIdle(state.phase)
        let mood = AuraMoods.moodOf(booting ? connectingStandIn(state) : state, interruptedRecently: interrupted)
        let name = state.botName?.isEmpty == false ? state.botName! : "Hermes"
        let model = captionModel(
            state: booting ? connectingStandIn(state) : state,
            botName: name,
            interrupt: controller.interrupt,
            interruptedRecently: interrupted,
            liveBotText: controller.liveBotText(),
            clock: clock
        )
        ZStack {
            CallTokens.base.ignoresSafeArea()
            AuraLayer(
                animator: animator,
                calm: reduceMotion,
                detail: lowPower ? 2 : 4,
                halfRate: lowPower,
                mini: false,
                palette: controller.palette,
                signals: { controller.signalSnapshot() },
                onRevealed: { revealed = $0 }
            )
            .ignoresSafeArea()
            DotGrid().ignoresSafeArea()
            VStack(spacing: 0) {
                CallTopBar(
                    name: name,
                    status: booting ? "연결하는 중" : callStatus(state),
                    statusColor: statusColor(state),
                    started: controller.startedAt,
                    image: store.avatars[store.openBot?.name ?? "default"],
                    onName: { settings = true }
                )
                KineticCaptions(model: model, revealed: revealed, subtitles: state.subtitlesOn)
                    .padding(.top, CallTokens.captionTop - CallTokens.topBarHeight)
                    .frame(height: CallTokens.captionHeight)
                if let approval = state.approval {
                    ApprovalStrip(approval: approval)
                }
                Spacer()
                if let reason = endedReason(state.phase) {
                    ended(reason, notice: state.notice)
                } else {
                    CallPill(
                        muted: state.muted,
                        onMic: { controller.toggleMute() },
                        onSpeaker: { controller.toggleSpeaker() },
                        onKeyboard: { onMinimize() },
                        onSubtitles: { controller.toggleSubtitles() },
                        onHangUp: { controller.hangUp() }
                    )
                }
            }
        }
        .opacity(progress < 0.35 ? 1 - Double(progress) / 0.35 : 0)
        .scaleEffect(1 - 0.06 * progress, anchor: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            apply(mood)
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: mood.rawValue) { _, key in
            guard key != moodKey else { return }
            moodKey = key
            animator.go(mood: mood, calm: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, calm in animator.go(mood: mood, calm: calm) }
        .onChange(of: phaseToken(state.phase)) { _, token in
            react(from: phaseKey, to: token, phase: state.phase)
            phaseKey = token
        }
        .onChange(of: controller.interrupt?.seq ?? 0) { _, seq in
            guard seq != interruptSeq, seq != 0 else { return }
            interruptSeq = seq
            animator.flashNow(calm: reduceMotion)
            CallHaptics.interrupt()
        }
        .onChange(of: store.approvals) { _, list in
            if let first = list.first {
                controller.approvalShown(VoiceApproval(id: first.id, tool: "command", prompt: first.command))
            } else if state.approval != nil {
                controller.approvalResolved()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .sheet(isPresented: $settings) {
            NavigationStack { VoiceSettingsView() }
                .preferredColorScheme(.light)
                .tint(Rose.deep)
        }
    }

    private var interrupted: Bool {
        guard let mark = controller.interrupt else { return false }
        return Date().timeIntervalSince1970 * 1000 - mark.atMs < AuraMoods.interruptHoldMs
    }

    private var clock: String {
        guard let started = controller.startedAt else { return "0:00" }
        return formatClock(Date().timeIntervalSince(started) * 1000)
    }

    private func connectingStandIn(_ state: VoiceState) -> VoiceState {
        var next = state
        next.phase = .connecting
        return next
    }

    private func apply(_ mood: AuraMood) {
        moodKey = mood.rawValue
        animator.go(mood: mood, calm: reduceMotion)
    }

    private func react(from: String, to: String, phase: VoicePhase) {
        if to == "listening", from == "connecting" || from == "reconnecting" || from.isEmpty { CallHaptics.connected() }
        if to == "delegating" { CallHaptics.working() }
        if to == "ended" {
            if case .ended(.user) = phase { CallHaptics.hangUp() } else { CallHaptics.error() }
            guard case .ended(.user) = phase else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(1400))
                if case .ended(.user) = controller.state.phase { VoiceCenter.shared.dismiss() }
            }
        }
    }

    private func statusColor(_ state: VoiceState) -> Color {
        switch state.phase {
        case .listening: state.muted ? CallTokens.reconnecting : CallTokens.online
        case .reconnecting: CallTokens.reconnecting
        case .ended(let reason): reason == .user ? CallTokens.textFaint : CallTokens.error
        case .delegating: CallTokens.accentLight
        default: CallTokens.accentLight
        }
    }

    @ViewBuilder private func ended(_ reason: VoiceEndReason, notice: String?) -> some View {
        VStack(spacing: 12) {
            if let notice, !notice.isEmpty {
                Text(notice).font(.app(size: CallTypeScale.current.hint)).foregroundStyle(CallTokens.error).multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                if reason != .user {
                    Button("다시 시도") { controller.retry() }
                        .buttonStyle(.plain)
                        .font(.app(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(minWidth: 120, minHeight: 48)
                        .background(CallTokens.accent)
                        .clipShape(Capsule())
                }
                Button("닫기") { VoiceCenter.shared.dismiss() }
                    .buttonStyle(.plain)
                    .font(.app(size: 16))
                    .foregroundStyle(CallTokens.textStrong)
                    .frame(minWidth: 88, minHeight: 48)
                    .background(CallTokens.glass)
                    .clipShape(Capsule())
            }
        }
        .padding(.bottom, CallTokens.pillBottom)
    }

    private func phaseToken(_ phase: VoicePhase) -> String {
        switch phase {
        case .idle: "idle"
        case .connecting: "connecting"
        case .listening: "listening"
        case .modelSpeaking: "speaking"
        case .delegating: "delegating"
        case .reconnecting: "reconnecting"
        case .ended: "ended"
        }
    }

    private func isIdle(_ phase: VoicePhase) -> Bool {
        if case .idle = phase { return true }
        return false
    }

    private func endedReason(_ phase: VoicePhase) -> VoiceEndReason? {
        if case .ended(let reason) = phase { return reason }
        return nil
    }
}

private struct ApprovalStrip: View {
    @Environment(Store.self) private var store
    let approval: VoiceApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("승인이 필요해요").font(.app(size: 13, weight: .medium)).foregroundStyle(CallTokens.captionHint)
            Text(approval.prompt).font(.app(size: 15)).foregroundStyle(CallTokens.textStrong).lineLimit(3)
            HStack(spacing: 8) {
                Button("허용") { act(true) }.buttonStyle(.plain).foregroundStyle(.white).padding(.horizontal, 16).frame(minHeight: 36).background(CallTokens.online).clipShape(Capsule())
                Button("거절") { act(false) }.buttonStyle(.plain).foregroundStyle(CallTokens.textStrong).padding(.horizontal, 16).frame(minHeight: 36).background(CallTokens.glass).clipShape(Capsule())
            }
        }
        .padding(14)
        .background(CallTokens.glass)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(CallTokens.glassBorder, lineWidth: 1))
        .padding(.horizontal, CallTokens.screenHPadding)
    }

    private func act(_ allow: Bool) {
        guard let request = store.approvals.first(where: { $0.id == approval.id }) ?? store.approvals.first else { return }
        store.answer(request, allow: allow)
    }
}

/// Full screen, or the bar the chat keeps while the call runs underneath.
struct CallOverlay: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var barAnimator = AuraAnimator(mood: .listening)

    private var center: VoiceCenter { VoiceCenter.shared }

    var body: some View {
        ZStack(alignment: .top) {
            if center.mode == .full, let controller = center.controller {
                CallScreen(controller: controller, progress: center.collapse, onMinimize: minimize)
                    .ignoresSafeArea()
                    .zIndex(2)
            }
            if center.mode == .minimized, let controller = center.controller, barVisible(controller) {
                CallBar(
                    name: controller.state.botName?.isEmpty == false ? controller.state.botName! : "Hermes",
                    status: callStatus(controller.state),
                    started: controller.startedAt,
                    image: store.avatars[store.openBot?.name ?? "default"],
                    animator: barAnimator,
                    calm: reduceMotion,
                    lowPower: lowPower,
                    palette: controller.palette,
                    signals: { controller.signalSnapshot() },
                    onOpen: expand,
                    onHangUp: {
                        controller.hangUp()
                        center.dismiss()
                    }
                )
                .zIndex(2)
            }
        }
        .onChange(of: center.mode) { _, mode in
            if mode == .minimized, let controller = center.controller {
                let mood = AuraMoods.moodOf(controller.state, interruptedRecently: false)
                barAnimator.go(mood: mood, calm: reduceMotion)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private func minimize() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            center.collapse = 1
        } completion: {
            center.minimize()
        }
    }

    private func expand() {
        center.collapse = 1
        center.expand()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            center.collapse = 0
        }
    }

    private func barVisible(_ controller: LiveController) -> Bool {
        if case .idle = controller.state.phase { return false }
        if case .ended = controller.state.phase { return false }
        return true
    }
}
