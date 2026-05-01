// interceptor-vd-helper — clean subprocess that creates and holds
// a CGVirtualDisplay alive. Pattern adapted from Lumen/Sunshine vd_helper.m.
//
// Why a subprocess? CGVirtualDisplay registration with WindowServer is
// poisoned by framework state in the parent process (TCC, AppKit/SCK/etc.
// already loaded). The bridge has loaded ~30 frameworks at startup, which
// causes `applySettings` + `SLSConfigureDisplayEnabled` to leave the new
// display stuck in mirror mode at the main display's resolution.
// A fresh process with only Foundation + AppKit + CoreGraphics + the
// SkyLight private dlopen avoids this.
//
// Usage:    interceptor-vd-helper <width> <height> <fps>
// Output:   first line on stdout = "<displayID>" (or "0" on failure)
// Lifetime: stays running until SIGTERM, holding the CGVirtualDisplay
//           reference alive (display vanishes when this exits).

import Foundation
import AppKit
import CoreGraphics
import Darwin

// MARK: - CGVirtualDisplay private API (NSClassFromString)

@objc protocol CGVirtualDisplayModeProto {
    init(width: UInt32, height: UInt32, refreshRate: Double)
}

@objc protocol CGVirtualDisplayDescriptorProto {
    var name: NSString? { get set }
    var vendorID: UInt32 { get set }
    var productID: UInt32 { get set }
    var serialNum: UInt32 { get set }
    var maxPixelsWide: UInt32 { get set }
    var maxPixelsHigh: UInt32 { get set }
    var sizeInMillimeters: CGSize { get set }
    var queue: DispatchQueue? { get set }
    var terminationHandler: ((Any?, Any?) -> Void)? { get set }
}

@objc protocol CGVirtualDisplaySettingsProto {
    var hiDPI: UInt32 { get set }
    var modes: NSArray? { get set }
}

@objc protocol CGVirtualDisplayProto {
    var displayID: UInt32 { get }
    init?(descriptor: Any)
    func applySettings(_ settings: Any) -> Bool
}

// MARK: - SLS private API (dlopen)

private typealias SLSBeginT = @convention(c) (UnsafeMutablePointer<CGDisplayConfigRef?>) -> Int32
private typealias SLSEnableT = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> Int32
private typealias SLSOriginT = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Int32, Int32) -> Int32
private typealias SLSCompleteT = @convention(c) (CGDisplayConfigRef, UInt32, UInt32) -> Int32

private struct SLSFns {
    let begin: SLSBeginT
    let enable: SLSEnableT
    let origin: SLSOriginT
    let complete: SLSCompleteT
}

private func loadSLS() -> SLSFns? {
    let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    guard let h = dlopen(path, RTLD_LAZY) else { return nil }
    guard let b = dlsym(h, "SLSBeginDisplayConfiguration"),
          let e = dlsym(h, "SLSConfigureDisplayEnabled"),
          let o = dlsym(h, "SLSConfigureDisplayOrigin"),
          let c = dlsym(h, "SLSCompleteDisplayConfiguration") else { return nil }
    return SLSFns(
        begin:    unsafeBitCast(b, to: SLSBeginT.self),
        enable:   unsafeBitCast(e, to: SLSEnableT.self),
        origin:   unsafeBitCast(o, to: SLSOriginT.self),
        complete: unsafeBitCast(c, to: SLSCompleteT.self)
    )
}

// MARK: - Signal handling

nonisolated(unsafe) var shouldExit: sig_atomic_t = 0

@_silgen_name("vdh_signal_handler")
nonisolated(unsafe) func vdhSignalHandler(_ sig: Int32) {
    shouldExit = 1
    CFRunLoopStop(CFRunLoopGetMain())
}

// MARK: - Helpers (kept inline so we don't need extra files)

private func unMirror(_ id: CGDirectDisplayID) {
    var cfg: CGDisplayConfigRef? = nil
    if CGBeginDisplayConfiguration(&cfg) == .success, let cfg = cfg {
        CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(cfg, .forSession)
    }
}

private func switchToNativeMode(_ id: CGDirectDisplayID, width: Int, height: Int) -> Bool {
    let opts: [CFString: Any] = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!]
    guard let modes = CGDisplayCopyAllDisplayModes(id, opts as CFDictionary) else { return false }
    let count = CFArrayGetCount(modes)
    for i in 0..<count {
        let m = unsafeBitCast(CFArrayGetValueAtIndex(modes, i), to: CGDisplayMode.self)
        let lw = m.width, lh = m.height, pw = m.pixelWidth, ph = m.pixelHeight
        if Int(lw) == width && Int(lh) == height && pw == lw && ph == lh {
            return CGDisplaySetDisplayMode(id, m, nil) == .success
        }
    }
    return false
}

// MARK: - Main

@MainActor
func runHelper(width: Int, height: Int, fps: Int) -> UInt32 {
    // Init NSApplication so AppKit is alive but no UI shows.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    // Install signal handlers
    signal(SIGTERM, vdhSignalHandler)
    signal(SIGINT, vdhSignalHandler)
    signal(SIGHUP, vdhSignalHandler)

    guard let descClass = NSClassFromString("CGVirtualDisplayDescriptor"),
          let modeClass = NSClassFromString("CGVirtualDisplayMode"),
          let settingsClass = NSClassFromString("CGVirtualDisplaySettings"),
          let displayClass = NSClassFromString("CGVirtualDisplay") else {
        FileHandle.standardError.write("vd_helper: CGVirtualDisplay classes unavailable\n".data(using: .utf8)!)
        return 0
    }

    // 1. Build CGVirtualDisplayDescriptor — alloc via objc runtime
    guard let descAlloc = (descClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
          let desc = (descAlloc as AnyObject).perform(NSSelectorFromString("init"))?.takeUnretainedValue() else {
        FileHandle.standardError.write("vd_helper: failed to alloc/init CGVirtualDisplayDescriptor\n".data(using: .utf8)!)
        return 0
    }
    let descSet = desc as AnyObject
    _ = descSet.perform(NSSelectorFromString("setName:"), with: "Interceptor Virtual Display" as NSString)
    let setU32: (Selector, UInt32) -> Void = { sel, v in
        let imp = (descSet as AnyObject).method(for: sel)
        typealias F = @convention(c) (AnyObject, Selector, UInt32) -> Void
        unsafeBitCast(imp, to: F.self)(descSet, sel, v)
    }
    setU32(NSSelectorFromString("setVendorID:"), 0xF0F0)
    setU32(NSSelectorFromString("setProductID:"), 0x5678)
    setU32(NSSelectorFromString("setSerialNum:"), arc4random())
    setU32(NSSelectorFromString("setMaxPixelsWide:"), UInt32(width))
    setU32(NSSelectorFromString("setMaxPixelsHigh:"), UInt32(height))
    let setSize: (Selector, CGSize) -> Void = { sel, v in
        let imp = (descSet as AnyObject).method(for: sel)
        typealias F = @convention(c) (AnyObject, Selector, CGSize) -> Void
        unsafeBitCast(imp, to: F.self)(descSet, sel, v)
    }
    // Fixed 27" physical size — Lumen verified that scaling proportional to
    // logical resolution causes WindowServer to reject the descriptor.
    setSize(NSSelectorFromString("setSizeInMillimeters:"), CGSize(width: 597, height: 336))
    _ = descSet.perform(NSSelectorFromString("setQueue:"), with: DispatchQueue.global(qos: .userInitiated))

    // 2. CGVirtualDisplayMode  — alloc via objc runtime so we get an
    // unitialized instance (Swift's `init()` calls the default initializer).
    let modeInitSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
    typealias ModeInit = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>

    func makeMode(_ w: Int, _ h: Int) -> AnyObject? {
        guard let alloc = (modeClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        let allocObj = alloc as AnyObject
        let imp = allocObj.method(for: modeInitSel)
        let initFn = unsafeBitCast(imp, to: ModeInit.self)
        return initFn(allocObj, modeInitSel, UInt32(w), UInt32(h), Double(fps)).takeRetainedValue()
    }
    guard let nativeMode = makeMode(width, height),
          let halfMode = makeMode(width / 2, height / 2) else {
        FileHandle.standardError.write("vd_helper: failed to create modes\n".data(using: .utf8)!)
        return 0
    }

    // 3. Settings — hiDPI=1 so we can pick the native 1x mode after
    guard let settingsAlloc = (settingsClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
          let settingsObj = (settingsAlloc as AnyObject).perform(NSSelectorFromString("init"))?.takeUnretainedValue() else {
        FileHandle.standardError.write("vd_helper: failed to alloc/init CGVirtualDisplaySettings\n".data(using: .utf8)!)
        return 0
    }
    let setHiSel = NSSelectorFromString("setHiDPI:")
    if (settingsObj as AnyObject).responds(to: setHiSel) {
        typealias FSetU32 = @convention(c) (AnyObject, Selector, UInt32) -> Void
        let setHiImp = (settingsObj as AnyObject).method(for: setHiSel)
        unsafeBitCast(setHiImp, to: FSetU32.self)(settingsObj, setHiSel, 1)
    }
    _ = (settingsObj as AnyObject).perform(NSSelectorFromString("setModes:"), with: [nativeMode, halfMode] as NSArray)

    // 4. Create display
    guard let dispAlloc = (displayClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else {
        FileHandle.standardError.write("vd_helper: alloc display failed\n".data(using: .utf8)!)
        return 0
    }
    let initDescSel = NSSelectorFromString("initWithDescriptor:")
    typealias InitDesc = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
    let initDesc = unsafeBitCast((dispAlloc as AnyObject).method(for: initDescSel), to: InitDesc.self)
    guard let displayUm = initDesc(dispAlloc, initDescSel, descSet) else {
        FileHandle.standardError.write("vd_helper: initWithDescriptor returned nil\n".data(using: .utf8)!)
        return 0
    }
    let display = displayUm.takeRetainedValue()

    let applySel = NSSelectorFromString("applySettings:")
    typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    let apply = unsafeBitCast((display as AnyObject).method(for: applySel), to: Apply.self)
    guard apply(display, applySel, settingsObj) else {
        FileHandle.standardError.write("vd_helper: applySettings failed\n".data(using: .utf8)!)
        return 0
    }

    let didSel = NSSelectorFromString("displayID")
    typealias GetID = @convention(c) (AnyObject, Selector) -> UInt32
    let getID = unsafeBitCast((display as AnyObject).method(for: didSel), to: GetID.self)
    let displayID = getID(display, didSel)
    if displayID == 0 {
        FileHandle.standardError.write("vd_helper: displayID == 0\n".data(using: .utf8)!)
        return 0
    }

    // 5. Activate via SLS
    if let sls = loadSLS() {
        var cfg: CGDisplayConfigRef? = nil
        if sls.begin(&cfg) == 0, let cfg = cfg {
            _ = sls.enable(cfg, displayID, true)
            let mainW = Int32(CGDisplayPixelsWide(CGMainDisplayID()))
            _ = sls.origin(cfg, displayID, mainW, 0)
            _ = sls.complete(cfg, 1, 0)  // kCGConfigureForSession
        }
    }
    usleep(500_000)

    // 6. Force extend mode (un-mirror)
    for _ in 0..<3 {
        if CGDisplayIsInMirrorSet(displayID) == 0 && CGDisplayMirrorsDisplay(displayID) == 0 { break }
        unMirror(displayID)
        usleep(300_000)
    }

    // 7. Switch to native 1x mode
    _ = switchToNativeMode(displayID, width: width, height: height)
    usleep(300_000)

    // Hold the strong reference for as long as we run
    objc_setAssociatedObject(NSApplication.shared, "vdh_keepalive", display, .OBJC_ASSOCIATION_RETAIN)
    objc_setAssociatedObject(NSApplication.shared, "vdh_keepalive_desc", desc, .OBJC_ASSOCIATION_RETAIN)
    objc_setAssociatedObject(NSApplication.shared, "vdh_keepalive_settings", settingsObj, .OBJC_ASSOCIATION_RETAIN)

    return displayID
}

// argv parsing: expects 3 ints
let argv = CommandLine.arguments
guard argv.count == 4,
      let w = Int(argv[1]), let h = Int(argv[2]), let fps = Int(argv[3]),
      w > 0, h > 0, fps > 0 else {
    print("0")
    exit(1)
}

let did = MainActor.assumeIsolated { runHelper(width: w, height: h, fps: fps) }
print("\(did)")
fflush(stdout)
if did == 0 { exit(2) }

// Hold the display alive on the main runloop until SIGTERM
while shouldExit == 0 {
    CFRunLoopRunInMode(.defaultMode, 1.0, false)
}

FileHandle.standardError.write("vd_helper: shutting down, releasing display \(did)\n".data(using: .utf8)!)
exit(0)
