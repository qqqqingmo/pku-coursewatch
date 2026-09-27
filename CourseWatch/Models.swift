import Foundation

enum EntryKind: String, Codable, CaseIterable, Identifiable {
    case announcement = "公告"
    case assignment = "作业"
    case material = "教学内容"
    case syllabus = "课程大纲"
    case recording = "课程实录"
    case grade = "成绩"
    case other = "其他"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .announcement: "megaphone.fill"
        case .assignment: "checklist"
        case .material: "doc.text.fill"
        case .syllabus: "text.book.closed.fill"
        case .recording: "play.rectangle.fill"
        case .grade: "chart.bar.fill"
        case .other: "bell.fill"
        }
    }
}

struct Course: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var url: String
    var current: Bool? = nil
    var selected: Bool = false
}

struct Entry: Identifiable, Codable, Hashable {
    var id: String
    var courseID: String
    var courseName: String
    var kind: EntryKind
    var title: String
    var detail: String
    var url: String
    var sourcePageURL: String? = nil
    var postedAt: Date
    var observedOnly: Bool? = nil
    var dueAt: Date?
    var seen: Bool = false
    var done: Bool = false
    var isManual: Bool = false
    var calendarID: String? = nil
    var note: String? = nil
    var pinned: Bool? = nil

    var isPinned: Bool { pinned == true }
}

struct Snapshot: Codable {
    var courses: [Course] = []
    var entries: [Entry] = []
    var hasSynced = false
    var classSyncEnabled: Bool? = nil
    var gradescopeCourseIDs: [String: String]? = nil
    var syncedCourseIDs: Set<String>? = nil
    var syncedSources: Set<String>? = nil
    var externalLoginRequired: Set<String>? = nil
    var lastSync: Date? = nil
    var calendarFormatVersion: Int? = nil
}

struct ExternalCrawlResult: Decodable {
    let loginRequired: Bool
    let scanComplete: Bool
    let entries: [CrawlResult.EntryRow]
    let warnings: [String]
}

struct CrawlResult: Decodable {
    struct CourseRow: Decodable { let id: String; let name: String; let url: String; let current: Bool }
    struct EntryRow: Decodable {
        let id: String
        let courseID: String
        let courseName: String
        let kind: String
        let title: String
        let detail: String
        let url: String
        let sourcePageURL: String?
        let postedAt: String?
        let dueAt: String?
        let completed: Bool?
    }
    let loginRequired: Bool
    let courses: [CourseRow]
    let entries: [EntryRow]
    let warnings: [String]
}
