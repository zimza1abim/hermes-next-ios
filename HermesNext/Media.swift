import Photos
import SwiftUI
import UIKit

/// Images inside a message's text, in the four forms the server and the bot write them:
/// `@image:<path>` lines (photos the user sent), `MEDIA:<path>` tokens (files the bot delivers),
/// Markdown `![alt](src)`, and inline `data:image/...;base64,...` text.
enum Media {
    struct Extraction: Equatable {
        var text: String
        var sources: [String]
    }

    private static let imageLine = try! NSRegularExpression(pattern: "^[ \\t]*@image:[ \\t]*(.+?)[ \\t]*$", options: .anchorsMatchLines)
    private static let markdownImage = try! NSRegularExpression(pattern: "!\\[[^\\]\\n]*\\]\\(\\s*<?([^)\\s>]+)>?(?:\\s+\"[^\"]*\")?\\s*\\)")
    private static let mediaToken = try! NSRegularExpression(pattern: "MEDIA:(\\S+?)(?=[.,;:!?)\\]]*(?:\\s|$))")
    private static let dataURL = try! NSRegularExpression(pattern: "data:image/[\\w.+-]+;base64,[A-Za-z0-9+/=]{64,}")
    private static let placeholder = try! NSRegularExpression(pattern: "^[ \\t]*\\[(?:image|screenshot)\\][ \\t]*$\\n?", options: .anchorsMatchLines)
    private static let blankRun = try! NSRegularExpression(pattern: "\\n{3,}")
    static let imageSuffixes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp"]

    private static var cache: [String: Extraction] = [:]

    /// The text with its images taken out, and the images in the order they appeared.
    static func extract(_ text: String) -> Extraction {
        guard text.contains("@image:") || text.contains("![") || text.contains("MEDIA:") || text.contains("data:image/") else {
            return Extraction(text: text, sources: [])
        }
        if let known = cache[text] { return known }
        var found: [(NSRange, String)] = []
        let whole = NSRange(text.startIndex..., in: text)
        func collect(_ regex: NSRegularExpression, group: Int, keep: (String) -> Bool = { _ in true }) {
            for match in regex.matches(in: text, range: whole) {
                // An image inside one already taken (a data URL inside a Markdown image) is not taken twice.
                guard !found.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }),
                      let range = Range(match.range(at: group), in: text) else { continue }
                let source = clean(String(text[range]))
                if !source.isEmpty, keep(source) { found.append((match.range, source)) }
            }
        }
        collect(markdownImage, group: 1)
        collect(imageLine, group: 1)
        collect(mediaToken, group: 1) { isImagePath($0) }
        collect(dataURL, group: 0)
        guard !found.isEmpty else { return Extraction(text: text, sources: []) }
        found.sort { $0.0.location < $1.0.location }
        let mutable = NSMutableString(string: text)
        for (range, _) in found.reversed() { mutable.replaceCharacters(in: range, with: "") }
        var rest = placeholder.stringByReplacingMatches(in: mutable as String, range: NSRange(location: 0, length: mutable.length), withTemplate: "")
        rest = blankRun.stringByReplacingMatches(in: rest, range: NSRange(rest.startIndex..., in: rest), withTemplate: "\n\n")
        var seen = Set<String>()
        let result = Extraction(text: rest.trimmingCharacters(in: .whitespacesAndNewlines), sources: found.map(\.1).filter { seen.insert($0).inserted })
        if cache.count > 300 { cache.removeAll() }
        cache[text] = result
        return result
    }

    /// A path or address without the quotes or backticks a directive may wrap it in.
    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`<>"))
    }

    static func isImagePath(_ path: String) -> Bool {
        let bare = path.split(separator: "?").first.map(String.init) ?? path
        return imageSuffixes.contains((bare as NSString).pathExtension.lowercased())
    }

    /// The image bytes of a `data:` URL.
    static func decodeDataURL(_ url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]), options: .ignoreUnknownCharacters)
    }

    /// A picture at most `side` points on its longer side, so a large photo does not hold its full size in memory.
    static func picture(_ data: Data, side: CGFloat = 1600) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let longer = max(image.size.width, image.size.height)
        guard longer > side else { return image }
        let scale = side / longer
        return image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
    }
}

/// The images of one message, as thumbnails; a tap opens one full screen.
struct MediaStrip: View {
    let sources: [String]
    var trailing = false
    @State private var viewing: String?

    var body: some View {
        let columns = sources.count == 1 ? 1 : 2
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), alignment: trailing ? .trailing : .leading, spacing: 6) {
            ForEach(sources, id: \.self) { source in
                MediaThumb(source: source, single: sources.count == 1) { viewing = source }
            }
        }
        .frame(maxWidth: sources.count == 1 ? 300 : 360, alignment: trailing ? .trailing : .leading)
        .fullScreenCover(item: Binding(get: { viewing.map(Viewing.init) }, set: { viewing = $0?.source })) { MediaViewer(source: $0.source) }
    }

    private struct Viewing: Identifiable {
        let source: String
        var id: String { source }
    }
}

private struct MediaThumb: View {
    @Environment(Store.self) private var store
    let source: String
    let single: Bool
    let open: () -> Void
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rose.soft
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: single ? .fit : .fill)
            } else if failed {
                VStack(spacing: 4) {
                    Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(Rose.muted)
                    Text("이미지를 불러오지 못했어요").font(.app(size: 11)).foregroundStyle(Rose.muted)
                }
                .padding(8)
            } else {
                ProgressView().tint(Rose.deep)
            }
        }
        .frame(minHeight: single ? nil : 140, maxHeight: single ? 360 : 140)
        .frame(height: image == nil ? 140 : nil)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Rose.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { if image != nil { open() } else if failed { failed = false; Task { await load() } } }
        .task(id: source) { await load() }
    }

    private func load() async {
        image = await store.image(source)
        failed = image == nil
    }
}

/// One image over the whole screen: pinch to zoom, double-tap to fit, drag down or tap the button to close.
private struct MediaViewer: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let source: String
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var settled: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var moved: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(scale).offset(offset)
                    .gesture(MagnifyGesture().onChanged { scale = max(1, settled * $0.magnification) }.onEnded { _ in settled = scale })
                    .simultaneousGesture(DragGesture().onChanged { drag in
                        offset = CGSize(width: moved.width + drag.translation.width, height: moved.height + drag.translation.height)
                    }.onEnded { drag in
                        // A drag down on an image that is not zoomed closes the viewer.
                        if settled == 1, drag.translation.height > 120 { dismiss(); return }
                        if settled == 1 { withAnimation(.spring) { offset = .zero } }
                        moved = offset
                    })
                    .onTapGesture(count: 2) {
                        withAnimation(.spring) {
                            scale = scale > 1 ? 1 : 2.5
                            settled = scale
                            offset = .zero
                            moved = .zero
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                if image != nil {
                    Button { Task { await save() } } label: {
                        Image(systemName: saved == true ? "checkmark" : "arrow.down.to.line").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(.white.opacity(0.15)).clipShape(Circle())
                    }
                    .disabled(saving || saved == true)
                    .accessibilityLabel("사진에 저장")
                }
                if let image {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("이미지", image: Image(uiImage: image))) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(.white.opacity(0.15)).clipShape(Circle())
                    }
                    .accessibilityLabel("공유")
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(.white.opacity(0.15)).clipShape(Circle())
                }
                .accessibilityLabel("닫기")
            }
            .padding(16)
            if let note {
                Text(note).font(.app(size: 14, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10).background(.white.opacity(0.18)).clipShape(Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 40)
                    .task(id: note) {
                        try? await Task.sleep(for: .seconds(2))
                        self.note = nil
                    }
            }
        }
        .task { image = await store.image(source) }
    }

    @State private var saving = false
    @State private var saved: Bool?
    @State private var note: String?

    /// Saves the image to Photos at the size the server keeps it, in its own format; the shown copy may be smaller.
    private func save() async {
        saving = true
        defer { saving = false }
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized || PHPhotoLibrary.authorizationStatus(for: .addOnly) == .limited else {
            note = "사진 접근이 꺼져 있어요. 설정에서 사진 추가를 허용해 주세요"
            return
        }
        let data = await store.imageBytes(source)
        let shown = image
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if let data, UIImage(data: data) != nil {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                } else if let shown {
                    PHAssetChangeRequest.creationRequestForAsset(from: shown)
                }
            }
            saved = true
            note = "사진에 저장했어요"
        } catch {
            note = "저장하지 못했어요"
        }
    }
}
