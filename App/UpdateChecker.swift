import AppKit
import Combine

/// Checks GitHub for a newer Zoomie Toolz release and offers the download.
///
/// The only thing sent is one request for the public "latest release" info
/// on GitHub; nothing about you or your Mac. Updates are never installed by
/// themselves: you get the new DMG and drag it to Applications as usual.
final class UpdateChecker: ObservableObject {
    static let repo = "TechnAudioToolz/zoomie-toolz"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedVersionKey = "skippedUpdateVersion"

    /// Check at launch, at most once a day.
    @Published var checkAutomatically = UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(checkAutomatically, forKey: "checkForUpdates") }
    }
    @Published private(set) var status: String?
    @Published private(set) var isChecking = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    struct Release {
        let version: String
        let pageURL: URL
        let dmgURL: URL?
        let notes: String
    }

    /// Launch-time check: quiet unless there's an update you haven't skipped.
    func checkAtLaunchIfDue() {
        guard checkAutomatically else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 60 * 60 else { return }
        check(manual: false)
    }

    /// - Parameter manual: true when the user asked; also reports "up to date" and errors.
    func check(manual: Bool) {
        guard !isChecking else { return }
        isChecking = true
        status = "Checking…"
        Task {
            let result: Result<Release, Error>
            do { result = .success(try await Self.fetchLatest()) } catch { result = .failure(error) }
            await MainActor.run { self.finish(result, manual: manual) }
        }
    }

    private func finish(_ result: Result<Release, Error>, manual: Bool) {
        isChecking = false
        switch result {
        case .failure(let error):
            status = "Couldn't check for updates"
            if manual { showError(error) }
        case .success(let release):
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            let current = Self.currentVersion
            guard Self.isVersion(release.version, newerThan: current) else {
                status = "Up to date (\(current))"
                if manual { showUpToDate(current) }
                return
            }
            status = "Version \(release.version) is available"
            let skipped = UserDefaults.standard.string(forKey: Self.skippedVersionKey)
            if manual || skipped != release.version { showUpdate(release, current: current) }
        }
    }

    // MARK: GitHub

    static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Zoomie-Toolz/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let html_url: URL
            let body: String?
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        let dmg = payload.assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browser_download_url
        return Release(version: version, pageURL: payload.html_url, dmgURL: dmg, notes: payload.body ?? "")
    }

    /// Compares dotted version numbers: "1.10" is newer than "1.9", "1.1.1" than "1.1".
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Popups

    private func showUpdate(_ release: Release, current: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Zoomie Toolz \(release.version) is available"
        alert.informativeText = "You have \(current).\n\n" + Self.summary(of: release.notes)
            + "\n\nDownload the new DMG, quit Zoomie Toolz, and drag the new version to Applications."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.dmgURL ?? release.pageURL)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: Self.skippedVersionKey)
        default:
            break
        }
    }

    private func showUpToDate(_ current: String) {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Zoomie Toolz \(current) is the latest version."
        alert.runModal()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = "GitHub couldn't be reached (\(error.localizedDescription)). Check your internet connection, or see github.com/\(Self.repo)/releases."
        alert.addButton(withTitle: "Open Releases Page")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/\(Self.repo)/releases")!)
        }
    }

    /// The "New in …" bullets from the release notes, without Markdown clutter.
    static func summary(of notes: String) -> String {
        let lines = notes.components(separatedBy: .newlines)
        var picked: [String] = []
        var inNewSection = false
        for line in lines {
            if line.hasPrefix("## ") {
                if inNewSection { break }
                inNewSection = line.lowercased().contains("new in")
                continue
            }
            if inNewSection, line.hasPrefix("- ") {
                var text = line.dropFirst(2).replacingOccurrences(of: "**", with: "")
                if text.count > 140 { text = text.prefix(137).trimmingCharacters(in: .whitespaces) + "…" }
                picked.append("• " + text)
            }
        }
        return picked.prefix(5).joined(separator: "\n")
    }
}
