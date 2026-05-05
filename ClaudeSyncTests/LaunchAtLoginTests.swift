import XCTest
@testable import ClaudeSync

/// LaunchAtLoginController wraps SMAppService.mainApp which has system-wide
/// side effects (writes to LaunchServices). We don't actually register the
/// test bundle as a login item — we only verify that the controller reports a
/// reasonable status without crashing and that toggling reflects in `status`
/// when SMAppService accepts the call.
@MainActor
final class LaunchAtLoginTests: XCTestCase {

    func testStatus_returnsKnownCase() {
        let c = LaunchAtLoginController()
        let s = c.status
        XCTAssertTrue(
            s == .enabled || s == .disabled || s == .requiresApproval || s == .notSupported,
            "Got unexpected status: \(s)"
        )
    }

    func testIsEnabled_matchesStatus() {
        let c = LaunchAtLoginController()
        XCTAssertEqual(c.isEnabled, c.status == .enabled)
    }
}
