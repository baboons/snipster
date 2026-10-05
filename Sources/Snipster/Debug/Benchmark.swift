import AppKit

/// `Snipster --bench [output.png]`: times each stage of a capture on this
/// machine. Needs the Screen Recording permission for whatever launched it.
@MainActor
enum Benchmark {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--bench") else { return false }
        Task {
            do {
                try await measure()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("bench failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        return true
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1e3 + Double(elapsed.components.attoseconds) / 1e15
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> String {
        String(format: "%7.2f ms", elapsed(since: start))
    }

    private static func measure() async throws {
        guard ScreenCapturer.hasPermission else { throw CaptureError.permissionDenied }
        let capturer = ScreenCapturer.shared

        var start = ContinuousClock.now
        var frames = try await capturer.captureDisplays()
        print("cold capture (content lookup + grab)  \(milliseconds(since: start))")

        // What a hotkey press waits for: the display under the pointer.
        let mouse = NSEvent.mouseLocation
        let pointerDisplay = NSScreen.screens.first { $0.frame.contains(mouse) }?.displayID
        var first: [Double] = []
        var all: [Double] = []
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(150))
            start = ContinuousClock.now
            let began = start
            var firstFrame: Double?
            frames = []
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                capturer.captureDisplays(startingWith: pointerDisplay, onFrame: { frame in
                    frames.append(frame)
                    if firstFrame == nil { firstFrame = elapsed(since: began) }
                }, completion: { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
            first.append(firstFrame ?? 0)
            all.append(elapsed(since: began))
        }
        first.sort()
        all.sort()
        print(String(format: "warm capture, pointer's display       %7.2f ms median (best %.2f)", first[first.count / 2], first[0]))
        print(String(format: "warm capture, all %d displays          %7.2f ms median (best %.2f)", frames.count, all[all.count / 2], all[0]))
        for frame in frames {
            print("  display \(frame.displayID): \(frame.width)x\(frame.height) px @\(frame.scale)x")
        }

        guard let frame = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return }
        let region = PixelRect(x: frame.width / 4, y: frame.height / 4,
                               width: min(1600, frame.width / 2), height: min(1000, frame.height / 2))
        start = ContinuousClock.now
        let crop = frame.image(cropping: region)!
        print("crop \(region.width)x\(region.height)                        \(milliseconds(since: start))")
        start = ContinuousClock.now
        let cropPNG = crop.pngData(level: 4)
        print("  encode PNG (\(cropPNG.count / 1024) KB)                 \(milliseconds(since: start))")

        start = ContinuousClock.now
        let full = frame.image(cropping: frame.pixelBounds)!
        print("copy full display \(frame.width)x\(frame.height)          \(milliseconds(since: start))")
        start = ContinuousClock.now
        let fullPNG = full.pngData(level: 6)
        print("  encode PNG (\(fullPNG.count / 1024) KB)                \(milliseconds(since: start))")

        start = ContinuousClock.now
        _ = full.redacted(region, effect: .blur(radius: 16))
        print("blur \(region.width)x\(region.height)                        \(milliseconds(since: start))")
        start = ContinuousClock.now
        _ = full.redacted(region, effect: .pixelate(block: 16))
        print("pixelate \(region.width)x\(region.height)                    \(milliseconds(since: start))")

        if let path = CommandLine.arguments.drop(while: { $0 != "--bench" }).dropFirst().first {
            try fullPNG.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
    }
}
