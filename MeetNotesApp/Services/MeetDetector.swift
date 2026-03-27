import AppKit
import Observation

/// Detects active Google Meet sessions by querying browser tab URLs via AppleScript.
///
/// Polls every 3 seconds for meet.google.com URLs in supported browsers
/// (Chrome, Safari, Arc, Firefox). When auto-record is enabled and a Meet
/// session is detected, signals the caller to start/stop recording.
///
/// Requires Accessibility permission (NSAppleEventsUsageDescription in Info.plist).
@MainActor @Observable
final class MeetDetector {
    // MARK: - Published State

    /// Whether a Google Meet session is currently detected.
    private(set) var isDetected = false

    /// The detected Google Meet URL, if any.
    private(set) var detectedURL: String?

    /// Error from the last detection attempt (non-fatal).
    var error: String?

    // MARK: - Private

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 3.0

    // MARK: - Public API

    /// Start polling for Google Meet sessions.
    func startMonitoring() {
        guard pollTimer == nil else { return }
        error = nil

        // Run immediately, then every 3 seconds
        checkForMeet()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForMeet()
            }
        }
    }

    /// Stop polling.
    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Detection

    private func checkForMeet() {
        let browsers = detectRunningBrowsers()

        for browser in browsers {
            if let url = queryActiveTabURL(for: browser) {
                if url.contains("meet.google.com/") && !url.contains("meet.google.com/landing") {
                    if !isDetected {
                        isDetected = true
                        detectedURL = url
                    }
                    return
                }
            }
        }

        // No Meet URL found
        if isDetected {
            isDetected = false
            detectedURL = nil
        }
    }

    // MARK: - Browser Detection

    private enum Browser: String, CaseIterable {
        case chrome = "com.google.Chrome"
        case safari = "com.apple.Safari"
        case arc = "company.thebrowser.Browser"
        case firefox = "org.mozilla.firefox"

        var displayName: String {
            switch self {
            case .chrome: return "Google Chrome"
            case .safari: return "Safari"
            case .arc: return "Arc"
            case .firefox: return "Firefox"
            }
        }
    }

    private func detectRunningBrowsers() -> [Browser] {
        let runningApps = NSWorkspace.shared.runningApplications
        let runningBundleIDs = Set(runningApps.compactMap(\.bundleIdentifier))

        return Browser.allCases.filter { browser in
            runningBundleIDs.contains(browser.rawValue)
        }
    }

    // MARK: - AppleScript Tab Query

    private func queryActiveTabURL(for browser: Browser) -> String? {
        let script: String
        switch browser {
        case .chrome:
            script = """
            tell application "Google Chrome"
                if (count of windows) > 0 then
                    return URL of active tab of front window
                end if
            end tell
            """
        case .safari:
            script = """
            tell application "Safari"
                if (count of windows) > 0 then
                    return URL of current tab of front window
                end if
            end tell
            """
        case .arc:
            // Arc uses same AppleScript API as Chrome (Chromium-based)
            script = """
            tell application "Arc"
                if (count of windows) > 0 then
                    return URL of active tab of front window
                end if
            end tell
            """
        case .firefox:
            // Firefox has limited AppleScript support — try via accessibility
            // Fallback: check window title for "Meet" indicator
            script = """
            tell application "System Events"
                tell process "Firefox"
                    if (count of windows) > 0 then
                        return name of front window
                    end if
                end tell
            end tell
            """
        }

        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorInfo)

        if let errorInfo {
            // Silently ignore — browser may not be frontmost or may deny access
            _ = errorInfo
            return nil
        }

        guard let urlString = result?.stringValue, !urlString.isEmpty else {
            return nil
        }

        // Firefox returns window title, not URL — check for Meet indicators
        if browser == .firefox {
            if urlString.contains("Google Meet") || urlString.contains("meet.google.com") {
                return "meet.google.com/detected-via-title"
            }
            return nil
        }

        return urlString
    }
}
