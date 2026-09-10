import AppKit

let application = NSApplication.shared
#if DEBUG
if ProcessInfo.processInfo.arguments.contains("--verify-delivery") {
    let runner = DeliveryValidationRunner()
    application.delegate = runner
    withExtendedLifetime(runner) { application.run() }
} else {
    let controller = AppController()
    application.delegate = controller
    withExtendedLifetime(controller) { application.run() }
}
#else
let controller = AppController()
application.delegate = controller
application.run()
#endif
