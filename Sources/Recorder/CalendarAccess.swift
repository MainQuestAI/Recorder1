import Foundation
import EventKit

/// EventKit access wrapper.
///
/// Owns a single, long-lived `EKEventStore` (releasing it would invalidate every
/// `EKEvent`/`EKCalendar` it vended) and exposes a small, UI-friendly surface:
/// permission, a "meetings around now" window, and a best-guess "current meeting"
/// used to name recording folders.
///
/// The whole type is `@MainActor`: all reads happen on the main thread, and the
/// `.EKEventStoreChanged` observer hops back to main before invoking `onChange`.
@MainActor
final class CalendarAccess {

    /// Wired by the model to `.EKEventStoreChanged`. Invoked on MAIN whenever
    /// calendar data changes anywhere on the system (so cached events may be stale).
    var onChange: (() -> Void)?

    /// One store for the app's lifetime — see note above.
    private let store = EKEventStore()

    /// Observer token for `.EKEventStoreChanged`; removed on deinit.
    private var changeObserver: NSObjectProtocol?

    // Window around "now" used for fetching (research-notes: eventkit-calendar §2).
    private let windowBack: TimeInterval = -2 * 3600   // 2 hours behind
    private let windowForward: TimeInterval = 8 * 3600 // 8 hours ahead

    init() {
        // Re-fetch whenever the system reports a calendar change. Observe on the
        // main queue; the closure isn't @MainActor-isolated, so hop explicitly
        // before touching our (main-actor) callback.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            // Already on the main queue, but assert MainActor isolation for Swift's
            // concurrency checker and to be safe if the queue assumption ever changes.
            Task { @MainActor [weak self] in
                self?.onChange?()
            }
        }
    }

    deinit {
        if let token = changeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Authorization

    /// Requests full calendar access (write-only cannot read existing events).
    /// Switches on the `EKAuthorizationStatus` CASE — never the raw value, because
    /// `.authorized` and `.fullAccess` collide on raw value 3.
    func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                return false
            }
        case .writeOnly, .denied, .restricted, .authorized:
            // .writeOnly can't read; the rest require a Settings change by the user.
            // (.authorized is the deprecated legacy alias; treat it as no read grant
            //  under the new model and fall through to a fresh request path is N/A
            //  here since it implies a prior legacy grant — return false to be safe.)
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Fetching

    /// Timed meetings overlapping a (now-2h .. now+8h) window, across all calendars.
    /// Drops all-day and empty-title events, sorts by start, dedups by
    /// `eventIdentifier`, and returns roughly the last 2 + current + next 2.
    func meetingsAroundNow(_ now: Date) -> [Meeting] {
        let start = now.addingTimeInterval(windowBack)
        let end = now.addingTimeInterval(windowForward)

        // nil = all calendars. The predicate matches any event OVERLAPPING the window.
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        // events(matching:) is synchronous and returns events in no guaranteed order.
        let events = store.events(matching: predicate)

        var seen = Set<String>()
        let meetings: [Meeting] = events
            .filter { !$0.isAllDay }                       // drop all-day
            .filter { ($0.title?.isEmpty == false) }       // drop untitled
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .compactMap { ev -> Meeting? in
                guard let s = ev.startDate, let e = ev.endDate else { return nil }
                // Dedup on the real event identifier (recurring/synced calendars can
                // surface duplicates). Fall back to title+start when none is present.
                let dedupKey = ev.eventIdentifier
                    ?? "\(ev.title ?? "")|\(s.timeIntervalSince1970)"
                guard seen.insert(dedupKey).inserted else { return nil }

                let id = ev.eventIdentifier ?? UUID().uuidString
                return Meeting(id: id, title: ev.title ?? "Untitled", start: s, end: e,
                               attendees: self.attendeeNames(ev))
            }

        return trimmedAroundNow(meetings, now: now)
    }

    /// The meeting "happening now or most recently started" — the best default for
    /// naming a recording folder: in-progress, else most-recently-started, else the
    /// next upcoming.
    func currentMeeting(_ now: Date) -> Meeting? {
        // Fetch the full (untrimmed) sorted set so the choice isn't skewed by trimming.
        let all = sortedMeetings(now: now)
        return all.last(where: { $0.isInProgress(now) })   // in progress
            ?? all.last(where: { $0.start <= now })         // most recently started
            ?? all.first                                    // else next upcoming
    }

    // MARK: - Helpers

    /// Best-effort display names of the organizer + invitees, for transcription
    /// context only. Falls back to the email local-part when a participant has no
    /// display name; dedups case-insensitively and caps the list.
    private func attendeeNames(_ ev: EKEvent) -> [String] {
        var names: [String] = []
        if let organizer = ev.organizer, let name = displayName(organizer) {
            names.append(name)
        }
        for participant in ev.attendees ?? [] {
            if let name = displayName(participant) {
                names.append(name)
            }
        }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0.lowercased()).inserted }
        return Array(unique.prefix(25))
    }

    /// A participant's display name, or its email local-part, or nil.
    private func displayName(_ participant: EKParticipant) -> String? {
        if let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let urlString = participant.url.absoluteString
        if urlString.lowercased().hasPrefix("mailto:") {
            let email = String(urlString.dropFirst("mailto:".count))
            if !email.isEmpty { return email }
        }
        return nil
    }

    /// Full window of qualifying meetings, sorted by start, deduped — without the
    /// last2/current/next2 trim. Used by `currentMeeting`.
    private func sortedMeetings(now: Date) -> [Meeting] {
        let start = now.addingTimeInterval(windowBack)
        let end = now.addingTimeInterval(windowForward)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        var seen = Set<String>()
        return events
            .filter { !$0.isAllDay }
            .filter { ($0.title?.isEmpty == false) }
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .compactMap { ev -> Meeting? in
                guard let s = ev.startDate, let e = ev.endDate else { return nil }
                let dedupKey = ev.eventIdentifier
                    ?? "\(ev.title ?? "")|\(s.timeIntervalSince1970)"
                guard seen.insert(dedupKey).inserted else { return nil }
                let id = ev.eventIdentifier ?? UUID().uuidString
                return Meeting(id: id, title: ev.title ?? "Untitled", start: s, end: e,
                               attendees: self.attendeeNames(ev))
            }
    }

    /// From a start-sorted list, keep ~the last 2 finished/started + the in-progress
    /// one + the next 2 upcoming, so the UI shows a focused slice around "now".
    private func trimmedAroundNow(_ meetings: [Meeting], now: Date) -> [Meeting] {
        guard !meetings.isEmpty else { return [] }

        // Partition by relationship to "now".
        let past = meetings.filter { $0.end < now }                       // already finished
        let current = meetings.filter { $0.isInProgress(now) }            // happening now
        let upcoming = meetings.filter { $0.start > now && $0.end >= now } // not yet started

        let lastTwoPast = Array(past.suffix(2))
        let nextTwoUpcoming = Array(upcoming.prefix(2))

        // Reassemble in chronological order and dedup defensively (a meeting could,
        // in edge cases, satisfy more than one partition due to boundary equality).
        var seen = Set<String>()
        let combined = (lastTwoPast + current + nextTwoUpcoming).filter { seen.insert($0.id).inserted }
        return combined.sorted { $0.start < $1.start }
    }
}
