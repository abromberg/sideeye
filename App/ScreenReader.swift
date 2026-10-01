import AppKit
import FocusCore
import ScreenCaptureKit
import Vision

/// On by default (Settings → Privacy): single-window screenshot → Vision OCR, plus a downscaled JPEG for the describer.
/// Before the JPEG is made, anything the `Redactor` would scrub from text (emails, card numbers, phones, SSNs, keys)
/// is blacked out in the image, using the OCR's own bounding boxes.
/// A perceptual hash skips OCR when the window hasn't visibly changed.
actor ScreenReader {
    private var lastHash: UInt64?
    private var lastPID: pid_t?
    private var lastResult: (ocrText: String, jpeg: Data)?

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// `crop`, when given, is the part of the window to keep, in screen coordinates (a browser's page area).
    func read(pid: pid_t, title: String, crop: CGRect? = nil) async -> (ocrText: String, jpeg: Data)? {
        guard Self.hasPermission, let image = await capture(pid: pid, title: title, crop: crop) else { return nil }
        let hash = Self.dHash(image)
        if pid == lastPID, let lastHash, let lastResult, (hash ^ lastHash).nonzeroBitCount <= 4 {
            return lastResult
        }
        let lines = Self.recognize(image)
        let text = lines.map(\.string).joined(separator: "\n")
        guard let redacted = Self.blackOut(Self.sensitiveBoxes(in: lines), in: image),
              let jpeg = Self.jpeg(redacted, maxSide: 1024) else { return nil }
        let result = (text, jpeg)
        lastHash = hash
        lastPID = pid
        lastResult = result
        return result
    }

    private func capture(pid: pid_t, title: String, crop: CGRect?) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let candidates = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 100 && $0.frame.height > 100
            }
            guard let window = candidates.first(where: { $0.title == title && !title.isEmpty })
                ?? candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = min(1, 1600 / max(window.frame.width, window.frame.height)) * CGFloat(filter.pointPixelScale)
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let crop else { return image }
            let px = CGFloat(image.width) / window.frame.width
            let rect = crop.intersection(window.frame).offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            guard rect.width > 100, rect.height > 100 else { return image }
            return image.cropping(to: CGRect(x: rect.minX * px, y: rect.minY * px, width: rect.width * px, height: rect.height * px)
                .integral) ?? image
        } catch {
            return nil
        }
    }

    /// Accurate (not fast) recognition: a misread digit would let a number slip past redaction.
    /// Runs only when metadata and window text left the judge unsure.
    static func recognize(_ image: CGImage) -> [VNRecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
    }

    /// Normalized (Vision, bottom-left origin) boxes around every sensitive span.
    static func sensitiveBoxes(in lines: [VNRecognizedText]) -> [CGRect] {
        lines.flatMap { line in
            Redactor.find(in: line.string).compactMap { match -> CGRect? in
                // Box just the match when Vision can; otherwise the whole line.
                let whole = line.string.startIndex..<line.string.endIndex
                return ((try? line.boundingBox(for: match.range)) ?? (try? line.boundingBox(for: whole)))?.boundingBox
            }
        }
    }

    /// The image with each normalized box painted solid black (padded a little to cover glyph edges).
    static func blackOut(_ boxes: [CGRect], in image: CGImage) -> CGImage? {
        guard !boxes.isEmpty else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for box in boxes {
            // Vision and CGContext both use a bottom-left origin, so no flip is needed.
            let r = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h)
            ctx.fill(r.insetBy(dx: -4, dy: -3))
        }
        return ctx.makeImage()
    }

    /// 64-bit difference hash on a 9×8 grayscale thumbnail.
    static func dHash(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                hash <<= 1
                if pixels[y * w + x] > pixels[y * w + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    static func jpeg(_ image: CGImage, maxSide: CGFloat) -> Data? {
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }
}
