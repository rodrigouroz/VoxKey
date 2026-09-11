import AppKit
import Testing
import VoxKeyCore
@testable import VoxKeyApp

@MainActor @Test
func settingsOffersPersistentNativePaneNavigation() throws {
    _ = NSApplication.shared
    let settings = SettingsWindowController()
    let toolbar = try #require(settings.window?.toolbar)
    #expect(!toolbar.allowsUserCustomization)
    #expect(toolbar.isVisible)
    #expect(toolbar.items.map(\.label) == ["General", "Dictation", "Models & Languages"])
    #expect(toolbar.selectedItemIdentifier == settings.selectedPane.identifier)
    #expect(settings.window?.styleMask.contains(.miniaturizable) == false)
    #expect(settings.window?.styleMask.contains(.resizable) == false)
}

@MainActor @Test
func nativeToolbarChangesPanesInTheSameWindowAndRestoresTheLastSelection() throws {
    _ = NSApplication.shared
    let suite = "VoxKey.SettingsNavigationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = SettingsWindowController(defaults: defaults)
    let window = try #require(settings.window)
    let toolbar = try #require(window.toolbar)
    let top = window.frame.maxY
    let models = try #require(toolbar.items.first { $0.itemIdentifier == SettingsWindowController.Pane.models.identifier })
    #expect(NSApp.sendAction(try #require(models.action), to: models.target, from: models))
    #expect(settings.selectedPane == .models)
    #expect(window.title == "Models & Languages")
    #expect(toolbar.selectedItemIdentifier == models.itemIdentifier)
    #expect(settings.models.view.window === window)
    #expect(settings.triggerPopup.window == nil)
    #expect(abs(window.frame.maxY - top) < 1)
    let reopened = SettingsWindowController(defaults: defaults)
    #expect(reopened.selectedPane == .models)
    #expect(reopened.window?.title == "Models & Languages")

    // Changing panes keeps the live model controls and their in-progress state.
    let card = try #require(settings.models.cards.first { $0.model == .turboCompressed })
    settings.selectPane(.general)
    settings.models.update(active: .init(), ready: false, installed: [], busy: false,
                           downloading: .turboCompressed, downloadProgress: 0.42, downloadElapsed: 75)
    #expect(card.window == nil)
    settings.selectPane(.models)
    #expect(settings.window === window)
    #expect(card.window === window)
    #expect(card.progress.doubleValue == 0.42)
    #expect(!card.progress.isHidden)
    settings.selectPane(.dictation)
    #expect(settings.triggerPopup.window === window)
    #expect(settings.models.view.window == nil)
}

@MainActor @Test
func settingsAndModelMenuCommandsShareOneSettingsWindow() throws {
    _ = NSApplication.shared
    let previousMenu = NSApp.mainMenu
    defer { NSApp.mainMenu = previousMenu }
    let suite = "VoxKey.SettingsMenuTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let app = AppController(defaults: defaults)
    defer { app.settings.close() }
    let window = try #require(app.settings.window)
    app.configureApplicationMenu()
    let appMenu = try #require(NSApp.mainMenu?.items.first?.submenu)
    let settingsCommand = try #require(appMenu.items.first { $0.title == "Settings…" })
    #expect(settingsCommand.keyEquivalent == ",")
    #expect(settingsCommand.target === app)
    let statusMenu = NSMenu()
    app.rebuildMenu(statusMenu, snapshot: .init(phase: .ready, lastResult: nil))
    let modelCommand = try #require(statusMenu.items.first { $0.title == "Models and Languages…" })
    #expect(modelCommand.target === app)
    #expect(NSApp.sendAction(try #require(modelCommand.action), to: modelCommand.target, from: modelCommand))
    #expect(app.settings.selectedPane == .models)
    #expect(app.settings.models.view.window === window)
    #expect(NSApp.sendAction(try #require(settingsCommand.action), to: settingsCommand.target, from: settingsCommand))
    #expect(app.settings.window === window)
    #expect(app.settings.selectedPane == .models)
}

@MainActor @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func settingsPanesFitTheirContentInBothAppearances(_ appearance: NSAppearance.Name) throws {
    _ = NSApplication.shared
    let previousAppearance = NSApp.appearance
    NSApp.appearance = NSAppearance(named: appearance)
    defer { NSApp.appearance = previousAppearance }
    let settings = SettingsWindowController(grammarAvailable: true)
    let window = try #require(settings.window)
    window.appearance = NSAppearance(named: appearance)
    settings.updateGrammarCorrection(enabled: true, state: .downloadRequired)
    settings.models.update(active: .init(model: .turboCompressed, language: "es"), ready: true,
                           installed: [.distilCompressed, .turboCompressed], busy: false)
    for pane in SettingsWindowController.Pane.allCases {
        settings.selectPane(pane)
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        func check(_ view: NSView) {
            if view is NSControl, !view.isHiddenOrHasHiddenAncestor {
                #expect(root.bounds.insetBy(dx: -1, dy: -1).contains(root.convert(view.bounds, from: view)))
            }
            view.subviews.forEach(check)
        }
        check(root)
        if let directory = ProcessInfo.processInfo.environment["VOXKEY_SETTINGS_PREVIEW_DIR"] {
            let frame = try #require(root.superview)
            frame.layoutSubtreeIfNeeded()
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
            }
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("pane-\(pane.rawValue)-\(appearance.rawValue).png"))
        }
    }
}
