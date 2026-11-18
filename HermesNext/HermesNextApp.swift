import SwiftUI
import WebKit

@main
struct HermesNextApp: App {
    @State private var store: Store
    @Environment(\.scenePhase) private var phase

    init() {
        // Fonts first: the picked one is registered before the first frame is drawn.
        _ = Fonts.shared
        _store = State(initialValue: Store())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.light)
                .tint(Rose.deep)
                .font(.app(size: 17))
                // Only a real trip to the background counts: the app switcher or Control Center is "inactive".
                .onChange(of: phase, initial: true) { _, now in
                    if now == .active { store.setActive(true) } else if now == .background { store.setActive(false) }
                }
        }
    }
}

/// The server address and sign-in until both are there; then the chats.
struct RootView: View {
    @Environment(Store.self) private var store
    @State private var signingIn = false

    var body: some View {
        Group {
            if !store.hasServer || store.link == .signedOut || store.link == .unsupported {
                SetupView(signingIn: $signingIn)
            } else {
                MainView()
            }
        }
        .background(Rose.panel.ignoresSafeArea())
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

struct SetupView: View {
    @Environment(Store.self) private var store
    @Binding var signingIn: Bool
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Image("HermesIcon").resizable().frame(width: 64, height: 64).clipShape(Circle()).overlay(Circle().stroke(Rose.petal, lineWidth: 1.5))
            Text("Hermes Next").font(.app(size: 28, weight: .bold, design: .serif)).foregroundStyle(Rose.text)
            Text(message).font(.app(size: 15)).foregroundStyle(Rose.muted)
            TextField("", text: $address, prompt: Text("https://hermes.example.com").foregroundStyle(Rose.muted))
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.app(size: 16)).foregroundStyle(Rose.text)
                .padding(.horizontal, 16).frame(minHeight: 52)
                .background(Rose.field).clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Rose.border, lineWidth: 1))
            HStack(spacing: 8) {
                PillButton(label: "연결", filled: true) {
                    let url = address.contains("://") ? address : "https://" + address
                    if Endpoint(url) != nil { store.setServer(url) }
                }
                if store.hasServer, store.link == .signedOut { PillButton(label: "로그인") { signingIn = true } }
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .onAppear { address = store.serverURL }
    }

    private var message: String {
        if !store.hasServer { return "Hermes Webapp 서버 주소를 적어 주세요." }
        switch store.link {
        case .signedOut: return "로그인이 필요해요. 로그인을 누르면 서버의 로그인 화면이 열려요."
        case .unsupported: return "이 주소는 Hermes Webapp 서버가 아니에요. 주소를 확인해 주세요."
        default: return "연결하는 중이에요."
        }
    }
}

/// The server's own sign-in page. Its cookies are copied to the store the app's requests use.
struct SignInSheet: View {
    let url: URL
    let done: () -> Void

    var body: some View {
        NavigationStack {
            SignInWeb(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("로그인")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("완료") {
                            Task {
                                await SignInWeb.copyCookies()
                                done()
                            }
                        }
                    }
                }
        }
    }
}

struct SignInWeb: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        // The page gets the app's newest cookies first: an older copy would replay a spent sign-in token.
        let store = view.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) { view.load(URLRequest(url: url)) }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { await SignInWeb.copyCookies() }
        }
    }

    /// The page's cookies, as the app's own requests and the socket send them.
    @MainActor
    static func copyCookies() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
        if let any = cookies.first, let url = URL(string: "https://\(any.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))") { CookieVault.save(url) }
    }
}

/// The chats beside the conversation on an iPad. On an iPhone the conversation lies over the list, so a swipe
/// back shows the list underneath as the conversation slides away.
struct MainView: View {
    @Environment(Store.self) private var store
    @Environment(\.horizontalSizeClass) private var size
    @State private var visibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var chatShown = false
    @State private var menu = false

    var body: some View {
        Group {
            if size == .compact {
                ZStack {
                    ChatListView(openMenu: { menu = true }, showChat: { withAnimation(.snappy(duration: 0.28)) { chatShown = true } })
                    if chatShown {
                        ConversationView(back: { slide in
                            if slide {
                                withAnimation(.snappy(duration: 0.28)) { chatShown = false }
                            } else {
                                var instant = Transaction()
                                instant.disablesAnimations = true
                                withTransaction(instant) { chatShown = false }
                            }
                        })
                            .shadow(color: .black.opacity(0.12), radius: 12, x: -4)
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                    }
                }
            } else {
                NavigationSplitView(columnVisibility: $visibility) {
                    ChatListView(openMenu: { menu = true }, showChat: {})
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
                } detail: {
                    ConversationView(back: { _ in })
                        .toolbar(.hidden, for: .navigationBar)
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .sheet(isPresented: $menu) { MenuView() }
        .overlay { CallOverlay() }
        .onChange(of: VoiceCenter.shared.mode) { _, mode in
            if mode == .full { menu = false }
        }
    }
}
