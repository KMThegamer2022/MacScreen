import Foundation
import AppKit
import CryptoKit

struct ReleaseInfo: Equatable {
    let tag: String           // e.g. "v1.0.1"
    let version: String       // e.g. "1.0.1"
    let pageURL: URL
    let zipURL: URL
    let sumsURL: URL?
}

/// Checks GitHub Releases for a newer version and installs it in place.
final class Updater: ObservableObject {
    enum State: Equatable { case idle, downloading, verifying, installing, failed(String) }

    static let repo = "KMThegamer2022/MacScreen"
    private static let dismissedKey = "dismissedUpdateVersion"

    @Published var available: ReleaseInfo?
    @Published var state: State = .idle
    @Published var checking = false
    @Published var upToDateNote = ""

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// Test hook: only local servers may override the update source.
    private var apiURL: URL {
        if let o = ProcessInfo.processInfo.environment["MACSCREEN_UPDATE_API"],
           o.hasPrefix("http://127.0.0.1") || o.hasPrefix("http://localhost"), let u = URL(string: o) { return u }
        return URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
    }

    private var webBase: String {
        if let o = ProcessInfo.processInfo.environment["MACSCREEN_UPDATE_WEB"],
           o.hasPrefix("http://127.0.0.1") || o.hasPrefix("http://localhost") { return o }
        return "https://github.com/\(Self.repo)"
    }

    // MARK: version compare

    static func parse(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parse(a), y = parse(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: check

    /// `manual`: user pressed "Check for updates" — ignore an earlier dismissal and report "up to date".
    @MainActor func check(manual: Bool = false) async {
        guard !checking, state == .idle || { if case .failed = state { return true }; return false }() else { return }
        checking = true; upToDateNote = ""
        defer { checking = false }
        guard let rel = await fetchLatest() else {
            if manual { upToDateNote = "Couldn't reach GitHub." }
            return
        }
        guard Self.isNewer(rel.tag, than: currentVersion) else {
            available = nil
            if manual { upToDateNote = "You're up to date (version \(currentVersion))." }
            return
        }
        if !manual, UserDefaults.standard.string(forKey: Self.dismissedKey) == rel.tag { return }
        available = rel
        log("update available: \(rel.tag) (running \(currentVersion))")
    }

    /// Latest release: GitHub API first, then a non-API fallback (the rate-limit-free /releases/latest redirect).
    private func fetchLatest() async -> ReleaseInfo? {
        if let r = await latestViaAPI() { return r }
        log("update check: API unavailable or rate-limited, using fallback")
        return await latestViaRedirect()
    }

    private func latestViaAPI() async -> ReleaseInfo? {
        var req = URLRequest(url: apiURL, timeoutInterval: 8)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacScreen-Updater", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,       // 403/429 = rate limited
                  let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = j["tag_name"] as? String,
                  (j["draft"] as? Bool) != true, (j["prerelease"] as? Bool) != true else { return nil }
            let assets = (j["assets"] as? [[String: Any]]) ?? []
            func asset(_ name: String) -> URL? {
                assets.first { ($0["name"] as? String) == name }
                    .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init) }
            }
            guard let zip = asset("MacScreen.zip") else { return nil }
            let page = (j["html_url"] as? String).flatMap(URL.init) ?? URL(string: "\(webBase)/releases")!
            return ReleaseInfo(tag: tag, version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                               pageURL: page, zipURL: zip, sumsURL: asset("SHA256SUMS.txt"))
        } catch { return nil }
    }

    /// github.com/<repo>/releases/latest answers with a redirect to /releases/tag/<tag>; no API involved.
    private func latestViaRedirect() async -> ReleaseInfo? {
        guard let url = URL(string: "\(webBase)/releases/latest") else { return nil }
        let catcher = RedirectCatcher()
        let session = URLSession(configuration: .ephemeral, delegate: catcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "HEAD"
        req.setValue("MacScreen-Updater", forHTTPHeaderField: "User-Agent")
        do {
            let (_, resp) = try await session.data(for: req)
            guard let h = resp as? HTTPURLResponse, (300..<400).contains(h.statusCode),
                  let loc = h.value(forHTTPHeaderField: "Location"),
                  let target = URL(string: loc, relativeTo: url)?.absoluteURL,
                  target.pathComponents.contains("tag") else { return nil }
            let tag = target.lastPathComponent
            guard !tag.isEmpty, Self.parse(tag).contains(where: { $0 > 0 }) else { return nil }
            let base = "\(webBase)/releases/download/\(tag)"
            return ReleaseInfo(tag: tag, version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                               pageURL: target, zipURL: URL(string: "\(base)/MacScreen.zip")!,
                               sumsURL: URL(string: "\(base)/SHA256SUMS.txt"))
        } catch { return nil }
    }

    /// Hide this version until a newer one is released.
    @MainActor func dismiss() {
        if let a = available { UserDefaults.standard.set(a.tag, forKey: Self.dismissedKey) }
        available = nil
        state = .idle
    }

    // MARK: install

    @MainActor func install() async {
        guard let rel = available, state == .idle || { if case .failed = state { return true }; return false }() else { return }
        do {
            state = .downloading
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("MacScreenUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zipFile = work.appendingPathComponent("MacScreen.zip")
            let (tmp, resp) = try await URLSession.shared.download(from: rel.zipURL)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed") }
            try FileManager.default.moveItem(at: tmp, to: zipFile)

            state = .verifying
            // 1. checksum from the release's SHA256SUMS.txt
            guard let sumsURL = rel.sumsURL else { throw UpdateError("Release has no checksum file") }
            let (sums, _) = try await URLSession.shared.data(from: sumsURL)
            let expected = String(decoding: sums, as: UTF8.self).split(separator: "\n")
                .first { $0.hasSuffix("MacScreen.zip") }?.split(separator: " ").first.map(String.init)
            let actual = SHA256.hash(data: try Data(contentsOf: zipFile)).map { String(format: "%02x", $0) }.joined()
            guard let expected, expected.lowercased() == actual else { throw UpdateError("Checksum mismatch — update not installed") }

            // 2. unpack and sanity-check the app
            let x = work.appendingPathComponent("x")
            try run("/usr/bin/ditto", ["-x", "-k", zipFile.path, x.path])
            let newApp = x.appendingPathComponent("MacScreen.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError("Update didn't contain MacScreen.app") }
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
            let plist = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
            guard (plist?["CFBundleIdentifier"] as? String) == Bundle.main.bundleIdentifier else {
                throw UpdateError("Update is for a different app")
            }

            // 3. swap after we quit, then relaunch
            state = .installing
            let dest = Bundle.main.bundlePath
            let parent = (dest as NSString).deletingLastPathComponent
            guard FileManager.default.isWritableFile(atPath: parent) else {
                throw UpdateError("Can't write to \(parent). Install the update manually.")
            }
            let script = work.appendingPathComponent("swap.sh")
            try """
            #!/bin/bash
            PID="$1"; NEW="$2"; DEST="$3"
            while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
            rm -rf "$DEST.old"
            if mv "$DEST" "$DEST.old" && ditto "$NEW" "$DEST"; then
              xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
              rm -rf "$DEST.old"
            else
              rm -rf "$DEST"; mv "$DEST.old" "$DEST"
            fi
            open "$DEST"
            rm -rf "\(work.path)"
            """.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "nohup /bin/bash \"$0\" \"$@\" >/dev/null 2>&1 &", script.path,
                           String(ProcessInfo.processInfo.processIdentifier), newApp.path, dest]
            try p.run()
            log("installing update \(rel.tag) over \(dest)")
            try? await Task.sleep(nanoseconds: 400_000_000)
            NSApp.terminate(nil)
        } catch {
            let msg = (error as? UpdateError)?.message ?? error.localizedDescription
            log("update failed: \(msg)")
            state = .failed(msg)
        }
    }

    struct UpdateError: Error { let message: String; init(_ m: String) { message = m } }

    private func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError("\((exe as NSString).lastPathComponent) failed") }
    }
}

/// Stops URLSession from following redirects so we can read the Location header.
private final class RedirectCatcher: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
