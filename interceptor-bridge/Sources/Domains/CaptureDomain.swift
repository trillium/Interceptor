import Foundation
@preconcurrency import ScreenCaptureKit
import AppKit
import CoreMedia
import CoreGraphics
import UniformTypeIdentifiers
import ImageIO

final class CaptureDomain: DomainHandler, @unchecked Sendable {
    private var activeStream: SCStream?
    private var latestFrame: Data?
    private let lock = NSLock()

    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        switch command {
        case "screenshot":
            takeScreenshot(action, completion: completion)
        case "capture":
            handleCapture(action, completion: completion)
        default:
            notImplemented(command, completion: completion)
        }
    }

    private func takeScreenshot(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let appName = action["app"] as? String
        let save = action["save"] as? Bool ?? false
        // WebP added to format union; default jpeg with q80.
        let format = (action["format"] as? String) ?? "jpeg"
        let quality = action["quality"] as? Int ?? 80
        let displayId = action["display"] as? Int
        let windowId = action["window"] as? Int
        let mode = action["mode"] as? String  // "display" forces full-display capture
        let requestedCwd = action["cwd"] as? String
        // cap longest edge at this value before encode. Defaults to 1568 —
        // matches Anthropic vision auto-resize ceiling for Sonnet (Opus is 2576). Set to
        // 0 to disable. The default keeps payloads <300 KB on a 1728×1084 display.
        let targetMaxLongEdge: Int = (action["target_max_long_edge"] as? Int) ?? 1568

        Task {
            do {
                let content = try await SCShareableContent.current
                var filter: SCContentFilter
                // track the SCWindow / SCDisplay we ended up filtering on so
                // we can compute proper width/height for SCStreamConfiguration. SCK's
                // single-frame capture returns a black/empty buffer for occluded
                // windows when width/height are left at default — Apple's
                // capturing-screen-content-in-macos sample explicitly sets
                // `streamConfig.width = window.frame.width * 2` for window mode.
                var targetWindow: SCWindow? = nil
                var targetDisplay: SCDisplay? = nil

                if mode == "display", let display = content.displays.first {
                    filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                    targetDisplay = display
                } else if let appName = appName {
                    guard let _ = content.applications.first(where: { $0.applicationName == appName }) else {
                        completion(WireFormat.error("app not found: \(appName)"))
                        return
                    }
                    // Pick the largest window owned by the app (skip 0×0 helper windows
                    // and the menu-bar item that some apps register).
                    let appWindows = content.windows
                        .filter { $0.owningApplication?.applicationName == appName }
                        .sorted { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }
                    let chosen = appWindows.first ?? content.windows[0]
                    filter = SCContentFilter(desktopIndependentWindow: chosen)
                    targetWindow = chosen
                } else if let displayId = displayId,
                          let display = content.displays.first(where: { Int($0.displayID) == displayId }) {
                    filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                    targetDisplay = display
                } else if let windowId = windowId,
                          let window = content.windows.first(where: { Int($0.windowID) == windowId }) {
                    filter = SCContentFilter(desktopIndependentWindow: window)
                    targetWindow = window
                } else {
                    let frontApp = NSWorkspace.shared.frontmostApplication
                    if let frontPid = frontApp?.processIdentifier,
                       let _ = content.applications.first(where: { $0.processID == frontPid }),
                       let window = content.windows.first(where: { $0.owningApplication?.processID == frontPid }) {
                        filter = SCContentFilter(desktopIndependentWindow: window)
                        targetWindow = window
                    } else if let display = content.displays.first {
                        filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                        targetDisplay = display
                    } else {
                        completion(WireFormat.error("no capturable content found"))
                        return
                    }
                }

                // explicit width/height + 2x point→pixel scale.
                // For window capture, SCK needs concrete dimensions or it returns
                // a black buffer for occluded windows. Use the window frame * pixelScale.
                // For display capture, use the display's pixel dimensions.
                let config = SCStreamConfiguration()
                let pixelScale: Int = 2
                if let w = targetWindow {
                    let wpx = max(1, Int(w.frame.width) * pixelScale)
                    let hpx = max(1, Int(w.frame.height) * pixelScale)
                    config.width = wpx
                    config.height = hpx
                    config.scalesToFit = true
                    config.showsCursor = false
                    // queueDepth + minimumFrameInterval don't apply to single-shot
                    // captureSampleBuffer but setting them is harmless.
                    config.queueDepth = 5
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                    // ignore-shadows + ignore-clipping help on occluded windows
                    // so we get the window's intrinsic content rather than what's on
                    // the visible portion of screen.
                    config.ignoreShadowsSingleWindow = true
                    config.captureResolution = .best
                } else if let d = targetDisplay {
                    config.width = d.width * pixelScale
                    config.height = d.height * pixelScale
                    config.showsCursor = false
                    config.captureResolution = .best
                }
                // For per-window captures, prefer the private SkyLight
                // CGSHWCaptureWindowList path. SCK's `captureSampleBuffer`
                // returns a black buffer for occluded / minimized / off-Space
                // Electron windows because Chromium pauses rendering when
                // unoccluded and SCK reads from the live framebuffer. The CGS
                // path reads from the WindowServer's persistent backing store
                // and works regardless of visibility — the same trick used by
                // AltTab, DockDoor, Loop, and Raycast for ~10 years.
                //
                // Per macOS 15 release notes the *public* `CGWindowListCreateImage`
                // is deprecated, but the private `CGSHWCaptureWindowList` (in
                // SkyLight.framework) remains stable. Screen Recording TCC is
                // still enforced.
                var cgImg: CGImage
                if let w = targetWindow,
                   let cgs = cgsCaptureWindow(
                    windowID: CGWindowID(w.windowID),
                    options: [.ignoreGlobalClipShape, .bestResolution, .fullSize]
                   ) {
                    cgImg = cgs
                } else {
                    // Fallback to SCK (display captures + edge cases).
                    let sampleBuffer = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        completion(WireFormat.error("failed to get pixel buffer"))
                        return
                    }
                    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                    let ciContext = CIContext()
                    guard let img = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                        completion(WireFormat.error("failed to create CGImage"))
                        return
                    }
                    cgImg = img
                }

                let originalWidth = cgImg.width
                let originalHeight = cgImg.height

                // resize at capture if requested.
                if targetMaxLongEdge > 0 {
                    let longEdge = max(originalWidth, originalHeight)
                    if longEdge > targetMaxLongEdge {
                        let scale = Double(targetMaxLongEdge) / Double(longEdge)
                        let newW = Int(Double(originalWidth) * scale)
                        let newH = Int(Double(originalHeight) * scale)
                        if let resized = Self.resize(cgImage: cgImg, width: newW, height: newH) {
                            cgImg = resized
                        }
                    }
                }

                // encode to png/jpeg/webp via CGImageDestination so we get
                // identical pipelines for all three formats (NSBitmapImageRep does not
                // support WebP).
                guard let data = Self.encode(cgImage: cgImg, format: format, quality: quality) else {
                    completion(WireFormat.error("failed to encode image as \(format)"))
                    return
                }

                let mimeType = format == "png" ? "image/png" : (format == "webp" ? "image/webp" : "image/jpeg")
                let ext = format == "png" ? "png" : (format == "webp" ? "webp" : "jpg")

                if save {
                    let filename = "interceptor-macos-screenshot-\(Int(Date().timeIntervalSince1970)).\(ext)"
                    let fileURL = resolveSaveURL(filename: filename, requestedCwd: requestedCwd)
                    try data.write(to: fileURL)
                    // when save:true, strip dataUrl from the response so
                    // downstream agents don't re-pay for the bytes inline. The filePath is
                    // sufficient — the agent can re-read the file when needed.
                    completion(WireFormat.success([
                        "filePath": fileURL.path,
                        "format": format,
                        "bytes": data.count,
                        "width": cgImg.width,
                        "height": cgImg.height,
                        "originalWidth": originalWidth,
                        "originalHeight": originalHeight
                    ]))
                } else {
                    let dataUrl = "data:\(mimeType);base64,\(data.base64EncodedString())"
                    completion(WireFormat.success([
                        "dataUrl": dataUrl,
                        "format": format,
                        "bytes": data.count,
                        "width": cgImg.width,
                        "height": cgImg.height,
                        "originalWidth": originalWidth,
                        "originalHeight": originalHeight
                    ]))
                }
            } catch {
                let errMsg = error.localizedDescription
                if errMsg.contains("3801") || errMsg.contains("declined") {
                    completion(WireFormat.error("Screen Recording permission required: System Settings → Privacy & Security → Screen Recording → Enable Interceptor"))
                } else {
                    completion(WireFormat.error("screenshot failed: \(errMsg)"))
                }
            }
        }
    }

    /// resize a CGImage via CoreGraphics. Bilinear-style filtering at
    /// `.high` interpolation quality. Returns nil on context-creation failure.
    private static func resize(cgImage: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = 0
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// encode a CGImage to png/jpeg/webp via CGImageDestination.
    /// WebP at q85 by default per academic evidence (ACAD-COMPRESS-BENCH).
    private static func encode(cgImage: CGImage, format: String, quality: Int) -> Data? {
        let utType: UTType
        switch format.lowercased() {
        case "png":  utType = .png
        case "webp":
            if #available(macOS 11.0, *), let webp = UTType("public.webp") ?? UTType("org.webmproject.webp") {
                utType = webp
            } else {
                return nil
            }
        default:     utType = .jpeg
        }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            utType.identifier as CFString,
            1, nil
        ) else { return nil }

        let q = max(0, min(100, quality))
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: Float(q) / 100.0
        ]
        CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    private func resolveSaveURL(filename: String, requestedCwd: String?) -> URL {
        let fm = FileManager.default

        let candidateDirs: [URL] = [
            requestedCwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
            fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        ].compactMap { $0 }

        for dir in candidateDirs {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue, fm.isWritableFile(atPath: dir.path) {
                return dir.appendingPathComponent(filename, isDirectory: false)
            }
        }

        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    private func handleCapture(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let sub = action["sub"] as? String ?? "frame"
        switch sub {
        case "start":
            startContinuousCapture(action, completion: completion)
        case "frame":
            lock.lock()
            let frame = latestFrame
            lock.unlock()
            if let frame = frame {
                completion(WireFormat.success(["dataUrl": "data:image/jpeg;base64,\(frame.base64EncodedString())"]))
            } else {
                completion(WireFormat.error("no active capture stream — use screenshot instead"))
            }
        case "stop":
            lock.lock()
            activeStream?.stopCapture()
            activeStream = nil
            latestFrame = nil
            lock.unlock()
            completion(WireFormat.success("capture stopped"))
        default:
            notImplemented("capture \(sub)", completion: completion)
        }
    }

    private func startContinuousCapture(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let appName = action["app"] as? String
        Task {
            do {
                let content = try await SCShareableContent.current
                let filter: SCContentFilter
                if let appName = appName,
                   let app = content.applications.first(where: { $0.applicationName == appName }),
                   let window = content.windows.first(where: { $0.owningApplication?.processID == app.processID }) {
                    filter = SCContentFilter(desktopIndependentWindow: window)
                } else if let frontApp = NSWorkspace.shared.frontmostApplication,
                          let window = content.windows.first(where: { $0.owningApplication?.processID == frontApp.processIdentifier }) {
                    filter = SCContentFilter(desktopIndependentWindow: window)
                } else if let display = content.displays.first {
                    filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                } else {
                    completion(WireFormat.error("no capturable content"))
                    return
                }

                let config = SCStreamConfiguration()
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)

                let output = CaptureStreamOutput { [weak self] data in
                    self?.lock.withLock { self?.latestFrame = data }
                }

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue.global())
                try await stream.startCapture()

                self.lock.withLock { self.activeStream = stream }

                completion(WireFormat.success("continuous capture started"))
            } catch {
                let msg = error.localizedDescription
                if msg.contains("3801") || msg.contains("declined") {
                    completion(WireFormat.error("Screen Recording permission required"))
                } else {
                    completion(WireFormat.error("capture start failed: \(msg)"))
                }
            }
        }
    }
}

@available(macOS 13.0, *)
final class CaptureStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onFrame: @Sendable (Data) -> Void

    init(onFrame: @escaping @Sendable (Data) -> Void) {
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        if let cgImage = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height)) {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.5]) {
                onFrame(data)
            }
        }
    }
}
