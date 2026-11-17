import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var s: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "display.2").font(.title)
                VStack(alignment: .leading) {
                    Text("MacScreen").font(.title2.bold())
                    Text(s.status).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(s.running ? "Stop" : (s.starting ? "Starting…" : "Start")) {
                    s.running ? s.stop() : s.start()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(s.starting)
                .controlSize(.large)
            }

            GroupBox("Second screen") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(s.settings.matchReceiver ? "Max resolution" : "Resolution", selection: Binding(
                        get: { "\(s.settings.width)x\(s.settings.height)" },
                        set: { v in
                            let p = v.split(separator: "x").compactMap { Int($0) }
                            if p.count == 2 { s.settings.width = p[0]; s.settings.height = p[1] }
                        })) {
                        Text("1280 × 720").tag("1280x720")
                        Text("1366 × 768 (typical Chromebook)").tag("1366x768")
                        Text("1600 × 900").tag("1600x900")
                        Text("1920 × 1080").tag("1920x1080")
                        Text("1920 × 1200").tag("1920x1200")
                        Text("2560 × 1440").tag("2560x1440")
                    }
                    Picker("Frame rate", selection: $s.settings.fps) {
                        Text("30 fps").tag(30); Text("60 fps").tag(60)
                    }.pickerStyle(.segmented)
                    HStack {
                        Text("Quality  \(s.settings.bitrateMbps) Mbps")
                        Slider(value: Binding(get: { Double(s.settings.bitrateMbps) },
                                              set: { s.settings.bitrateMbps = Int($0) }), in: 2...50, step: 1)
                    }
                    Toggle("Match the Chromebook's screen shape automatically", isOn: $s.settings.matchReceiver)
                    Toggle("Retina (HiDPI) — sharper, uses more power", isOn: $s.settings.hiDPI)
                    Text(s.running ? "Max resolution / Retina changes apply next time you press Start." : "")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }.disabled(s.starting)

            GroupBox("Startup") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Launch MacScreen when I log in", isOn: Binding(
                        get: { s.launchAtLogin }, set: { s.setLaunchAtLogin($0) }))
                    Toggle("Start the second screen automatically", isOn: $s.settings.autoStartServer)
                        .disabled(!s.launchAtLogin)
                        .padding(.leading, 18)
                    if !s.launchAtLogin {
                        Text("Turn on “Launch at login” to enable this.").font(.caption).foregroundStyle(.secondary).padding(.leading, 18)
                    }
                    if !s.loginNote.isEmpty { Text(s.loginNote).font(.caption).foregroundStyle(.orange) }
                }.padding(6)
            }

            if s.running {
                GroupBox("Open this on the Chromebook (Chrome)") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(s.addresses) { a in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(a.url).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    Text(a.label).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(a.url, forType: .string)
                                }
                            }
                        }
                        Divider()
                        ForEach(s.slotInfos) { d in
                            Text("Screen \(d.id) — \(d.width) × \(d.height) — \(d.clients) receiver\(d.clients == 1 ? "" : "s")")
                                .font(.callout)
                        }
                        if s.slotInfos.isEmpty { Text("No receivers yet — open a URL above on a device.").font(.callout).foregroundStyle(.secondary) }
                        Text("Each new device gets its own virtual display. Add ?screen=1 to the URL to share one.").font(.caption).foregroundStyle(.secondary)
                        Text("Receivers: \(s.clients)   ·   frames/s: \(s.fpsOut)").font(.callout)
                    }.padding(6)
                }
            }

            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 6) {
                    permRow("Screen Recording (to capture the second screen)", ok: s.screenOK,
                            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                    permRow("Accessibility (so Chromebook touch can control the Mac)", ok: s.accessOK,
                            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    Button("Re-check") { s.refreshPermissions() }.controlSize(.small)
                }.padding(6)
            }
            Spacer(minLength: 0)
            HStack {
                Text("Closing this window keeps streaming in the background.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit MacScreen") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(18)
        .frame(width: 520, height: s.running ? 780 : 660)
        .onAppear { s.refreshLoginItem() }
    }

    func permRow(_ t: String, ok: Bool, url: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(t).font(.callout)
            Spacer()
            if !ok { Button("Open Settings") { NSWorkspace.shared.open(URL(string: url)!) }.controlSize(.small) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = Session()
    var window: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let sub = NSMenu()
        sub.addItem(withTitle: "Quit MacScreen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = sub
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MacScreen"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(s: session))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        session.refreshLoginItem()
        if CommandLine.arguments.contains("--autostart") || session.shouldAutoStart { session.start() }
    }

    // Red button only hides the window; streaming continues. Quit button / Cmd+Q really quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    // Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
    func applicationWillTerminate(_ n: Notification) { session.server.stop() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
