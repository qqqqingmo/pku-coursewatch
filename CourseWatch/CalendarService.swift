import EventKit
import Foundation

enum CalendarFailure: LocalizedError {
    case noPermission, noCalendar, noDeadline
    var errorDescription: String? {
        switch self {
        case .noPermission: "请在系统设置中允许课讯访问日历。"
        case .noCalendar: "没有找到可写入的“课业”日历，也无法自动创建。"
        case .noDeadline: "这条内容没有截止时间。"
        }
    }
}

@MainActor final class CalendarService {
    private let store = EKEventStore()

    func save(_ entry: Entry) async throws -> String {
        guard let due = entry.dueAt else { throw CalendarFailure.noDeadline }
        try await requestPermission()
        let event = entry.calendarID.flatMap { store.event(withIdentifier: $0) } ?? EKEvent(eventStore: store)
        return try write(event, for: entry, due: due)
    }

    func updateExisting(_ entry: Entry) async throws -> String? {
        guard let due = entry.dueAt, let identifier = entry.calendarID else { return nil }
        try await requestPermission()
        guard let event = store.event(withIdentifier: identifier) else { return nil }
        return try write(event, for: entry, due: due)
    }

    private func requestPermission() async throws {
        let allowed: Bool = await withCheckedContinuation { continuation in
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { ok, _ in continuation.resume(returning: ok) }
            } else {
                store.requestAccess(to: .event) { ok, _ in continuation.resume(returning: ok) }
            }
        }
        guard allowed else { throw CalendarFailure.noPermission }
    }

    private func courseworkCalendar() throws -> EKCalendar {
        if let calendar = store.calendars(for: .event).first(where: { $0.title == "课业" && $0.allowsContentModifications }) {
            return calendar
        }
        guard let source = store.defaultCalendarForNewEvents?.source else { throw CalendarFailure.noCalendar }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "课业"
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    private func write(_ event: EKEvent, for entry: Entry, due: Date) throws -> String {
        event.calendar = try courseworkCalendar()
        event.isAllDay = true
        let day = Calendar.current.startOfDay(for: due)
        event.startDate = day
        event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(24 * 3600)
        let time = due.formatted(date: .omitted, time: .shortened)
        event.title = "[\(entry.courseName)] \(entry.title) 截止 \(time)"
        event.notes = "实际截止：\(due.formatted(date: .abbreviated, time: .shortened))\n\n\(entry.detail)"
        if let url = URL(string: entry.url) { event.url = url }
        event.alarms?.forEach { event.removeAlarm($0) }
        event.addAlarm(EKAlarm(absoluteDate: due.addingTimeInterval(-2 * 24 * 3600)))
        event.addAlarm(EKAlarm(absoluteDate: due.addingTimeInterval(-24 * 3600)))
        event.addAlarm(EKAlarm(absoluteDate: due.addingTimeInterval(-2 * 3600)))
        try store.save(event, span: .thisEvent)
        return event.eventIdentifier
    }
}
