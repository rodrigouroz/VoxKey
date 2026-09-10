import Testing
@testable import VoxKeyApp

@Test
func readOnlyAccessibilityAttributesDoNotRejectKeyboardEditableFields() {
    #expect(DestinationCapabilityClassifier.isEditable(
        role: "AXTextArea", editable: nil, enabled: true, hasSelection: true, directInsertionSettable: false
    ))
    #expect(!DestinationCapabilityClassifier.isEditable(
        role: "AXStaticText", editable: nil, enabled: true, hasSelection: true, directInsertionSettable: false
    ))
    #expect(!DestinationCapabilityClassifier.isEditable(
        role: "AXTextArea", editable: false, enabled: true, hasSelection: true, directInsertionSettable: true
    ))
    #expect(!DestinationCapabilityClassifier.isEditable(
        role: "AXTextArea", editable: true, enabled: false, hasSelection: true, directInsertionSettable: true
    ))
}

@Test
func webBackedDestinationUsesPasteboardRoute() {
    #expect(DeliveryRoutePolicy.preferredRoute(
        isWebBacked: true,
        directInsertionSettable: true,
        directInsertionKnownUnsupported: false
    ) == .pasteboard)
}

@Test
func nativeDestinationUsesDirectInsertionWhenAvailable() {
    #expect(DeliveryRoutePolicy.preferredRoute(
        isWebBacked: false,
        directInsertionSettable: true,
        directInsertionKnownUnsupported: false
    ) == .accessibilitySelection)
}

@Test
func learnedDirectInsertionNoOpUsesPasteboardRoute() {
    #expect(DeliveryRoutePolicy.preferredRoute(
        isWebBacked: false,
        directInsertionSettable: true,
        directInsertionKnownUnsupported: true
    ) == .pasteboard)
}

@Test
func unavailableDirectInsertionUsesPasteboardRoute() {
    #expect(DeliveryRoutePolicy.preferredRoute(
        isWebBacked: false,
        directInsertionSettable: false,
        directInsertionKnownUnsupported: false
    ) == .pasteboard)
}

@Test
func webCapabilitiesAreDetectedWithoutApplicationIdentity() {
    #expect(DestinationCapabilityClassifier.isWebBacked(
        role: "AXTextArea",
        attributeNames: ["AXSelectedTextMarkerRange"]
    ))
    #expect(DestinationCapabilityClassifier.isWebBacked(
        role: "AXWebArea",
        attributeNames: []
    ))
    #expect(!DestinationCapabilityClassifier.isWebBacked(
        role: "AXTextArea",
        attributeNames: ["AXValue", "AXSelectedTextRange"]
    ))
}
