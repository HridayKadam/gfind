import AppKit
import ServiceManagement
import SwiftUI

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    static let repo = URL(string: "https://github.com/HridayKadam/gfind")!
    static let issues = URL(string: "https://github.com/HridayKadam/gfind/issues")!
}

/// Opens GFind when you log in, via the system's Login Items.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Launch at login failed: \(error.localizedDescription)")
            AppState.shared.toast("Couldn't change Launch at Login. Move GFind to Applications first.")
        }
    }
}

/// Checks GitHub Releases for a newer version. Sends nothing but the request itself.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    @Published private(set) var latest: (version: String, url: URL, notes: String)?
    @Published private(set) var checking = false
    @AppStorage("autoCheckUpdates") var autoCheck = true
    @AppStorage("lastUpdateCheck") private var lastCheck = 0.0

    func checkInBackground() {
        guard autoCheck, Date.now.timeIntervalSince1970 - lastCheck > 86_400 else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        checking = true; defer { checking = false }
        lastCheck = Date.now.timeIntervalSince1970
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/HridayKadam/gfind/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            if userInitiated { alert("Couldn't check for updates", "No published release was found, or you're offline.") }
            return
        }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }?["browser_download_url"] as? String
        let page = json["html_url"] as? String
        guard Self.isNewer(version, than: AppInfo.version), let link = URL(string: dmg ?? page ?? "") else {
            latest = nil
            if userInitiated { alert("You're up to date", "GFind \(AppInfo.version) is the latest version.") }
            return
        }
        latest = (version, link, json["body"] as? String ?? "")
        if userInitiated { promptToUpdate() } else { AppState.shared.toast("GFind \(version) is available. Help › Check for Updates…") }
    }

    func promptToUpdate() {
        guard let latest else { return }
        let a = NSAlert()
        a.messageText = "GFind \(latest.version) is available"
        a.informativeText = "You have \(AppInfo.version).\n\n" + String(latest.notes.prefix(600))
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(latest.url) }
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// Shown once on first launch: what GFind does and which permissions it will ask for.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading) {
                    Text("Welcome to GFind").font(.largeTitle.weight(.bold))
                    Text("Your files, big and easy to find. Plus a notch that does things.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                row("folder", "Folder access", "macOS will ask to let GFind see Desktop, Documents and Downloads. Allow these so GFind can show and search your files.")
                row("lock.shield", "Stays on your Mac", "Text recognition, duplicates, clipboard history and screen time are processed and kept on this Mac. Nothing is uploaded.")
                row("trash", "Nothing is deleted outright", "Clean Up and Duplicates only move files to the Trash, so you can always put them back.")
                row("magnifyingglass", "Search from anywhere", "Press ⇧⌘Space in any app for Quick Search. Hover the notch at the top of the screen for its tools.")
            }
            Toggle("Open GFind when I log in", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { LaunchAtLogin.set(launchAtLogin) }
            HStack {
                Spacer()
                Button("Get Started") {
                    let firstRun = !hasOnboarded
                    hasOnboarded = true
                    dismiss()
                    if firstRun { Library.shared.start() }
                }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 580, height: 560, alignment: .top)
    }

    private func row(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Apps whose copies are never saved to clipboard history.
enum ClipboardPrivacy {
    static let defaultIgnored = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
    ]

    static var ignored: [String] {
        get { UserDefaults.standard.stringArray(forKey: "clipboardIgnored") ?? defaultIgnored }
        set { UserDefaults.standard.set(newValue, forKey: "clipboardIgnored") }
    }

    static var paused: Bool { UserDefaults.standard.bool(forKey: "clipboardPaused") }

    static func shouldRecord(from app: NSRunningApplication?) -> Bool {
        guard !paused else { return false }
        guard let id = app?.bundleIdentifier else { return true }
        return !ignored.contains(id)
    }
}
