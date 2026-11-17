import SwiftUI

/// The list of chats: one page per tab (every chat, the main bot, then each bot). A swipe sideways
/// moves to the next tab.
struct ChatListView: View {
    @Environment(Store.self) private var store
    let openMenu: () -> Void
    let showChat: () -> Void
    @State private var query = ""
    @State private var page = 0
    @State private var renaming: ChatRow?
    @State private var newName = ""
    @State private var deleting: ChatRow?

    var body: some View {
        let tabs = store.tabs
        VStack(spacing: 0) {
            header
            chips(tabs)
            SearchField(query: $query, hint: "대화 찾기").padding(.horizontal, 20).padding(.top, 12)
            NoticeBar().padding(.horizontal, 20).padding(.top, 8)
            TabView(selection: $page) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                    ChatPage(tab: tab, query: query, open: open, rename: { newName = $0.title ?? ""; renaming = $0 }, delete: { deleting = $0 }).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Rose.panel.ignoresSafeArea())
        .onAppear { page = max(0, tabs.firstIndex { $0 == store.tab } ?? 0) }
        .onChange(of: page) { _, now in if tabs.indices.contains(now) { store.tab = tabs[now] } }
        // The roster changed (a bot added, removed or reordered): the page follows the tab that was open,
        // or the full list when that bot is gone, so the page, its chip and store.tab never disagree.
        .onChange(of: tabs) { _, now in
            let index = now.firstIndex { $0 == store.tab } ?? 0
            if !now.indices.contains(index) || now[index] != store.tab { store.tab = now.first ?? Store.allTab }
            if page != index { page = index }
        }
        .alert("이름 변경", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("이름", text: $newName)
            Button("취소", role: .cancel) { renaming = nil }
            Button("바꾸기") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let row = renaming, !name.isEmpty { Task { await store.rename(row, to: String(name.prefix(120))) } }
                renaming = nil
            }
        }
        .confirmationDialog("이 대화를 지울까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("지우기", role: .destructive) {
                if let row = deleting { Task { await store.delete(row) } }
                deleting = nil
            }
            Button("취소", role: .cancel) { deleting = nil }
        } message: {
            Text("\"\(deleting?.shownTitle ?? "")\"\nHermes에서 완전히 지워져요. 다른 기기에서도 사라지고 되돌릴 수 없어요.")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image("HermesIcon").resizable().frame(width: 38, height: 38).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Hermes").font(.app(size: 22, weight: .medium, design: .serif)).italic().foregroundStyle(Rose.text)
                HStack(spacing: 6) {
                    StatusDot(color: store.link.color, blinking: store.link == .connecting)
                    Text(store.link.label).font(.app(size: 10.5, design: .monospaced)).foregroundStyle(Rose.muted)
                }
            }
            .padding(.leading, 4)
            Spacer()
            // The main action first; the menu sits at the edge, where menus are.
            RoundIcon(system: "plus", label: "새 대화", primary: true) {
                store.newChat(profile: store.tab == Store.allTab ? nil : store.tab)
                showChat()
            }
            RoundIcon(system: "arrow.clockwise", label: "목록 새로 고침", filled: true) {
                Task {
                    await store.refreshChats()
                    await store.refreshProfiles()
                }
            }
            RoundIcon(system: "line.3.horizontal", label: "메뉴", filled: true, action: openMenu)
        }
        .padding(.leading, 20).padding(.trailing, 14).padding(.top, 14)
    }

    private func chips(_ tabs: [String?]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        TabChip(label: label(tab), image: tab == Store.allTab ? nil : store.avatars[tab ?? store.own?.name ?? "default"],
                                picture: tab != Store.allTab, selected: page == index) {
                            withAnimation { page = index }
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 14)
            .onChange(of: page) { _, now in withAnimation { proxy.scrollTo(now, anchor: .center) } }
        }
    }

    private func label(_ tab: String?) -> String {
        if tab == Store.allTab { return "전체" }
        guard let tab else { return store.own.map { "@\($0.title)" } ?? "일반" }
        return "@" + (store.bots.first { $0.name == tab }?.title ?? tab)
    }

    private func open(_ row: ChatRow) {
        store.open(row)
        showChat()
    }
}

private struct TabChip: View {
    let label: String
    let image: UIImage?
    let picture: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if picture { BotAvatar(image: image, size: 40) }
                Text(label).font(.app(size: 14, weight: selected ? .bold : .regular)).foregroundStyle(selected ? Rose.chipText : Rose.text).lineLimit(1)
            }
            .padding(.leading, picture ? 5 : 16).padding(.trailing, picture ? 14 : 16).frame(minHeight: 50)
            .background(selected ? Rose.bubble : Rose.field).clipShape(Capsule())
            .overlay(Capsule().stroke(selected ? Rose.rose : Rose.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// One tab's chats.
private struct ChatPage: View {
    @Environment(Store.self) private var store
    let tab: String?
    let query: String
    let open: (ChatRow) -> Void
    let rename: (ChatRow) -> Void
    let delete: (ChatRow) -> Void

    var body: some View {
        let sections = store.sections(tab: tab, query: query)
        ScrollView {
            if sections.isEmpty {
                if store.chatsLoading { ProgressView().tint(Rose.deep).padding(.top, 40) }
                else { EmptyState(text: query.isEmpty ? "아직 대화가 없어요" : "찾는 대화가 없어요") }
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections, id: \.0) { title, rows in
                        SectionTitle(title: title, count: "\(rows.count)").padding(.leading, 10).padding(.top, 14).padding(.bottom, 2)
                        ForEach(rows, id: \.key) { row in
                            ChatRowView(row: row, image: store.avatar(for: row), tag: tab == Store.allTab ? kindTag(row) : nil, selected: store.openRow?.key == row.key)
                                .contentShape(RoundedRectangle(cornerRadius: 18))
                                .onTapGesture { open(row) }
                                .contextMenu {
                                    // A bot's standing chat is the bot itself; it is not renamed or removed from here.
                                    if row.kind != .bot {
                                        Button { rename(row) } label: { Label("이름 변경", systemImage: "pencil") }
                                        Button { Task { await store.pin(row, !row.pinned) } } label: {
                                            Label(row.pinned ? "고정 해제" : "맨 위에 고정", systemImage: row.pinned ? "pin.slash" : "pin")
                                        }
                                        Button { Task { await store.archive(row) } } label: { Label("보관", systemImage: "archivebox") }
                                        Button(role: .destructive) { delete(row) } label: { Label("삭제", systemImage: "trash") }
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 24)
            }
        }
        .refreshable { await store.refreshChats() }
    }

    private func kindTag(_ row: ChatRow) -> String? {
        switch row.kind {
        case .bot: "봇"
        case .messaging: platformLabel(row.source ?? "messaging")
        case .cron: "크론"
        case .chat: nil
        }
    }
}

private struct ChatRowView: View {
    let row: ChatRow
    let image: UIImage?
    let tag: String?
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            BotAvatar(image: image, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if row.pinned, row.kind != .bot { Image(systemName: "pin.fill").font(.app(size: 10)).foregroundStyle(Rose.rose) }
                    Text(row.shownTitle).font(.app(size: 15.5, weight: row.unread ? .bold : .medium)).foregroundStyle(Rose.text).lineLimit(1)
                    if let tag {
                        Text(tag).font(.app(size: 10.5)).foregroundStyle(Rose.chipText).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Rose.soft).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    // The dot blinks while an answer is being written, and until an answer that came is read.
                    if row.running || row.unread { StatusDot(color: row.running ? Rose.deep : Rose.rose, blinking: true) }
                }
                if let preview = row.preview { Text(preview).font(.app(size: 13)).foregroundStyle(Rose.muted).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let at = row.lastActiveAt { Text(ago(at)).font(.app(size: 10.5, design: .monospaced)).foregroundStyle(Rose.muted) }
        }
        .padding(.horizontal, 10).padding(.vertical, 11)
        .background(selected ? Rose.soft : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
