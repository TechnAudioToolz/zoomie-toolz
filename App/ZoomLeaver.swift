import AppKit
import Combine

/// Force-quits Zoom at a scheduled time, which drops you out of whatever
/// meeting you're in. Uses NSRunningApplication, so no special permissions
/// are needed, and force-quitting skips Zoom's "leave meeting?" prompt.
final class ZoomLeaver: ObservableObject {
    static let zoomBundleID = "us.zoom.xos"

    @Published private(set) var scheduledTime: Date?
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var lastResult: String?

    private var timer: Timer?

    func schedule(at time: Date) {
        // A time-of-day that's already passed means "tomorrow".
        var target = time
        while target <= Date() { target = target.addingTimeInterval(24 * 60 * 60) }
        scheduledTime = target
        lastResult = nil
        startTimer()
    }

    func schedule(inMinutes minutes: Int) {
        schedule(at: Date().addingTimeInterval(TimeInterval(minutes * 60)))
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        scheduledTime = nil
        remaining = 0
    }

    func leaveNow() {
        cancel()
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.zoomBundleID)
        guard !apps.isEmpty else {
            lastResult = "Zoom wasn't running"
            return
        }
        apps.forEach { $0.forceTerminate() }
        lastResult = "Quit Zoom at \(Date().formatted(date: .omitted, time: .shortened))"
    }

    private func startTimer() {
        timer?.invalidate()
        // Poll once a second instead of one long timer so sleep/wake can't
        // make us miss the deadline.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    private func check() {
        guard let scheduledTime else { return }
        remaining = scheduledTime.timeIntervalSinceNow
        if remaining <= 0 { leaveNow() }
    }
}
