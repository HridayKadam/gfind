import AppKit
import SwiftUI

@main
struct GFindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState.shared
    @StateObject private var library = Library.shared
    @StateObject private var text = TextIndex.shared
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        Window("GFind", id: "main") {
            MainView()
                .environmentObject(app).environmentObject(library).environmentObject(text)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { GFindCommands(app: app, library: library) }

        Settings {
            SettingsView().environmentObject(app).environmentObject(library).environmentObject(text)
        }

        MenuBarExtra("GFind", systemImage: "square.grid.2x2.fill", isInserted: $showMenuBar) {
            MenuBarView().environmentObject(app).environmentObject(library)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            HotKey.shared.action = { QuickSearch.shared.toggle() }
            let saved = QuickSearchShortcut(rawValue: UserDefaults.standard.string(forKey: "quickSearchShortcut") ?? "")
            HotKey.shared.register(saved ?? .shiftCmdSpace)
            Library.shared.refresh()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppState.shared.showMain() } }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            let lib = Library.shared
            if let last = lib.lastScan, Date.now.timeIntervalSince(last) > 120 { lib.refresh() }
        }
    }
}

struct GFindCommands: Commands {
    @ObservedObject var app: AppState
    @ObservedObject var library: Library

    var selectedItems: [FileItem] { app.selection.compactMap { library.item(at: $0) ?? Scanner.makeItem($0, nil, includeUncategorized: true) } }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Quick Search") { QuickSearch.shared.show() }
            Button("Rescan Library") { library.refresh() }.keyboardShortcut("r")
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Text from Images") { app.copyText(selectedItems) }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Move to Trash") {
                library.trash(Array(app.selection)); app.selection = []
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(app.selection.isEmpty)
        }
        CommandGroup(replacing: .textEditing) {
            Button("Search") { app.focusSearch += 1 }.keyboardShortcut("f")
        }
        CommandMenu("Go") {
            Button("Home") { app.go(.home) }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Recents") { app.go(.recents) }.keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Downloaded From") { app.go(.downloadedFrom(nil)) }.keyboardShortcut("j", modifiers: [.command, .shift])
            Button("Duplicates") { app.go(.duplicates) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Clean Up") { app.go(.cleanUp) }.keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("Show in Finder") { app.showInFinder(Array(app.selection)) }
                .keyboardShortcut("r", modifiers: [.command, .option]).disabled(app.selection.isEmpty)
        }
        CommandGroup(before: .toolbar) {
            Button("as Grid") { app.viewMode = .grid }.keyboardShortcut("1")
            Button("as List") { app.viewMode = .list }.keyboardShortcut("2")
            Divider()
            Button("Bigger Cards") { app.zoom(20) }.keyboardShortcut("+")
            Button("Smaller Cards") { app.zoom(-20) }.keyboardShortcut("-")
            Button("Switch Look") { app.toggleLook() }.keyboardShortcut("t", modifiers: [.command, .control])
            Button(app.showInspector ? "Hide Inspector" : "Show Inspector") { app.showInspector.toggle() }.keyboardShortcut("i")
            Divider()
        }
        CommandMenu("Music") {
            Button("Play / Pause") { Player.shared.toggle() }.keyboardShortcut("p", modifiers: [.command, .option])
            Button("Next Song") { Player.shared.skip(1) }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Song") { Player.shared.skip(-1) }.keyboardShortcut(.leftArrow, modifiers: .command)
        }
    }
}
