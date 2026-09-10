import AppKit
import Testing
@testable import VoxKeyApp

@Test
func statusOverlayUsesTheUpperRightVisibleScreenCorner() {
    let origin = StatusOverlayPlacement.origin(
        windowSize: NSSize(width: 228, height: 52),
        visibleFrame: NSRect(x: 0, y: 40, width: 1440, height: 860)
    )

    #expect(origin.x == 1194)
    #expect(origin.y == 830)
}
