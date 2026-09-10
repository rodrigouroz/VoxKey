import AppKit

struct PasteboardLease {
    enum Restoration: Equatable {
        case restored
        case ownershipLost
        case failed
    }

    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pasteboard: NSPasteboard
    private let snapshot: PasteboardSnapshot
    private let changeCount: Int

    var isOwned: Bool { pasteboard.changeCount == changeCount }

    static func begin(text: String, pasteboard: NSPasteboard) -> PasteboardLease? {
        guard let snapshot = PasteboardSnapshot.capture(pasteboard) else { return nil }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setString("", forType: transientType),
              item.setString("", forType: concealedType) else {
            return nil
        }
        guard pasteboard.changeCount == snapshot.changeCount else { return nil }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            _ = snapshot.restore(to: pasteboard)
            return nil
        }
        return PasteboardLease(
            pasteboard: pasteboard,
            snapshot: snapshot,
            changeCount: pasteboard.changeCount
        )
    }

    @discardableResult
    func restoreIfOwned() -> Restoration {
        guard isOwned else { return .ownershipLost }
        return snapshot.restore(to: pasteboard) ? .restored : .failed
    }
}

struct PasteboardSnapshot {
    struct Item {
        let representations: [(NSPasteboard.PasteboardType, Data)]
    }

    let items: [Item]
    let changeCount: Int

    static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        let changeCount = pasteboard.changeCount
        var items: [Item] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                representations.append((type, data))
            }
            items.append(Item(representations: representations))
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        return PasteboardSnapshot(items: items, changeCount: changeCount)
    }

    func restore(to pasteboard: NSPasteboard) -> Bool {
        var restoredItems: [NSPasteboardItem] = []
        for saved in items {
            let item = NSPasteboardItem()
            for (type, data) in saved.representations {
                guard item.setData(data, forType: type) else { return false }
            }
            restoredItems.append(item)
        }
        pasteboard.clearContents()
        return restoredItems.isEmpty || pasteboard.writeObjects(restoredItems)
    }
}
