import ApplicationServices
import Foundation
import Testing
@testable import VoxKeyApp

@MainActor
@Test
func focusedWindowCanExposeTheEditorWhenTopLevelFocusIsMissing() {
    let client = WindowFocusFixture()
    let resolver = FocusedElementResolver(client: client)
    let result = resolver.resolve(in: client.application, process: client.process)
    #expect(result.map { CFEqual($0, client.editor) } == true)
}

@MainActor
@Test(arguments: ["AXWebArea", "AXScrollArea"])
func focusedWindowResolvesEditorBehindReportedContainer(role: String) {
    let client = WindowFocusFixture()
    client.reportedFocusID = 3
    client.roles[3] = role
    let resolver = FocusedElementResolver(client: client)
    #expect(resolver.resolve(in: client.application, process: client.process).map { CFEqual($0, client.editor) } == true)
}

@MainActor
@Test
func focusedWindowFindsComposerBeyondConversationHistory() {
    let client = WindowFocusFixture()
    client.reportedFocusID = 3
    client.childrenByID[3] = Array(100...280) + [4]
    let resolver = FocusedElementResolver(client: client)
    #expect(resolver.resolve(in: client.application, process: client.process).map { CFEqual($0, client.editor) } == true)
}

@MainActor
@Test(arguments: [false, true])
func focusedWindowFindsEditorDespiteDeepUnrelatedBranch(editorFirst: Bool) {
    let client = WindowFocusFixture()
    client.addDeepBranch()
    client.childrenByID[3] = editorFirst ? [4, 100] : [100, 4]
    let resolver = FocusedElementResolver(client: client)
    #expect(resolver.resolve(in: client.application, process: client.process).map { CFEqual($0, client.editor) } == true)
}

@MainActor
@Test(arguments: ["AXTextArea", "AXSecureTextField"])
func focusedWindowFindsDeepEditorWithoutDiscardingSecureRole(role: String) {
    let client = WindowFocusFixture()
    client.addDeepBranch()
    client.childrenByID[3] = [100]
    client.childrenByID[123] = [4]
    client.roles[4] = role
    let resolver = FocusedElementResolver(client: client)
    #expect(resolver.resolve(in: client.application, process: client.process).map { CFEqual($0, client.editor) } == true)
}

@MainActor
@Test
func focusedWindowRejectsAmbiguousEditorInDeepBranch() {
    let client = WindowFocusFixture()
    client.addDeepBranch()
    client.childrenByID[3] = [4, 100]
    client.childrenByID[123] = [5]
    client.focused.insert(5)
    let resolver = FocusedElementResolver(client: client)
    #expect(resolver.resolve(in: client.application, process: client.process) == nil)
}

@MainActor
@Test
func focusedWindowTerminatesDeepCycleAndFindsEditor() {
    let client = WindowFocusFixture()
    client.addDeepBranch()
    client.childrenByID[3] = [100, 4]
    client.childrenByID[123] = [100]
    let resolver = FocusedElementResolver(client: client)
    #expect(resolver.resolve(in: client.application, process: client.process).map { CFEqual($0, client.editor) } == true)
}

@MainActor
@Test
func focusedWindowCannotAcceptDeepSearchPastNodeBudget() {
    let client = WindowFocusFixture()
    client.childrenByID[3] = [4, 100]
    for id: pid_t in 100..<700 { client.childrenByID[id] = [id + 1] }
    let resolver = FocusedElementResolver(client: client)
    #expect(resolver.resolve(in: client.application, process: client.process) == nil)
}

@MainActor
@Test
func reportedContainerDoesNotMakeAnUnfocusedEditorEligible() {
    let client = WindowFocusFixture()
    client.reportedFocusID = 3
    client.focused = [3]
    let resolver = FocusedElementResolver(client: client)
    #expect(resolver.resolve(in: client.application, process: client.process) == nil)
}

@MainActor
@Test(arguments: ["AXButton", "AXGroup", "AXSecureTextField"])
func otherReportedControlsRemainAuthoritative(role: String) {
    let client = WindowFocusFixture()
    client.reportedFocusID = 3
    client.roles[3] = role
    let resolver = FocusedElementResolver(client: client)
    #expect(resolver.resolve(in: client.application, process: client.process).map { CFEqual($0, AXUIElementCreateApplication(3)) } == true)
}

@MainActor
@Test(arguments: [nil, 3] as [pid_t?])
func focusedWindowRejectsMultipleFocusedEditors(reportedFocusID: pid_t?) {
    let client = WindowFocusFixture()
    client.reportedFocusID = reportedFocusID
    client.focused.insert(5)
    client.childrenByID[2] = [3, 5]
    let resolver = FocusedElementResolver(client: client)
    #expect(resolver.resolve(in: client.application, process: client.process) == nil)
}

@MainActor
@Test(arguments: [nil, 3] as [pid_t?])
func focusedWindowCannotAcceptAnIncompleteSearch(reportedFocusID: pid_t?) {
    let client = WindowFocusFixture()
    client.reportedFocusID = reportedFocusID
    client.childrenByID[2] = [3] + Array(100...620)
    let resolver = FocusedElementResolver(client: client)
    #expect(resolver.resolve(in: client.application, process: client.process) == nil)
}

@MainActor
@Test
func focusedWindowChangeInvalidatesAnObservedEditor() {
    let client = WindowFocusFixture()
    let resolver = FocusedElementResolver(client: client)
    #expect(resolver.resolve(in: client.application, process: client.process) != nil)
    client.windowID = 6
    #expect(resolver.resolve(in: client.application, process: client.process) == nil)
}

@MainActor
@Test(arguments: [nil, 3] as [pid_t?])
func focusedWindowRetainsSecureFieldsForCaptureRejection(reportedFocusID: pid_t?) {
    let client = WindowFocusFixture()
    client.reportedFocusID = reportedFocusID
    client.roles[4] = "AXSecureTextField"
    let resolver = FocusedElementResolver(client: client)
    let result = resolver.resolve(in: client.application, process: client.process)
    #expect(result.map { CFEqual($0, client.editor) } == true)
}

/// Only the external AX tree is substituted. The resolver and its search,
/// cache validation, ambiguity handling, and limits execute normally.
@MainActor
private final class WindowFocusFixture: FocusedElementClient {
    let application = AXUIElementCreateApplication(1)
    let editor = AXUIElementCreateApplication(4)
    let process = AccessibilityProcessIdentity(processIdentifier: 1, launchDate: Date(timeIntervalSince1970: 1))
    var windowID: pid_t = 2
    var reportedFocusID: pid_t?
    var roles: [pid_t: String] = [2: "AXWindow", 3: "AXWebArea", 4: "AXTextArea", 5: "AXTextField", 6: "AXWindow"]
    var focused: Set<pid_t> = [3, 4]
    var childrenByID: [pid_t: [pid_t]] = [2: [3], 3: [4]]

    func addDeepBranch() {
        for id: pid_t in 100..<123 { childrenByID[id] = [id + 1] }
    }

    func focusedElement(in application: AXUIElement) -> AXUIElement? {
        reportedFocusID.map { AXUIElementCreateApplication($0) }
    }
    func systemWideFocusedElement() -> AXUIElement? { nil }
    func processIdentifier(of element: AXUIElement) -> pid_t? { id(element) }
    func isFocused(_ element: AXUIElement) -> Bool { focused.contains(id(element)) }
    func enable(_ attribute: String, in application: AXUIElement) -> AXError { .attributeUnsupported }
    func focusedWindow(in application: AXUIElement) -> AXUIElement? { AXUIElementCreateApplication(windowID) }
    func role(of element: AXUIElement) -> String? { roles[id(element)] ?? "AXGroup" }
    func children(of element: AXUIElement, limit: Int) -> [AXUIElement]? {
        (childrenByID[id(element)] ?? []).prefix(limit).map { AXUIElementCreateApplication($0) }
    }
    private func id(_ element: AXUIElement) -> pid_t {
        var pid = pid_t()
        _ = AXUIElementGetPid(element, &pid)
        return pid
    }
}

#if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
@MainActor
@Test(arguments: ["matched", "node_limit", "ambiguous_editors"])
func performanceFocusDiagnosticsDescribeActualSearchResult(expected: String) throws {
    let client = WindowFocusFixture()
    client.addDeepBranch()
    client.childrenByID[3] = [100]
    client.childrenByID[123] = [4]
    if expected == "node_limit" {
        client.childrenByID[2] = [3] + Array(200...820)
    } else if expected == "ambiguous_editors" {
        client.childrenByID[2] = [3, 5]
        client.focused.insert(5)
    }
    let diagnostics = DestinationDiagnostics()
    let resolver = FocusedElementResolver(client: client)
    let result = DestinationDiagnostics.$current.withValue(diagnostics) {
        resolver.resolve(in: client.application, process: client.process)
    }
    #expect((result != nil) == (expected == "matched"))
    if let result { #expect(CFEqual(result, client.editor)) }
    let record = diagnostics.finish(status: expected)
    let attempt = try #require(record.focusAttempts.last)
    #expect(attempt.searchResult == expected)
    #expect(attempt.visited > 0)
    if expected == "matched" { #expect(try #require(attempt.editorDepth) > 12) }
    #expect(attempt.manualAccessibilityResult == AXError.attributeUnsupported.rawValue)
}
#endif
