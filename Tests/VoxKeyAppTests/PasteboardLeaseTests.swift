import AppKit
import Foundation
import Testing
@testable import VoxKeyApp

@MainActor
@Test
func pasteboardLeaseRestoresEveryOriginalItemAndRepresentation() throws {
    let pasteboard = makeIsolatedPasteboard()
    let binaryType = NSPasteboard.PasteboardType("com.rodrigouroz.VoxKey.tests.binary")
    let first = NSPasteboardItem()
    first.setString("original text", forType: .string)
    first.setData(Data([0x00, 0x7f, 0xff]), forType: binaryType)
    let second = NSPasteboardItem()
    second.setString("second item", forType: .string)
    pasteboard.writeObjects([first, second])

    let lease = try #require(PasteboardLease.begin(text: "temporary dictation", pasteboard: pasteboard))

    let leasedItem = try #require(pasteboard.pasteboardItems?.first)
    #expect(leasedItem.string(forType: .string) == "temporary dictation")
    #expect(leasedItem.types.contains(PasteboardLease.transientType))
    #expect(leasedItem.types.contains(PasteboardLease.concealedType))
    #expect(lease.restoreIfOwned() == .restored)

    let restoredItems = try #require(pasteboard.pasteboardItems)
    #expect(restoredItems.count == 2)
    #expect(restoredItems[0].string(forType: .string) == "original text")
    #expect(restoredItems[0].data(forType: binaryType) == Data([0x00, 0x7f, 0xff]))
    #expect(restoredItems[1].string(forType: .string) == "second item")
}

@MainActor
@Test
func pasteboardLeaseDoesNotOverwriteAConcurrentUserChange() throws {
    let pasteboard = makeIsolatedPasteboard()
    pasteboard.setString("original", forType: .string)
    let lease = try #require(PasteboardLease.begin(text: "temporary dictation", pasteboard: pasteboard))

    pasteboard.clearContents()
    pasteboard.setString("new user clipboard", forType: .string)

    #expect(lease.restoreIfOwned() == .ownershipLost)
    #expect(pasteboard.string(forType: .string) == "new user clipboard")
}

@MainActor
@Test
func pasteboardLeaseRestoresAnOriginallyEmptyPasteboard() throws {
    let pasteboard = makeIsolatedPasteboard()
    let lease = try #require(PasteboardLease.begin(text: "temporary dictation", pasteboard: pasteboard))

    #expect(lease.restoreIfOwned() == .restored)
    #expect(pasteboard.pasteboardItems?.isEmpty != false)
}

@MainActor
private func makeIsolatedPasteboard() -> NSPasteboard {
    let name = NSPasteboard.Name("com.rodrigouroz.VoxKey.tests.\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    pasteboard.clearContents()
    return pasteboard
}
