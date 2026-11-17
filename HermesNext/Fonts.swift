import CoreText
import SwiftUI
import UIKit

/// The font every screen uses: an iOS font or one imported from a file. Read before the first frame
/// (the app creates it in its `init`), so nothing is drawn in the default font first.
@MainActor
@Observable
final class Fonts {
    static let shared = Fonts()

    struct Imported: Identifiable, Hashable {
        let file: String
        let families: [String]
        var id: String { file }
    }

    /// The picked family; nil is the phone's own font.
    private(set) var family: String?
    private(set) var imported: [Imported] = []

    private let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("fonts")
    private static let key = "font_family"

    private init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        imported = files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap(register)
        // A family whose file is gone is not kept: the screens would fall back one face at a time.
        family = UserDefaults.standard.string(forKey: Fonts.key).flatMap { UIFont.fontNames(forFamilyName: $0).isEmpty ? nil : $0 }
        applyToBars()
    }

    /// The fonts iOS itself has, by family.
    var systemFamilies: [String] { UIFont.familyNames.sorted() }

    func pick(_ family: String?) {
        self.family = family
        UserDefaults.standard.set(family, forKey: Fonts.key)
        applyToBars()
    }

    /// What one import did, for the line the font screen shows.
    struct Outcome { var added: [String] = []; var skipped: [String] = [] }

    /// Copies font files into the app and makes them usable. A file is read whole and checked before it
    /// is kept, so a copy that is not a font never stays behind.
    func add(_ urls: [URL]) -> Outcome {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var outcome = Outcome()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url),
                  let faces = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], !faces.isEmpty else {
                outcome.skipped.append(name)
                continue
            }
            let target = dir.appendingPathComponent(name)
            // The same file again replaces the copy that is there.
            if let old = imported.first(where: { $0.file == name }) { remove(old) }
            try? FileManager.default.removeItem(at: target)
            guard (try? data.write(to: target, options: .atomic)) != nil, let font = register(target) else {
                try? FileManager.default.removeItem(at: target)
                outcome.skipped.append(name)
                continue
            }
            imported.append(font)
            outcome.added += font.families
        }
        return outcome
    }

    func remove(_ font: Imported) {
        let url = dir.appendingPathComponent(font.file)
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
        try? FileManager.default.removeItem(at: url)
        imported.removeAll { $0.file == font.file }
        if let family, font.families.contains(family) { pick(nil) }
    }

    private func register(_ url: URL) -> Imported? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty else { return nil }
        // Already registered (the same file again) is not a failure.
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        var seen = Set<String>()
        let families = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }.filter { seen.insert($0).inserted }
        return families.isEmpty ? nil : Imported(file: url.lastPathComponent, families: families)
    }

    func uiFont(size: CGFloat, bold: Bool = false) -> UIFont {
        guard let family else { return .systemFont(ofSize: size, weight: bold ? .semibold : .regular) }
        var descriptor = UIFontDescriptor(fontAttributes: [.family: family])
        if bold, let heavier = descriptor.withSymbolicTraits(.traitBold) { descriptor = heavier }
        return UIFont(descriptor: descriptor, size: size)
    }

    /// Navigation bar titles and buttons are UIKit text, out of SwiftUI's reach.
    private func applyToBars() {
        let title: [NSAttributedString.Key: Any] = [.font: uiFont(size: 17, bold: true), .foregroundColor: UIColor(Rose.text)]
        UINavigationBar.appearance().titleTextAttributes = title
        for state in [UIControl.State.normal, .highlighted, .disabled] {
            UIBarButtonItem.appearance().setTitleTextAttributes([.font: uiFont(size: 17)], for: state)
        }
    }
}

extension Font {
    /// The app's text style: the picked family when there is one. Code stays monospaced.
    @MainActor
    static func app(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        guard design != .monospaced, let family = Fonts.shared.family else { return .system(size: size, weight: weight, design: design) }
        return .custom(family, size: size).weight(weight)
    }
}
