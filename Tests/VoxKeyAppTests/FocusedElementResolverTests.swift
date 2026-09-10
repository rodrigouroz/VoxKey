import ApplicationServices
import Foundation
import Testing
@testable import VoxKeyApp

@MainActor
@Test
func transientAccessibilityEnablementFailureCanRecover() async throws {
    let client = RecoveringAccessibilityClient()
    let resolver = FocusedElementResolver(client: client)
    let application = AXUIElementCreateApplication(getpid())
    let process = AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: Date())
    #expect(resolver.resolve(in: application, process: process) == nil)
    client.messagingRecovered = true
    try await Task.sleep(for: .milliseconds(300))
    #expect(resolver.resolve(in: application, process: process) != nil)
}

@MainActor
private final class RecoveringAccessibilityClient: FocusedElementClient {
    var messagingRecovered = false
    private var enabled = false
    func focusedElement(in application: AXUIElement) -> AXUIElement? { enabled ? application : nil }
    func systemWideFocusedElement() -> AXUIElement? { nil }
    func processIdentifier(of element: AXUIElement) -> pid_t? { getpid() }
    func isFocused(_ element: AXUIElement) -> Bool { enabled }
    func enable(_ attribute: String, in application: AXUIElement) -> AXError {
        guard messagingRecovered else { return .cannotComplete }
        enabled = true
        return .success
    }
}

@MainActor
@Test
func focusedElementResolverKeepsTheOrdinaryPathFast() throws {
    let client = StubFocusedElementClient(reads: [true])
    let resolver = FocusedElementResolver(client: client)

    let result = resolver.resolve(
        in: AXUIElementCreateApplication(getpid()),
        process: AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: Date())
    )

    #expect(result != nil)
    #expect(client.enabledAttributes.isEmpty)
}

@MainActor
@Test
func applicationReportedRendererFocusCanBelongToAnotherProcess() {
    let client = StubFocusedElementClient(reads: [true, false], systemWideProcessIdentifier: getpid() + 1)
    let resolver = FocusedElementResolver(client: client)
    let application = AXUIElementCreateApplication(getpid())
    let process = AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: Date())
    #expect(resolver.resolve(in: application, process: process) != nil)
    #expect(resolver.resolve(in: application, process: process) != nil)
    #expect(client.enabledAttributes.isEmpty)
}

@MainActor
@Test
func focusedElementResolverUsesMatchingSystemWideFocusWhenApplicationFocusIsMissing() throws {
    let client = StubFocusedElementClient(
        reads: [false],
        systemWideReads: [true],
        systemWideProcessIdentifier: getpid()
    )
    let resolver = FocusedElementResolver(client: client)

    let result = resolver.resolve(
        in: AXUIElementCreateApplication(getpid()),
        process: AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: Date())
    )

    #expect(result != nil)
    #expect(client.enabledAttributes.isEmpty)
}

@MainActor
@Test
func focusedElementResolverRejectsSystemWideFocusFromAnotherProcess() {
    let client = StubFocusedElementClient(
        reads: [false, false, false],
        systemWideReads: [true, true, true],
        systemWideProcessIdentifier: getpid() + 1
    )
    let resolver = FocusedElementResolver(client: client)

    let result = resolver.resolve(
        in: AXUIElementCreateApplication(getpid()),
        process: AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: Date())
    )

    #expect(result == nil)
    #expect(client.enabledAttributes == [
        FocusedElementResolver.manualAccessibilityAttribute,
        FocusedElementResolver.enhancedUserInterfaceAttribute
    ])
}

@MainActor
@Test
func focusedElementResolverUsesTheLastVerifiedFocusEvent() async {
    let client = StubFocusedElementClient(reads: [true, false])
    let focusEvents = StubFocusEventSource()
    let resolver = FocusedElementResolver(client: client, focusEvents: focusEvents)
    let process = AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: Date())
    let application = AXUIElementCreateApplication(getpid())
    focusEvents.emit(application: application, process: process)
    await resolver.waitForPendingFocus()

    let result = resolver.resolve(in: application, process: process)

    #expect(result != nil)
    #expect(client.enabledAttributes.isEmpty)
}

@MainActor
@Test
func focusEventPrimesTheMinimalAssistiveTreeBeforeTheTrigger() async {
    let client = StubFocusedElementClient(reads: [false, true, false])
    let focusEvents = StubFocusEventSource()
    let resolver = FocusedElementResolver(client: client, focusEvents: focusEvents)
    let process = AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: Date())
    let application = AXUIElementCreateApplication(getpid())
    focusEvents.emit(application: application, process: process)
    await resolver.waitForPendingFocus()

    let result = resolver.resolve(in: application, process: process)

    #expect(result != nil)
    #expect(client.enabledAttributes == [FocusedElementResolver.manualAccessibilityAttribute])
}

@MainActor
@Test
func focusedElementResolverRejectsAnObservedElementThatIsNoLongerFocused() async {
    let client = StubFocusedElementClient(
        reads: [true, false, false, false],
        focused: false
    )
    let focusEvents = StubFocusEventSource()
    let resolver = FocusedElementResolver(client: client, focusEvents: focusEvents)
    let process = AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: Date())
    let application = AXUIElementCreateApplication(getpid())
    focusEvents.emit(application: application, process: process)
    await resolver.waitForPendingFocus()

    let result = resolver.resolve(in: application, process: process)

    #expect(result == nil)
}

@MainActor
@Test
func focusedElementResolverUnlocksTheMinimalAssistiveTreeFirst() throws {
    let client = StubFocusedElementClient(reads: [false, true])
    let resolver = FocusedElementResolver(client: client)

    let result = resolver.resolve(
        in: AXUIElementCreateApplication(getpid()),
        process: AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: Date())
    )

    #expect(result != nil)
    #expect(client.enabledAttributes == [FocusedElementResolver.manualAccessibilityAttribute])
}

@MainActor
@Test
func focusedElementResolverEscalatesOnlyWhenMinimalEnablementIsInsufficient() throws {
    let client = StubFocusedElementClient(reads: [false, false, true])
    let resolver = FocusedElementResolver(client: client)

    let result = resolver.resolve(
        in: AXUIElementCreateApplication(getpid()),
        process: AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: Date())
    )

    #expect(result != nil)
    #expect(client.enabledAttributes == [
        FocusedElementResolver.manualAccessibilityAttribute,
        FocusedElementResolver.enhancedUserInterfaceAttribute
    ])
}

@MainActor
@Test
func focusedElementResolverDoesNotRepeatFailedEscalationForTheSameProcessLaunch() {
    let client = StubFocusedElementClient(reads: [false, false, false, false])
    let resolver = FocusedElementResolver(client: client)
    let process = AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: Date())
    let application = AXUIElementCreateApplication(getpid())

    #expect(resolver.resolve(in: application, process: process) == nil)
    #expect(resolver.resolve(in: application, process: process) == nil)
    #expect(client.enabledAttributes == [
        FocusedElementResolver.manualAccessibilityAttribute,
        FocusedElementResolver.enhancedUserInterfaceAttribute
    ])
}

@MainActor
private final class StubFocusedElementClient: FocusedElementClient {
    private var reads: [Bool]
    private var systemWideReads: [Bool]
    private let focusedElement = AXUIElementCreateSystemWide()
    private let systemWideProcessIdentifier: pid_t
    private let focused: Bool
    private(set) var enabledAttributes: [String] = []

    init(
        reads: [Bool],
        systemWideReads: [Bool] = [],
        systemWideProcessIdentifier: pid_t = getpid(),
        focused: Bool = true
    ) {
        self.reads = reads
        self.systemWideReads = systemWideReads
        self.systemWideProcessIdentifier = systemWideProcessIdentifier
        self.focused = focused
    }

    func focusedElement(in application: AXUIElement) -> AXUIElement? {
        guard !reads.isEmpty else { return nil }
        return reads.removeFirst() ? focusedElement : nil
    }

    func systemWideFocusedElement() -> AXUIElement? {
        guard !systemWideReads.isEmpty else { return nil }
        return systemWideReads.removeFirst() ? focusedElement : nil
    }

    func processIdentifier(of element: AXUIElement) -> pid_t? {
        systemWideProcessIdentifier
    }

    func isFocused(_ element: AXUIElement) -> Bool {
        focused
    }

    func enable(_ attribute: String, in application: AXUIElement) -> AXError {
        enabledAttributes.append(attribute)
        return .success
    }
}

@MainActor
private final class StubFocusEventSource: FocusEventSource {
    var onFocusEvent: ((AXUIElement, AccessibilityProcessIdentity) -> Void)?

    func start() {}

    func emit(application: AXUIElement, process: AccessibilityProcessIdentity) {
        onFocusEvent?(application, process)
    }
}


@MainActor @Test
func focusSignalBurstRemembersOnlyTheNewestProcessAndLaterSignalsStillRefresh() async {
    // FocusedElementClient is the external AX API boundary. Its sequence makes
    // an extra background resolution discard the only available focused element.
    let client = StubFocusedElementClient(reads: [true, false, true, false])
    let events = StubFocusEventSource()
    let resolver = FocusedElementResolver(client: client, focusEvents: events)
    let application = AXUIElementCreateApplication(getpid())
    let older = AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: .distantPast)
    let latest = AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: .now)
    events.emit(application: application, process: older)
    events.emit(application: application, process: latest)
    // A global input signal joins the same window as the AX events.
    await resolver.refreshObservedFocus(in: application, process: latest)
    #expect(resolver.resolve(in: application, process: latest) != nil)
    #expect(client.enabledAttributes.isEmpty)

    events.emit(application: application, process: older)
    await resolver.waitForPendingFocus()
    #expect(resolver.resolve(in: application, process: older) != nil)
    #expect(client.enabledAttributes.isEmpty)
}

@MainActor @Test
func triggerResolutionSupersedesQueuedFocusWithoutWaitingOrLosingItsResult() async {
    let client = StubFocusedElementClient(reads: [true, false])
    let events = StubFocusEventSource()
    let resolver = FocusedElementResolver(client: client, focusEvents: events)
    let application = AXUIElementCreateApplication(getpid())
    let older = AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: .distantPast)
    let current = AccessibilityProcessIdentity(processIdentifier: getpid(), launchDate: .now)
    events.emit(application: application, process: older)
    #expect(resolver.resolve(in: application, process: current) != nil)
    await resolver.waitForPendingFocus()
    #expect(resolver.resolve(in: application, process: current) != nil)
    #expect(client.enabledAttributes.isEmpty)
}
