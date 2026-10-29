import Foundation
import EventKit
import os

enum CalendarLoadState: Equatable {
    case loading, ready, accessRequired, denied, restricted
    case failed(String)
}

struct CalendarSnapshot {
    var state: CalendarLoadState
    var meetings: [Meeting] = []
    var currentMeeting: Meeting?
}

/// One permission-gated query supplies both the nearby list and recording title.
@MainActor
final class CalendarAccess {
    var onChange: (() -> Void)?
    private let store: EKEventStore
    private let authorization: () -> EKAuthorizationStatus
    private let request: () async throws -> Bool
    private let fetch: (Date, Date) -> [Meeting]
    private var changeObserver: NSObjectProtocol?
    private static let log = Logger(subsystem: "com.dingcheng.Recorder1", category: "Calendar")

    init(store: EKEventStore = EKEventStore(),
         authorization: @escaping () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) },
         request: (() async throws -> Bool)? = nil,
         fetch: ((Date, Date) -> [Meeting])? = nil) {
        self.store = store
        self.authorization = authorization
        self.request = request ?? { try await store.requestFullAccessToEvents() }
        self.fetch = fetch ?? { start, end in
            store.refreshSourcesIfNecessary()
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            return store.events(matching: predicate).compactMap { event in
                guard !event.isAllDay, let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty, let start = event.startDate, let end = event.endDate else { return nil }
                let participants = [event.organizer].compactMap { $0 } + (event.attendees ?? [])
                var seen = Set<String>()
                let attendees = participants.compactMap { participant -> String? in
                    let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = name?.isEmpty == false ? name! : participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                    return !value.isEmpty && seen.insert(value.lowercased()).inserted ? value : nil
                }
                return Meeting(id: event.eventIdentifier ?? "\(title)|\(start.timeIntervalSince1970)",
                    title: title, start: start, end: end, attendees: Array(attendees.prefix(25)))
            }
        }
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onChange?() }
        }
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    func load(now: Date, requestAccess: Bool = false) async -> CalendarSnapshot {
        let status = authorization()
        switch status {
        case .fullAccess: break
        case .notDetermined, .writeOnly:
            guard requestAccess else { return CalendarSnapshot(state: .accessRequired) }
            do {
                let granted = try await request()
                Self.log.info("Full calendar access request granted=\(granted)")
                guard granted, authorization() == .fullAccess else { return CalendarSnapshot(state: .denied) }
            } catch {
                Self.log.error("Calendar authorization failed: \(error.localizedDescription, privacy: .public)")
                return CalendarSnapshot(state: .failed(error.localizedDescription))
            }
        case .restricted: return CalendarSnapshot(state: .restricted)
        default: return CalendarSnapshot(state: .denied)
        }
        // Permission may be revoked while a request was suspended; never query without it.
        guard authorization() == .fullAccess else { return CalendarSnapshot(state: .denied) }
        let start = now.addingTimeInterval(-2 * 3600)
        let end = now.addingTimeInterval(8 * 3600)
        var seen = Set<String>()
        let all = fetch(start, end).filter { $0.start <= end && $0.end >= start && seen.insert($0.id).inserted }
            .sorted { $0.start < $1.start }
        let current = all.last(where: { $0.isInProgress(now) })
            ?? all.last(where: { $0.start <= now }) ?? all.first
        let past = Array(all.filter { $0.end < now }.suffix(2))
        let ongoing = all.filter { $0.isInProgress(now) }
        let upcoming = Array(all.filter { $0.start > now }.prefix(2))
        Self.log.info("Calendar loaded meetings=\(all.count)")
        return CalendarSnapshot(state: .ready, meetings: (past + ongoing + upcoming).sorted { $0.start < $1.start }, currentMeeting: current)
    }
}
