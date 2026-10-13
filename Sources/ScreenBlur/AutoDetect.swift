import AppKit
import ScreenCaptureKit
import Vision

// MARK: - Auto-detect (screen capture + OCR, needs Screen Recording permission)

/// Repeatedly screenshots every display, OCRs it, and reports the screen rects of
/// text that looks sensitive. Our own windows are excluded from the capture so the
/// blur never hides the text from the detector.
final class AutoDetector: @unchecked Sendable {
    // A pattern with a capture group blurs only group 1; otherwise the whole match.
    private static let builtIn = [
        #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,                                  // email
        #"\+\d[\d\s().-]{7,16}\d"#,                                                 // international phone
        #"\b\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{4}\b"#,                                   // card number
        #"\b(?:sk|pk|rk)[-_][A-Z0-9_-]{16,}"#,                                      // API keys
        #"\bAKIA[0-9A-Z]{16}\b"#,                                                   // AWS access key
        #"\bgh[pousr]_[A-Z0-9]{20,}"#,                                              // GitHub token
        #"\bxox[baprs]-[A-Z0-9-]{10,}"#,                                            // Slack token
        #"\beyJ[A-Z0-9_-]{10,}\.[A-Z0-9_-]{10,}(?:\.[A-Z0-9_-]+)?"#,                // JWT
        #"(?:password|passwd|pwd|secret|api[ _-]?key|access[ _-]?key|token)\s*[:=]\s*(\S+)"#,
    ]

    private let patterns: [NSRegularExpression]
    private let onResult: @MainActor ([CGRect]) -> Void
    private var task: Task<Void, Never>?

    init(customTerms: [String], onResult: @escaping @MainActor ([CGRect]) -> Void) {
        let custom = customTerms.map { NSRegularExpression.escapedPattern(for: $0) }
        patterns = (Self.builtIn + custom).compactMap {
            try? NSRegularExpression(pattern: $0, options: .caseInsensitive)
        }
        self.onResult = onResult
    }

    func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let rects = (try? await self.scan()) ?? []
                if Task.isCancelled { return }
                await self.onResult(rects)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func scan() async throws -> [CGRect] {
        let screens = await MainActor.run {
            NSScreen.screens.map { screen in
                (id: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                 frame: screen.frame, scale: screen.backingScaleFactor)
            }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = content.applications.filter { $0.processID == getpid() }
        var found: [CGRect] = []
        for display in content.displays {
            guard let screen = screens.first(where: { $0.id == display.displayID }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * screen.scale)
            config.height = Int(CGFloat(display.height) * screen.scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            found += try recognize(image, in: screen.frame)
        }
        return found
    }

    private func recognize(_ image: CGImage, in frame: CGRect) throws -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])

        var rects: [CGRect] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            for pattern in patterns {
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    let group = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                    guard group.location != NSNotFound,
                          let range = Range(group, in: text),
                          let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                    // Vision boxes are normalized with a bottom-left origin, same as Cocoa screens.
                    rects.append(CGRect(x: frame.minX + box.minX * frame.width,
                                        y: frame.minY + box.minY * frame.height,
                                        width: box.width * frame.width,
                                        height: box.height * frame.height).insetBy(dx: -8, dy: -5))
                }
            }
        }
        return rects
    }
}
