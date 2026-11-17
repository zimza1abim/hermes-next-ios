import SwiftUI
import UniformTypeIdentifiers

/// The menu: cron jobs, what the bot can use, installing, archived chats and the server.
struct MenuView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle(title: "Hermes").padding(.leading, 12).padding(.top, 6).padding(.bottom, 4)
                    NavigationLink { CronPane() } label: { MenuRow(icon: "clock", title: "크론 작업", detail: "예약 작업을 보고, 멈추고, 바로 실행해요") }
                    NavigationLink { CapabilitiesPane() } label: { MenuRow(icon: "puzzlepiece.extension", title: "스킬 · 도구 · MCP", detail: "\(botLabel)에 켜져 있는 것들") }
                    NavigationLink { InstallPane() } label: { MenuRow(icon: "arrow.down.circle", title: "플러그인 · MCP 설치", detail: "Hermes 카탈로그에서 골라 설치해요") }
                    NavigationLink { ArchivePane() } label: { MenuRow(icon: "archivebox", title: "보관한 대화", detail: "보관한 대화를 보고 다시 꺼내요") }
                    SectionTitle(title: "앱").padding(.leading, 12).padding(.top, 16).padding(.bottom, 4)
                    NavigationLink { FontPane() } label: { MenuRow(icon: "textformat", title: "글꼴", detail: Fonts.shared.family ?? "휴대폰 기본 글꼴") }
                    NavigationLink { ServerPane() } label: { MenuRow(icon: "server.rack", title: "서버", detail: store.serverURL) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(Rose.panel.ignoresSafeArea())
            .navigationTitle("메뉴").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
        }
        .preferredColorScheme(.light)
        .tint(Rose.deep)
    }

    private var botLabel: String {
        let tab = store.tab == Store.allTab ? nil : store.tab
        return "@" + (store.profiles.first { tab == nil ? $0.own : $0.name == tab }?.title ?? tab ?? "메인 봇")
    }
}

private struct MenuRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.app(size: 17)).foregroundStyle(Rose.deep).frame(width: 40, height: 40).background(Rose.soft).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.app(size: 16, weight: .medium)).foregroundStyle(Rose.text)
                Text(detail).font(.app(size: 13)).foregroundStyle(Rose.muted).lineLimit(2).multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.app(size: 13, weight: .semibold)).foregroundStyle(Rose.muted)
        }
        .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 64).contentShape(Rectangle())
    }
}

/// The frame every menu screen shares: the rose ground, the notice line and a refresh button.
private struct Pane<Content: View>: View {
    @Environment(Store.self) private var store
    let title: String
    let refresh: () async -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                NoticeBar()
                content()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .background(Rose.panel.ignoresSafeArea())
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if store.menuLoading { ProgressView().tint(Rose.deep) }
                else { Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("새로 고침") }
            }
        }
        .refreshable { await refresh() }
        .task { await refresh() }
    }
}

private struct CronPane: View {
    @Environment(Store.self) private var store

    var body: some View {
        Pane(title: "크론 작업", refresh: store.refreshCron) {
            if store.cron.isEmpty, !store.menuLoading { EmptyState(text: "예약된 작업이 없어요") }
            ForEach(store.cron) { job in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Circle().fill(job.paused ? Rose.border : Rose.online).frame(width: 8, height: 8)
                        Text(job.name).font(.app(size: 15.5, weight: .medium)).foregroundStyle(Rose.text).lineLimit(2)
                    }
                    let facts = [job.profile.map { "@\($0)" }, job.schedule, job.paused ? nil : job.nextRun.map { "다음 \(shortTime($0))" },
                                 job.lastStatus.map { "지난 실행 \($0)" }, job.paused ? "멈춤" : nil].compactMap { $0 }
                    if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.app(size: 13)).foregroundStyle(Rose.muted) }
                    HStack(spacing: 8) {
                        PillButton(label: "지금 실행", filled: true) { Task { await store.cronAct(job, "trigger", done: "실행을 요청했어요") } }
                        PillButton(label: job.paused ? "다시 켜기" : "멈추기") {
                            Task { await store.cronAct(job, job.paused ? "resume" : "pause", done: job.paused ? "작업을 다시 켰어요" : "작업을 멈췄어요") }
                        }
                    }
                }
                .roseCard()
            }
        }
    }

    /// `2026-11-16T09:00:00+09:00` as `11-16 09:00`.
    private func shortTime(_ iso: String) -> String {
        guard iso.count >= 16 else { return iso }
        let start = iso.index(iso.startIndex, offsetBy: 5)
        return String(iso[start..<iso.index(iso.startIndex, offsetBy: 16)]).replacingOccurrences(of: "T", with: " ")
    }
}

private struct CapabilitiesPane: View {
    @Environment(Store.self) private var store
    @State private var query = ""

    var body: some View {
        Pane(title: "스킬 · 도구 · MCP", refresh: store.refreshCapabilities) {
            SearchField(query: $query, hint: "이름이나 설명으로 찾기")
            section("도구 모음", store.toolsets)
            section("MCP 서버", store.mcp)
            section("스킬", store.skills)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ all: [Capability]) -> some View {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let rows = needle.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(needle) || ($0.detail ?? "").localizedCaseInsensitiveContains(needle) }
        SectionTitle(title: title, count: rows.isEmpty ? nil : "\(rows.filter(\.enabled).count) / \(rows.count) 켜짐").padding(.top, 8)
        if rows.isEmpty { Text(needle.isEmpty ? "없어요" : "찾는 것이 없어요").font(.app(size: 13)).foregroundStyle(Rose.muted) }
        ForEach(rows) { row in
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(row.enabled ? Rose.online : Rose.border).frame(width: 8, height: 8).padding(.top, 7)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(row.name).font(.app(size: 15)).foregroundStyle(row.enabled ? Rose.text : Rose.muted).lineLimit(1)
                        if let note = row.note { Text(note).font(.app(size: 10.5, design: .monospaced)).foregroundStyle(Rose.muted) }
                    }
                    if let detail = row.detail { Text(detail).font(.app(size: 13)).foregroundStyle(Rose.muted).lineLimit(2) }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct InstallPane: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    @State private var asking: Installable?

    var body: some View {
        Pane(title: "플러그인 · MCP 설치", refresh: store.refreshCatalogs) {
            SearchField(query: $query, hint: "플러그인, MCP 서버 찾기")
            catalog("플러그인", store.plugins)
            catalog("MCP 서버", store.mcpCatalog)
        }
        // A plugin is code that will run on the Hermes machine, so installing one is confirmed first.
        .confirmationDialog(asking.map { "\($0.title) 설치" } ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible) {
            Button("설치") {
                if let item = asking { Task { await store.install(item) } }
                asking = nil
            }
            Button("취소", role: .cancel) { asking = nil }
        } message: {
            Text((asking?.plugin == true ? "Hermes가 돌아가는 컴퓨터에 이 플러그인의 코드를 설치하고 켜요." : "이 MCP 서버를 Hermes 설정에 추가하고 켜요.") + (asking?.source.map { "\n\n\($0)" } ?? ""))
        }
    }

    @ViewBuilder
    private func catalog(_ title: String, _ all: [Installable]) -> some View {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let rows = needle.isEmpty ? all : all.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.name.localizedCaseInsensitiveContains(needle)
                || ($0.detail ?? "").localizedCaseInsensitiveContains(needle) || ($0.source ?? "").localizedCaseInsensitiveContains(needle)
        }
        SectionTitle(title: title, count: rows.isEmpty ? nil : "\(rows.filter(\.installed).count) / \(rows.count) 설치됨").padding(.top, 8)
        if rows.isEmpty { Text(needle.isEmpty ? "카탈로그가 비어 있어요" : "찾는 것이 없어요").font(.app(size: 13)).foregroundStyle(Rose.muted) }
        ForEach(rows) { item in
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.app(size: 15.5, weight: .medium)).foregroundStyle(Rose.text).lineLimit(1)
                if let detail = item.detail { Text(detail).font(.app(size: 13)).foregroundStyle(Rose.muted).lineLimit(4) }
                if let source = item.source { Text(source).font(.app(size: 10.5, design: .monospaced)).foregroundStyle(Rose.muted).lineLimit(1) }
                if item.installed { Text("설치됨").font(.app(size: 13)).foregroundStyle(Rose.online) }
                else if store.installing.contains(item.id) { Text("설치하는 중…").font(.app(size: 13)).foregroundStyle(Rose.muted) }
                else if let blocked = item.blocked { Text("\(blocked). Webapp에서 설치해 주세요").font(.app(size: 13)).foregroundStyle(Rose.muted) }
                else { PillButton(label: "설치", filled: true) { asking = item }.padding(.top, 4) }
            }
            .roseCard()
        }
    }
}

private struct ArchivePane: View {
    @Environment(Store.self) private var store

    var body: some View {
        Pane(title: "보관한 대화", refresh: store.refreshArchived) {
            if store.archived.isEmpty, !store.menuLoading { EmptyState(text: "보관한 대화가 없어요") }
            ForEach(store.archived, id: \.key) { row in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.shownTitle).font(.app(size: 15.5, weight: .medium)).foregroundStyle(Rose.text).lineLimit(1)
                        Text([row.profile.map { "@\($0)" }, row.lastActiveAt.map { ago($0) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.app(size: 13)).foregroundStyle(Rose.muted)
                    }
                    Spacer()
                    PillButton(label: "꺼내기") { Task { await store.unarchive(row) } }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

private struct ServerPane: View {
    @Environment(Store.self) private var store
    @State private var address = ""
    @State private var signingIn = false

    var body: some View {
        Pane(title: "서버", refresh: {}) {
            SectionTitle(title: "주소")
            TextField("", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.app(size: 15)).foregroundStyle(Rose.text).padding(.horizontal, 14).frame(minHeight: 48)
                .background(Rose.field).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Rose.border, lineWidth: 1))
            HStack(spacing: 8) {
                PillButton(label: "저장하고 연결", filled: true) { if Endpoint(address) != nil { store.setServer(address) } }
                PillButton(label: "로그인 화면") { signingIn = true }
            }
            HStack(spacing: 6) {
                StatusDot(color: store.link.color)
                Text(store.link.label).font(.app(size: 10.5, design: .monospaced)).foregroundStyle(Rose.muted)
            }
            .padding(.top, 6)
        }
        .onAppear { address = store.serverURL }
        .sheet(isPresented: $signingIn) {
            if let url = store.pageURL {
                SignInSheet(url: url) {
                    signingIn = false
                    store.reconnect()
                }
            }
        }
    }
}

/// The fonts: the phone's own, the ones imported from files, and every font iOS has. Each name is drawn
/// in its own font; picking one changes every screen at once.
private struct FontPane: View {
    @Environment(Store.self) private var store
    @State private var importing = false
    @State private var query = ""
    @State private var result: String?
    private let fonts = Fonts.shared

    var body: some View {
        Pane(title: "글꼴", refresh: {}) {
            PillButton(label: "파일에서 글꼴 추가", filled: true) { importing = true }
            Text("TTF, OTF, TTC 파일을 고르면 앱 안에 복사해서 써요.").font(.app(size: 13)).foregroundStyle(Rose.muted)
            FontRow(family: nil, picked: fonts.family == nil) { fonts.pick(nil) }
            if !fonts.imported.isEmpty {
                SectionTitle(title: "가져온 글꼴", count: "\(fonts.imported.count)").padding(.top, 10)
                ForEach(fonts.imported) { file in
                    ForEach(file.families, id: \.self) { family in
                        FontRow(family: family, picked: fonts.family == family, detail: file.file) { fonts.pick(family) }
                            .contextMenu {
                                Button(role: .destructive) { fonts.remove(file) } label: { Label("글꼴 지우기", systemImage: "trash") }
                            }
                    }
                }
            }
            SectionTitle(title: "iOS 글꼴", count: "\(fonts.systemFamilies.count)").padding(.top, 10)
            SearchField(query: $query, hint: "글꼴 이름 찾기")
            let needle = query.trimmingCharacters(in: .whitespaces)
            LazyVStack(spacing: 0) {
                ForEach(fonts.systemFamilies.filter { needle.isEmpty || $0.localizedCaseInsensitiveContains(needle) }, id: \.self) { family in
                    FontRow(family: family, picked: fonts.family == family) { fonts.pick(family) }
                }
            }
        }
        // UIKit's picker, copying the files into the app: SwiftUI's file importer hands over a link to the
        // file that some hosts (LiveContainer) never deliver, so the tap on Open did nothing.
        .sheet(isPresented: $importing) {
            FontFilePicker { urls in
                importing = false
                guard !urls.isEmpty else { return }
                let outcome = fonts.add(urls)
                // The first new family is picked at once: that is why it was added.
                if let first = outcome.added.first { fonts.pick(first) }
                result = outcome.added.isEmpty
                    ? "읽을 수 있는 글꼴이 없어요" + (outcome.skipped.isEmpty ? "" : "\n" + outcome.skipped.joined(separator: ", "))
                    : "추가하고 적용했어요: " + outcome.added.joined(separator: ", ")
            }
            .ignoresSafeArea()
        }
        .alert(result ?? "", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("확인", role: .cancel) { result = nil }
        }
    }
}

private struct FontRow: View {
    let family: String?
    let picked: Bool
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(family ?? "휴대폰 기본 글꼴").font(face(17)).foregroundStyle(Rose.text).lineLimit(1)
                    // Hangul in the sample shows whether the font covers it.
                    Text(family == nil ? "iOS 시스템 글꼴을 따라요" : "가나다라 마바사 Hermes 123").font(face(13)).foregroundStyle(Rose.muted).lineLimit(1)
                    if let detail { Text(detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Rose.muted).lineLimit(1) }
                }
                Spacer()
                if picked { Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Rose.deep) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(picked ? Rose.bubble : Color.clear).clipShape(RoundedRectangle(cornerRadius: 18))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func face(_ size: CGFloat) -> Font { family.map { .custom($0, size: size) } ?? .system(size: size) }
}

/// The document picker for font files. `asCopy` puts each file in the app's own inbox, readable without
/// asking the file's owner again.
private struct FontFilePicker: UIViewControllerRepresentable {
    let done: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = [UTType.font] + ["public.truetype-ttf-font", "public.opentype-font", "public.truetype-collection-font", "org.w3.woff"].compactMap(UTType.init)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: ([URL]) -> Void
        init(done: @escaping ([URL]) -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done([]) }
    }
}
