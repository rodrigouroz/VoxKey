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
@Test
func focusedWindowRejectsMultipleFocusedEditors() {
    let client = WindowFocusFixture()
    client.focused.insert(5)
    client.childrenByID[2] = [3, 5]
    let resolver = FocusedElementResolver(client: client)
    #expect(resolver.resolve(in: client.application, process: client.process) == nil)
}

@MainActor
@Test
func focusedWindowCannotAcceptAnIncompleteSearch() {
    let client = WindowFocusFixture()
    client.childrenByID[2] = [3] + Array(100...240)
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
@Test
func focusedWindowRetainsSecureFieldsForCaptureRejection() {
    let client = WindowFocusFixture()
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
    var roles: [pid_t: String] = [2: "AXWindow", 3: "AXWebArea", 4: "AXTextArea", 5: "AXTextField", 6: "AXWindow"]
    var focused: Set<pid_t> = [3, 4]
    var childrenByID: [pid_t: [pid_t]] = [2: [3], 3: [4]]

    func focusedElement(in application: AXUIElement) -> AXUIElement? { nil }
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
