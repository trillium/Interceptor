import Foundation

// Any overlay view that can accept verb-driven commands from the CLI.
// `perform` must be called on the main thread — OverlayDomain handles that.
@MainActor
protocol OverlayControllable: AnyObject {
    func perform(verb: String, args: [String: Any]) -> [String: Any]
    var supportedVerbs: [String] { get }
}
