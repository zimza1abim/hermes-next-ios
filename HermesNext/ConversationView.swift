import SwiftUI

/// One conversation: the transcript, the answer as it is written, and the input.
struct ConversationView: View {
    @Environment(Store.self) private var store
    @Environment(\.horizontalSizeClass) private var width
    /// Back to the list; `slide` is false when a swipe already moved the screen away.
    let back: (_ slide: Bool) -> Void
    @FocusState private var typing: Bool
    /// How far a swipe back has moved the screen; 0 when no swipe is going on.
    @State private var swipe: CGFloat = 0

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            if store.messages.isEmpty && store.approvals.isEmpty {
                if store.opening { Spacer(); ProgressView().tint(Rose.deep); Spacer() } else { greeting }
            } else {
                transcript
            }
            if store.link == .offline {
                HStack {
                    Text("서버에 닿지 않아요. 쓰던 글은 그대로 있어요").font(.app(size: 13.5)).foregroundStyle(Rose.text)
                    Spacer()
                    PillButton(label: "다시 연결") { store.reconnect() }
                }
                .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
                .background(Rose.soft).clipShape(RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 20).padding(.bottom, 8)
            }
            SlashMenu()
            input(draft: $store.draft)
        }
        .background(Rose.panel.ignoresSafeArea())
        .offset(x: swipe)
        .simultaneousGesture(swipeBack, including: width == .compact ? .all : .subviews)
        // The draft is kept once typing pauses, not on every key.
        .task(id: store.draft) {
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { UserDefaults.standard.set(store.draft, forKey: "draft") }
        }
    }

    /// On a phone, a swipe to the right that starts at the screen's left edge goes back to the list, as the
    /// system's own edge swipe does. The screen follows the finger and settles back when the swipe is short.
    /// A drag that starts anywhere else is left alone: selecting text or scrolling a wide code block or table
    /// no longer moves the screen.
    private var swipeBack: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .global)
            .onChanged { drag in
                guard drag.startLocation.x < Self.edge, drag.translation.width > 0,
                      abs(drag.translation.width) > abs(drag.translation.height) * 1.5 else { return }
                swipe = drag.translation.width
            }
            .onEnded { drag in
                guard swipe > 0 else { return }
                let screen = UIScreen.main.bounds.width
                if drag.translation.width > screen * 0.3 || drag.predictedEndTranslation.width > screen * 0.6 {
                    typing = false
                    withAnimation(.easeOut(duration: 0.18)) { swipe = screen } completion: {
                        // The screen is already off to the side: it goes from there, with no second slide.
                        // The offset is left as it is; the view is gone and a new one starts at zero.
                        back(false)
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { swipe = 0 }
                }
            }
    }

    /// How far from the left edge a swipe back may start, in points.
    private static let edge: CGFloat = 24

    private var header: some View {
        HStack(spacing: 9) {
            if width == .compact { RoundIcon(system: "chevron.left", label: "대화 목록") { back(true) } }
            BotAvatar(image: store.avatars[store.openBot?.name ?? "default"], size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.title ?? (store.messages.isEmpty ? "새 대화" : "대화")).font(.app(size: 16.5, weight: .bold)).foregroundStyle(Rose.text).lineLimit(1)
                HStack(spacing: 6) {
                    let writing = store.messages.last?.status == .writing
                    StatusDot(color: writing ? Rose.deep : store.link.color, blinking: writing || store.link == .connecting)
                    Text(writing ? "WRITING" : store.link.label).font(.app(size: 10.5, design: .monospaced)).foregroundStyle(Rose.muted)
                }
            }
            Spacer()
            RoundIcon(system: "plus", label: "새 대화", filled: true) { store.newChat(profile: store.profile) }
        }
        .padding(.leading, width == .compact ? 8 : 20).padding(.trailing, 14).padding(.top, 10).padding(.bottom, 6)
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer()
            Text("반가워요").font(.app(size: 13)).foregroundStyle(Rose.muted)
            Text("무엇을 도와드릴까요?").font(.app(size: 26, weight: .bold, design: .serif)).foregroundStyle(Rose.text)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity).padding(.horizontal, 24)
    }

    /// How many of the newest messages are drawn; earlier ones come in on a tap.
    @State private var shown = 120

    private var transcript: some View {
        ScrollViewReader { proxy in
            // One copy of the messages for this drawing: the range, the rows and each row's neighbour all come
            // from it. Reading the store again inside the rows crashed when another chat opened between the two
            // reads and the list got shorter (a range whose start passed its end).
            let messages = store.messages
            let first = max(0, messages.count - shown)
            let rows = Array(messages.enumerated().dropFirst(first))
            ScrollView {
                // A plain stack, not a lazy one: a lazy stack pinned to the bottom skipped rows whose height it
                // guessed wrong, so an opened chat stayed blank and a sent question did not show.
                VStack(alignment: .leading, spacing: 22) {
                    if first > 0 {
                        Button { shown += 120 } label: {
                            Text("이전 메시지 \(first)개 더 보기").font(.app(size: 13)).foregroundStyle(Rose.chipText)
                                .padding(.horizontal, 14).frame(minHeight: 36).background(Rose.soft).clipShape(Capsule())
                        }
                        .buttonStyle(.plain).frame(maxWidth: .infinity)
                    }
                    ForEach(rows, id: \.element.id) { index, message in
                        MessageView(message: message, botTitle: store.openBot?.title, image: store.avatars[store.openBot?.name ?? "default"],
                                    // The bot is named once per answer, not on each part a tool call split it into.
                                    named: index == 0 || messages[index - 1].role == .user)
                            // Only the message that changed is drawn again while an answer streams.
                            .equatable()
                            .id(message.id)
                    }
                    ForEach(store.approvals) { request in ApprovalCard(request: request) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                // A readable line length on an iPad: the text does not run the full width of the screen.
                .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            // To the newest message once the rows are laid out: on opening, on each new message, as an answer grows.
            .onAppear { toBottom(proxy) }
            .onChange(of: store.openRow?.key) { _, _ in
                shown = 120
                toBottom(proxy)
            }
            .onChange(of: store.messages.count) { _, _ in toBottom(proxy, animated: true) }
            .onChange(of: store.messages.last?.text.count ?? 0) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func toBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        DispatchQueue.main.async {
            if animated { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } else { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func input(draft: Binding<String>) -> some View {
        let writing = store.busy
        let ready = !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !writing
        return HStack(alignment: .bottom, spacing: 6) {
            TextField("", text: draft, prompt: Text("무엇이든 물어보세요").foregroundStyle(Rose.muted), axis: .vertical)
                .lineLimit(1...6).font(.app(size: 16)).foregroundStyle(Rose.text).tint(Rose.deep)
                .focused($typing).padding(.leading, 14).padding(.vertical, 12)
            if writing {
                Button { store.stop() } label: {
                    RoundedRectangle(cornerRadius: 3).fill(Rose.deep).frame(width: 13, height: 13)
                        .frame(width: 44, height: 44).overlay(Circle().stroke(Rose.deep, lineWidth: 2))
                }
                .buttonStyle(.plain).accessibilityLabel("답변 중지")
            } else {
                Button {
                    typing = false
                    store.send()
                } label: {
                    Image(systemName: "arrow.up").font(.app(size: 17, weight: .bold)).foregroundStyle(ready ? Color.white : Rose.deep)
                        .frame(width: 44, height: 44).background(ready ? Rose.deep : Color(hex: 0xF3D5E3)).clipShape(Circle())
                }
                .buttonStyle(.plain).disabled(!ready).accessibilityLabel("보내기")
            }
        }
        .padding(6)
        .background(Rose.field).clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(typing ? Rose.rose : Rose.border, lineWidth: typing ? 1.5 : 1))
        .frame(maxWidth: 760).frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.bottom, 12).padding(.top, 6)
    }
}

private struct MessageView: View, Equatable {
    let message: Message
    let botTitle: String?
    let image: UIImage?
    let named: Bool
    @State private var open = false

    nonisolated static func == (a: MessageView, b: MessageView) -> Bool {
        a.message == b.message && a.botTitle == b.botTitle && a.image === b.image && a.named == b.named
    }

    var body: some View {
        switch message.role {
        case .user:
            let media = Media.extract(message.text)
            VStack(alignment: .trailing, spacing: 5) {
                if !media.sources.isEmpty { MediaStrip(sources: media.sources, trailing: true) }
                // A long question is cut and opens in full on a tap.
                if !media.text.isEmpty { Text(media.text).font(.app(size: 15.5)).lineSpacing(5).foregroundStyle(Rose.text).lineLimit(open ? nil : 12)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .background(Rose.bubble)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20))
                    .onTapGesture { open.toggle() } }
                switch message.status {
                case .sending: Text("보내는 중").font(.app(size: 10.5)).foregroundStyle(Rose.muted)
                case .failed(let reason): Text(reason).font(.app(size: 12)).foregroundStyle(Rose.deep)
                default: EmptyView()
                }
            }
            .frame(maxWidth: 520, alignment: .trailing).frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if named {
                    HStack(spacing: 8) {
                        BotAvatar(image: image, size: 42)
                        Text("@\(botTitle ?? "Hermes")").font(.app(size: 13.5, weight: .semibold)).foregroundStyle(Rose.deep)
                    }
                }
                if message.text.isEmpty {
                    if message.status == .writing { ThinkingDots() } else { Text("답변이 비어 있어요").font(.app(size: 13)).foregroundStyle(Rose.muted) }
                } else {
                    let media = Media.extract(message.text)
                    if !media.text.isEmpty { MarkdownView(text: media.text) }
                    if !media.sources.isEmpty { MediaStrip(sources: media.sources) }
                }
                switch message.status {
                case .stopped: Text("멈췄어요").font(.app(size: 13)).foregroundStyle(Rose.muted)
                case .failed(let reason): Text(reason).font(.app(size: 13)).foregroundStyle(Rose.deep)
                case .done where !message.text.isEmpty: CopyButton(text: message.text)
                default: EmptyView()
                }
            }
        }
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                copied = false
            }
        } label: {
            Label(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc").font(.app(size: 13)).foregroundStyle(Rose.text)
                .padding(.horizontal, 12).frame(minHeight: 36)
                .background(Rose.field).clipShape(Capsule()).overlay(Capsule().stroke(Rose.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct ThinkingDots: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(Rose.rose).frame(width: 7, height: 7).opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2), value: on)
            }
        }
        .padding(.vertical, 8)
        .onAppear { on = true }
    }
}

private struct ApprovalCard: View {
    @Environment(Store.self) private var store
    let request: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("명령을 실행해도 될까요?").font(.app(size: 15, weight: .bold)).foregroundStyle(Rose.text)
            Text(request.command).font(.app(size: 13, design: .monospaced)).foregroundStyle(Rose.text).lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                .background(Rose.soft).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 8) {
                PillButton(label: "거절") { store.answer(request, allow: false) }
                PillButton(label: "한 번 허용", filled: true) { store.answer(request, allow: true) }
            }
        }
        .padding(18).background(Rose.field).clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Rose.rose, lineWidth: 1))
    }
}

/// Commands, plugins and skills for a `/` at the start of the field, filtered as the name is typed.
/// The rows are read once per bot and filtered here; picking one puts `/name ` in the field.
private struct SlashMenu: View {
    @Environment(Store.self) private var store

    var body: some View {
        let query = SlashCommand.query(store.draft)
        ZStack {
            if let query {
                menu(query)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.98, anchor: .bottom)),
                                            removal: .opacity))
                    .task { store.loadSlash() }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: query != nil)
        .frame(maxWidth: 760).frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    private func menu(_ query: String) -> some View {
        let rows = store.slashItems.map { SlashCommand.filter($0, query) }
        return Group {
            if let rows {
                if rows.isEmpty {
                    Text("맞는 명령이 없어요").font(.app(size: 13)).foregroundStyle(Rose.muted).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || rows[index - 1].group != item.group {
                                    Text(item.group).font(.app(size: 11, weight: .bold)).foregroundStyle(Rose.chipText)
                                        .padding(.leading, 16).padding(.top, index == 0 ? 8 : 12).padding(.bottom, 2)
                                }
                                Button { store.draft = item.name + " " } label: { row(item, typed: String(query.dropFirst())) }.buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    .frame(maxHeight: 264)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().tint(Rose.deep)
                    Text("명령을 읽는 중").font(.app(size: 13)).foregroundStyle(Rose.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }
        .background(Rose.panel)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Rose.border, lineWidth: 1))
        .shadow(color: Color(hex: 0x9A86D6).opacity(0.18), radius: 10, y: 4)
        .padding(.bottom, 4)
    }

    private func row(_ item: SlashItem, typed: String) -> some View {
        var name = AttributedString(item.name)
        if !typed.isEmpty, let range = name.range(of: typed, options: .caseInsensitive), range.lowerBound > name.startIndex {
            name[range].foregroundColor = Rose.deep
            name[range].font = .system(size: 14, weight: .bold, design: .monospaced)
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(Rose.text).lineLimit(1)
            if !item.description.isEmpty { Text(item.description).font(.app(size: 12.5)).foregroundStyle(Rose.muted).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
