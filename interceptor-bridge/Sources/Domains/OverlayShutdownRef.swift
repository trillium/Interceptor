// tiny global ref so the C-convention `signal()` handlers in
// main.swift can teardown overlays without capturing the OverlayDomain
// instance directly (signal handlers are restricted to function pointers).
//
// The engine-side equivalent (per-session overlay stop on bridge disconnect)
// happens in the daemon by tracking owner ids per overlay. This bridge-side
// global ref is the last-resort cleanup when the bridge process itself dies.

import Foundation

enum GlobalOverlayDomainRef {
    /// Set once at bridge boot from main.swift. Never reassigned. Read-only
    /// from the signal handlers, which run on a Darwin-internal thread; the
    /// OverlayDomain itself dispatches all NSPanel work onto the main thread,
    /// so this is safe under Swift 6 strict concurrency.
    nonisolated(unsafe) static var shared: OverlayDomain?
}
