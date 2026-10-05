import AppKit
import UniformTypeIdentifiers

@MainActor
enum Clipboard {
    /// Puts the image on the general pasteboard as PNG, like the system
    /// screenshot shortcut does.
    static func copy(_ image: PixelImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(image.pngData(level: 4), forType: .png)
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The image currently on the pasteboard, if there is one.
    static func image() -> PixelImage? {
        let pasteboard = NSPasteboard.general
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL])?.first {
            return ImageFile.load(url)
        }
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        return ImageFile.pixelImage(from: image)
    }
}

@MainActor
enum ImageFile {
    static func load(_ url: URL) -> PixelImage? {
        NSImage(contentsOf: url).flatMap(pixelImage(from:))
    }

    static func pixelImage(from image: NSImage) -> PixelImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil), image.size.width > 0 else {
            return nil
        }
        // A 144 dpi file is a Retina capture: keep showing it at half size.
        let ratio = CGFloat(cgImage.width) / image.size.width
        return PixelImage(cgImage: cgImage, scale: ratio >= 1.5 ? 2 : 1)
    }

    nonisolated static func defaultName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Snipster \(formatter.string(from: date)).png"
    }

    /// Writes a PNG into `folder`, never overwriting an existing file.
    @discardableResult
    static func save(_ image: PixelImage, in folder: URL, name: String = defaultName()) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(counter)).png")
            counter += 1
        }
        try image.pngData(level: 6).write(to: url, options: .atomic)
        return url
    }
}

/// What happens to a finished capture, according to the user's settings.
@MainActor
enum CaptureOutput {
    /// `decorating` is true for captures a window frame or backdrop makes
    /// sense for (areas and windows, not whole screens).
    static func deliver(_ image: PixelImage, decorating: Bool = false) {
        let settings = Settings.shared
        let style = settings.decoration
        let decorated = decorating && settings.decorateNewCaptures && !style.isEmpty
        // The clipboard and the saved file get what the editor is about to show.
        let output = decorated ? DecorationRenderer().render(style, around: image) : image
        if settings.copyAfterCapture {
            Clipboard.copy(output)
        }
        var savedURL: URL?
        if settings.saveAfterCapture {
            do {
                savedURL = try ImageFile.save(output, in: settings.saveFolder)
            } catch {
                Toast.show("Couldn't save: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
        }
        if settings.openEditorAfterCapture {
            EditorWindowController.open(image, fileURL: savedURL, decorated: decorated)
        } else if let savedURL {
            Toast.show("Saved \(savedURL.lastPathComponent)")
        } else if settings.copyAfterCapture {
            Toast.show("Copied to clipboard")
        } else {
            // Nothing else is configured to receive it; don't lose the capture.
            EditorWindowController.open(image, fileURL: nil)
        }
    }
}
