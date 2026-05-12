import Foundation
import AppKit

// MonitorWorkspaceBridge subscribes to NSWorkspace notifications for
// app/space/volume/wake events. Subscriptions go through
// NSWorkspace.shared.notificationCenter (NOT the default NotificationCenter)
// per Apple's documented constraint on didActivateApplicationNotification.
//
// Each notification is converted to a flat event dict with stable field names
// (`app`, `bundleId`, `pid`) and forwarded to the EventCallback. The bridge
// also exposes attach/detach hooks so MonitorDomain can drive AX-observer
// lifecycle in response to app launches.

final class MonitorWorkspaceBridge: @unchecked Sendable {
    typealias EventCallback = (_ event: String, _ data: [String: Any]) -> Void
    typealias AppLaunchHook = (_ pid: pid_t, _ bundleId: String?, _ appName: String?) -> Void
    typealias AppTerminateHook = (_ pid: pid_t) -> Void

    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []
    private var callback: EventCallback?
    private var launchHook: AppLaunchHook?
    private var terminateHook: AppTerminateHook?

    func setCallback(_ cb: @escaping EventCallback) {
        lock.lock(); defer { lock.unlock() }
        self.callback = cb
    }

    func setAppLifecycleHooks(launch: @escaping AppLaunchHook, terminate: @escaping AppTerminateHook) {
        lock.lock(); defer { lock.unlock() }
        self.launchHook = launch
        self.terminateHook = terminate
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        let pairs: [(NSNotification.Name, String)] = [
            (NSWorkspace.didActivateApplicationNotification, "frontmost"),
            (NSWorkspace.didDeactivateApplicationNotification, "app_deactivate"),
            (NSWorkspace.didLaunchApplicationNotification, "app_launch"),
            (NSWorkspace.didTerminateApplicationNotification, "app_terminate"),
            (NSWorkspace.didHideApplicationNotification, "app_hide"),
            (NSWorkspace.didUnhideApplicationNotification, "app_unhide"),
            (NSWorkspace.activeSpaceDidChangeNotification, "space"),
            (NSWorkspace.didMountNotification, "mount"),
            (NSWorkspace.didUnmountNotification, "unmount"),
            (NSWorkspace.didRenameVolumeNotification, "volume_rename"),
            (NSWorkspace.didWakeNotification, "wake"),
            (NSWorkspace.willSleepNotification, "sleep"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session_active"),
            (NSWorkspace.sessionDidResignActiveNotification, "session_inactive")
        ]
        var newObservers: [NSObjectProtocol] = []
        for (name, eventName) in pairs {
            let token = nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                self?.handle(notification: note, eventName: eventName)
            }
            newObservers.append(token)
        }
        lock.lock()
        observers.append(contentsOf: newObservers)
        lock.unlock()
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        lock.lock()
        let toRemove = observers
        observers.removeAll()
        lock.unlock()
        for o in toRemove { nc.removeObserver(o) }
    }

    private func handle(notification: Notification, eventName: String) {
        var data: [String: Any] = [:]
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            data["app"] = app.localizedName ?? ""
            data["bundleId"] = app.bundleIdentifier ?? ""
            data["pid"] = Int(app.processIdentifier)
        }
        if let path = notification.userInfo?["NSDevicePath"] as? String {
            data["path"] = path
        }
        if let volName = notification.userInfo?["NSWorkspaceVolumeLocalizedNameKey"] as? String {
            data["name"] = volName
        }

        // Lifecycle hooks fire BEFORE the event callback so attach happens
        // ahead of the first AX notification on the new pid.
        let pid = data["pid"] as? Int
        if eventName == "app_launch", let p = pid {
            launchHook?(pid_t(p), data["bundleId"] as? String, data["app"] as? String)
        }
        if eventName == "app_terminate", let p = pid {
            terminateHook?(pid_t(p))
        }

        callback?(eventName, data)
    }
}
