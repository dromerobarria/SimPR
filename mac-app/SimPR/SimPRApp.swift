import AppKit
import SimPRCore
import SwiftUI

@main
struct SimPRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(appDelegate.model)
        } label: {
            Image(systemName: appDelegate.model.runState == nil ? "iphone" : "iphone.radiowaves.left.and.right")
                .accessibilityLabel("SimPR")
        }
        .menuBarExtraStyle(.menu)

        Window("SimPR Library", id: WindowID.library) {
            LibraryView()
                .environment(appDelegate.model)
                .frame(minWidth: 720, minHeight: 440)
        }
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

enum WindowID {
    static let library = "library"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var runPanel: RunPanelController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register before launch finishes so the URL that launched the app isn't missed.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        runPanel = RunPanelController(model: model)
        #if DEBUG
        // Test hooks: `-SimPRImport /path/build.zip` imports a build, `-SimPROpenURL simpr://…` opens a link.
        if let path = UserDefaults.standard.string(forKey: "SimPRImport") {
            model.importBuild(from: URL(fileURLWithPath: path))
        }
        if let link = UserDefaults.standard.string(forKey: "SimPROpenURL"), let url = URL(string: link) {
            model.handle(url: url)
        }
        #endif
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        model.handle(url: url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL, url.pathExtension.lowercased() == "zip" {
                model.importBuild(from: url)
            } else if url.scheme == RunRequest.scheme {
                model.handle(url: url)
            }
        }
    }
}
