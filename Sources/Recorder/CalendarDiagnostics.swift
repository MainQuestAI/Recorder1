import AppKit
import EventKit
import Foundation

/// Runs with the app bundle's signing identity and privacy usage declaration.
enum CalendarDiagnostics {
    @MainActor static func runAndExit() -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            let access = CalendarAccess()
            let snapshot = await access.load(now: Date(), requestAccess: true)
            let data: [String: Any] = ["ok": snapshot.state == .ready,
                "state": String(describing: snapshot.state), "meeting_count": snapshot.meetings.count,
                "has_current_meeting": snapshot.currentMeeting != nil,
                "authorization": EKEventStore.authorizationStatus(for: .event).rawValue]
            do {
                let json = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: json, as: UTF8.self))
                let args = CommandLine.arguments
                if let index = args.firstIndex(of: "--diagnose-output"), args.indices.contains(index + 1) {
                    try json.write(to: URL(fileURLWithPath: args[index + 1]))
                }
            } catch { fputs("FAIL \(error)\n", stderr); exit(1) }
            exit(snapshot.state == .ready ? 0 : 1)
        }
        NSApp.run()
        exit(1)
    }
}
