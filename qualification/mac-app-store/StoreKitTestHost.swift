import AppKit

// XCTest owns this process. No fixture UI, credentials, or provider startup.
@main
struct StoreKitTestHost {
    static func main() {
        NSApplication.shared.run()
    }
}
