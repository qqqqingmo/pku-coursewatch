import Foundation
import UserNotifications

@MainActor final class Store: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var isSyncing = false
    @Published var status = "尚未同步"
    @Published var needsLogin = false
    @Published var needsClassLogin = false
    @Published var needsGradescopeLogin = false
    @Published var warnings: [String] = []

    private let fileURL: URL
    private let engine = PortalEngine()
    private let externalEngine = ExternalEngine()
    private var lastAttempt: Date?
    private var sourceReadyAt: [String: Date] = [:]

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CourseWatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        fileURL = directory.appendingPathComponent("data.json")
        if let data = try? Data(contentsOf: fileURL), let value = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = value
            var migrated = false
            for index in snapshot.entries.indices where snapshot.entries[index].kind == .material {
                let title = snapshot.entries[index].title
                if title.contains("大纲") || title.localizedCaseInsensitiveContains("syllabus") {
                    snapshot.entries[index].kind = .syllabus
                    snapshot.entries[index].id = snapshot.entries[index].id.replacingOccurrences(of: "|教学内容|", with: "|课程大纲|")
                    migrated = true
                }
            }
            if snapshot.gradescopeCourseIDs == nil {
                var inferred: [String: String] = [:]
                for index in snapshot.entries.indices {
                    let entry = snapshot.entries[index]
                    guard let courseID = Self.gradescopeCourseID(from: entry.url) else { continue }
                    inferred[entry.courseID] = courseID
                    if entry.id.hasPrefix("gradescope|") && entry.id.split(separator: "|").count == 2 {
                        snapshot.entries[index].id = entry.id.replacingOccurrences(
                            of: "gradescope|", with: "gradescope|\(courseID)|")
                    }
                }
                snapshot.gradescopeCourseIDs = inferred
                if !inferred.isEmpty { migrated = true }
            }
            if migrated { save() }
            let required = snapshot.externalLoginRequired ?? []
            needsClassLogin = isClassSyncEnabled && required.contains("class")
            needsGradescopeLogin = required.contains("gradescope")
            if let date = value.lastSync { status = "上次同步：\(date.formatted(date: .abbreviated, time: .shortened))" }
        }
    }

    var selectedCourseIDs: [String] { snapshot.courses.filter(\.selected).map(\.id) }

    private static func gradescopeCourseID(from rawURL: String) -> String? {
        guard let url = URL(string: rawURL), url.host == "www.gradescope.com",
              let index = url.pathComponents.firstIndex(of: "courses"),
              url.pathComponents.indices.contains(index + 1) else { return nil }
        let id = url.pathComponents[index + 1]
        return !id.isEmpty && id.allSatisfy(\.isNumber) ? id : nil
    }
    var isClassSyncEnabled: Bool {
        snapshot.classSyncEnabled ?? (snapshot.syncedSources ?? []).contains("class")
    }

    func setClassSyncEnabled(_ enabled: Bool) {
        snapshot.classSyncEnabled = enabled
        if !enabled {
            needsClassLogin = false
            snapshot.externalLoginRequired?.remove("class")
        }
        save()
    }

    func setGradescopeCourseIDs(_ values: [String: String]) {
        snapshot.gradescopeCourseIDs = values.filter { !$0.value.isEmpty }
        if snapshot.gradescopeCourseIDs?.isEmpty == true {
            needsGradescopeLogin = false
            snapshot.externalLoginRequired?.remove("gradescope")
        }
        save()
    }

    func setCourse(_ id: String, selected: Bool) {
        guard let index = snapshot.courses.firstIndex(where: { $0.id == id }) else { return }
        snapshot.courses[index].selected = selected
        save()
    }

    func setSeen(_ id: String, _ value: Bool) { update(id) { $0.seen = value } }
    func markAllSeen() {
        let selected = Set(selectedCourseIDs)
        for index in snapshot.entries.indices where selected.contains(snapshot.entries[index].courseID) && snapshot.entries[index].kind != .assignment {
            snapshot.entries[index].seen = true
        }
        save()
    }
    func setDone(_ id: String, _ value: Bool) { update(id) { $0.done = value } }
    func setNote(_ id: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.note = trimmed.isEmpty ? nil : trimmed }
    }
    func setPinned(_ id: String, _ value: Bool) { update(id) { $0.pinned = value } }
    func setCalendarID(_ id: String, _ value: String) { update(id) { $0.calendarID = value } }

    func migrateCalendarEventsIfNeeded() async {
        guard (snapshot.calendarFormatVersion ?? 0) < 2 else { return }
        let calendar = CalendarService()
        let calendarEntries = snapshot.entries.filter { $0.kind == .assignment && $0.calendarID != nil }
        for entry in calendarEntries {
            do {
                guard let identifier = try await calendar.updateExisting(entry) else {
                    warnings.append("未找到\(entry.title)原有的日历事件，请在卡片上点击“更新日历”。")
                    return
                }
                if let index = snapshot.entries.firstIndex(where: { $0.id == entry.id }) {
                    snapshot.entries[index].calendarID = identifier
                }
            } catch {
                warnings.append("已有作业的日历事件未能更新：\(error.localizedDescription)")
                return
            }
        }
        snapshot.calendarFormatVersion = 2
        save()
    }

    private func update(_ id: String, _ change: (inout Entry) -> Void) {
        guard let index = snapshot.entries.firstIndex(where: { $0.id == id }) else { return }
        change(&snapshot.entries[index]); save()
    }

    func addManual(courseID: String, title: String, detail: String, dueAt: Date) {
        guard let course = snapshot.courses.first(where: { $0.id == courseID }) else { return }
        let item = Entry(id: "manual-\(UUID().uuidString)", courseID: course.id,
                         courseName: course.name, kind: .assignment, title: title,
                         detail: detail, url: course.url, postedAt: Date(), dueAt: dueAt,
                         isManual: true)
        snapshot.entries.insert(item, at: 0); save()
    }

    func deleteManual(_ id: String) {
        snapshot.entries.removeAll { $0.id == id && $0.isManual }; save()
    }

    func shouldAutoSync(now: Date = Date()) -> Bool {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let start = calendar.startOfDay(for: now)
        guard let nine = calendar.date(byAdding: .hour, value: 9, to: start), now >= nine else { return false }
        return (snapshot.lastSync ?? .distantPast) < nine && (lastAttempt ?? .distantPast) < nine
    }

    func prepareSource(_ entry: Entry) async -> Bool {
        guard let host = URL(string: entry.url)?.host else { return false }
        guard ["course.pku.edu.cn", "class.pku.edu.cn", "www.gradescope.com"].contains(host) else { return true }
        if let checkedAt = sourceReadyAt[host], Date().timeIntervalSince(checkedAt) < 900 { return true }
        for _ in 0..<120 {
            if !isSyncing { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard !isSyncing else { return false }
        if let checkedAt = sourceReadyAt[host], Date().timeIntervalSince(checkedAt) < 900 { return true }
        do {
            let loginRequired: Bool
            switch host {
            case "course.pku.edu.cn":
                loginRequired = try await engine.crawl(selectedCourseIDs: []).loginRequired
                needsLogin = loginRequired
            case "class.pku.edu.cn":
                guard let course = snapshot.courses.first(where: { $0.id == entry.courseID }) else { return false }
                loginRequired = try await externalEngine.crawlClass(courses: [course]).loginRequired
                needsClassLogin = loginRequired
            case "www.gradescope.com":
                guard let course = snapshot.courses.first(where: { $0.id == entry.courseID }) else { return false }
                let gradescopeID = snapshot.gradescopeCourseIDs?[course.id] ??
                    Self.gradescopeCourseID(from: entry.url)
                guard let gradescopeID, !gradescopeID.isEmpty else { return false }
                loginRequired = try await externalEngine.crawlGradescope(course: course,
                                                                          gradescopeCourseID: gradescopeID).loginRequired
                needsGradescopeLogin = loginRequired
            default: return true
            }
            if !loginRequired { sourceReadyAt[host] = Date() }
            return !loginRequired
        } catch {
            warnings.append("打开原文前检查登录失败：\(error.localizedDescription)")
            return false
        }
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true; status = "正在检查课程动态…"; needsLogin = false
        needsClassLogin = false; needsGradescopeLogin = false; warnings = []; lastAttempt = Date()
        defer { isSyncing = false }
        var portalSucceeded = false
        do {
            let previousSelection = selectedCourseIDs
            let result = try await engine.crawl(selectedCourseIDs: previousSelection)
            if result.loginRequired {
                needsLogin = true; status = "登录已过期，请重新登录"
                if snapshot.hasSynced { notifyProblem("教学网登录已过期", "打开课讯重新登录，才能继续检查课程动态。") }
            } else {
                merge(result, scannedCourseIDs: previousSelection)
                warnings.append(contentsOf: result.warnings)
                if previousSelection.isEmpty && !selectedCourseIDs.isEmpty {
                    let detailResult = try await engine.crawl(selectedCourseIDs: selectedCourseIDs)
                    if detailResult.loginRequired {
                        needsLogin = true; status = "登录已过期，请重新登录"
                        notifyProblem("教学网登录已过期", "打开课讯重新登录，才能继续检查课程动态。")
                    } else {
                        merge(detailResult, scannedCourseIDs: selectedCourseIDs)
                        warnings.append(contentsOf: detailResult.warnings)
                        portalSucceeded = true
                    }
                } else {
                    portalSucceeded = true
                }
            }
        } catch {
            status = "同步失败：\(error.localizedDescription)"
            if snapshot.hasSynced { notifyProblem("教学网同步失败", error.localizedDescription) }
        }
        await syncExternal()
        warnings = Array(Set(warnings)).sorted()
        if portalSucceeded {
            sourceReadyAt["course.pku.edu.cn"] = Date()
            status = "已更新 · \(Date().formatted(date: .abbreviated, time: .shortened))"
        }
    }

    private func syncExternal() async {
        if isClassSyncEnabled {
            let courses = snapshot.courses.filter { $0.selected && $0.current != false }
            if !courses.isEmpty {
                do {
                    let result = try await externalEngine.crawlClass(courses: courses)
                    needsClassLogin = result.loginRequired
                    setExternalLogin("class", required: result.loginRequired)
                    warnings.append(contentsOf: result.warnings)
                    if result.scanComplete {
                        mergeExternal(result, source: "class")
                        sourceReadyAt["class.pku.edu.cn"] = Date()
                    }
                    if result.loginRequired && (snapshot.syncedSources ?? []).contains("class") {
                        notifyProblem("北大问学需要登录", "打开课讯恢复登录，才能继续检查问学作业。")
                    }
                } catch {
                    warnings.append("北大问学同步失败：\(error.localizedDescription)")
                }
            }
        }
        let gradescopeCourses = snapshot.courses.compactMap { course -> (course: Course, gradescopeID: String)? in
            guard course.selected, let id = snapshot.gradescopeCourseIDs?[course.id], !id.isEmpty else { return nil }
            return (course, id)
        }
        var gradescopeLoginRequired = false
        let gradescopeChecked = !gradescopeCourses.isEmpty
        for target in gradescopeCourses {
            let course = target.course
            let source = "gradescope:\(target.gradescopeID)"
            do {
                let result = try await externalEngine.crawlGradescope(course: course,
                                                                       gradescopeCourseID: target.gradescopeID)
                gradescopeLoginRequired = gradescopeLoginRequired || result.loginRequired
                warnings.append(contentsOf: result.warnings)
                if result.scanComplete {
                    mergeExternal(result, source: source)
                    sourceReadyAt["www.gradescope.com"] = Date()
                }
                if result.loginRequired && (snapshot.syncedSources ?? []).contains(source) {
                    notifyProblem("Gradescope 需要登录", "打开课讯登录，才能继续检查\(course.name)作业。")
                }
            } catch {
                warnings.append("\(course.name)的 Gradescope 同步失败：\(error.localizedDescription)")
            }
        }
        if gradescopeChecked {
            needsGradescopeLogin = gradescopeLoginRequired
            setExternalLogin("gradescope", required: gradescopeLoginRequired)
        }
    }

    private func setExternalLogin(_ source: String, required: Bool) {
        var pending = snapshot.externalLoginRequired ?? []
        if required { pending.insert(source) } else { pending.remove(source) }
        snapshot.externalLoginRequired = pending
        save()
    }

    private func mergeExternal(_ result: ExternalCrawlResult, source: String) {
        let oldEntries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) })
        let items: [Entry] = result.entries.compactMap { row in
            guard let course = snapshot.courses.first(where: { $0.id == row.courseID && $0.selected }) else { return nil }
            let old = oldEntries[row.id]
            let date = Self.parseDate(row.postedAt) ?? Date()
            return Entry(id: row.id, courseID: course.id, courseName: course.name,
                         kind: .assignment, title: row.title, detail: row.detail, url: row.url,
                         postedAt: old?.postedAt ?? date, observedOnly: row.postedAt == nil,
                         dueAt: Self.parseDate(row.dueAt), seen: old?.seen ?? false,
                         done: old?.done ?? (row.completed ?? false), isManual: false,
                         calendarID: old?.calendarID, note: old?.note, pinned: old?.pinned)
        }
        let incoming = (snapshot.syncedSources ?? []).contains(source) ? items.filter { oldEntries[$0.id] == nil } : []
        let replacing = Set(items.map(\.id))
        snapshot.entries.removeAll { replacing.contains($0.id) }
        snapshot.entries.append(contentsOf: items)
        snapshot.entries.sort { $0.postedAt > $1.postedAt }
        snapshot.syncedSources = (snapshot.syncedSources ?? []).union([source])
        save()
        notify(incoming)
    }

    private func merge(_ result: CrawlResult, scannedCourseIDs: [String]) {
        let oldCourses = Dictionary(uniqueKeysWithValues: snapshot.courses.map { ($0.id, $0) })
        var mergedCourses = oldCourses
        for row in result.courses {
            mergedCourses[row.id] = Course(id: row.id, name: row.name, url: row.url,
                                           current: row.current,
                                           selected: oldCourses[row.id]?.selected ?? row.current)
        }
        snapshot.courses = mergedCourses.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let oldEntries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) })
        var newEntries: [Entry] = []
        for row in result.entries {
            guard snapshot.courses.contains(where: { $0.id == row.courseID && $0.selected }) else { continue }
            let kind = EntryKind(rawValue: row.kind) ?? .other
            let old = oldEntries[row.id]
            let gradeChanged = kind == .grade && old != nil && old?.detail != row.detail
            let date = Self.parseDate(row.postedAt) ?? Date()
            newEntries.append(Entry(id: row.id, courseID: row.courseID, courseName: row.courseName,
                                    kind: kind, title: row.title, detail: row.detail,
                                    url: row.url, sourcePageURL: row.sourcePageURL ?? old?.sourcePageURL,
                                    postedAt: gradeChanged ? date : (old?.postedAt ?? date),
                                    observedOnly: row.postedAt == nil,
                                    dueAt: Self.parseDate(row.dueAt), seen: gradeChanged ? false : (old?.seen ?? false),
                                    done: old?.done ?? false, isManual: false,
                                    calendarID: old?.calendarID, note: old?.note, pinned: old?.pinned))
        }
        let incoming = newEntries.filter { item in
            guard (snapshot.syncedCourseIDs ?? []).contains(item.courseID) else { return false }
            let old = oldEntries[item.id]
            return old == nil || (item.kind == .grade && old?.detail != item.detail)
        }
        let manuals = snapshot.entries.filter(\.isManual)
        let newIDs = Set(newEntries.map(\.id))
        let remoteOld = snapshot.entries.filter { !$0.isManual && !newIDs.contains($0.id) }
        snapshot.entries = (manuals + newEntries + remoteOld).sorted { $0.postedAt > $1.postedAt }
        snapshot.syncedCourseIDs = (snapshot.syncedCourseIDs ?? []).union(scannedCourseIDs)
        snapshot.hasSynced = true
        snapshot.lastSync = Date()
        save()
        notify(incoming)
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        for format in ["yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
            f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = format
            if let date = f.date(from: value) { return date }
        }
        for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm Z"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format
            if let date = f.date(from: value) { return date }
        }
        return nil
    }

    private func notify(_ items: [Entry]) {
        guard !items.isEmpty else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { allowed, _ in
            guard allowed else { return }
            for item in items.prefix(10) {
                let content = UNMutableNotificationContent()
                content.title = "\(item.courseName) · \(item.kind.rawValue)"
                content.body = item.title
                content.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
            }
        }
    }

    private func notifyProblem(_ title: String, _ body: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, _ in
            guard allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "coursewatch-sync-problem", content: content, trigger: nil))
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }
}
