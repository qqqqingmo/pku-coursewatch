import AppKit
import SwiftUI
import UserNotifications
import WebKit

private final class ForegroundNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundNotifications()
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@MainActor private enum AppRuntime {
    static let store = Store()
    static var started = false
    static var timer: Timer?

    static func start() {
        guard !started else { return }
        started = true
        Scheduler.install()
        let checkingTimer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in if store.shouldAutoSync() { await store.sync() } }
        }
        RunLoop.main.add(checkingTimer, forMode: .common)
        timer = checkingTimer
        let args = ProcessInfo.processInfo.arguments
        let needsSync = args.contains("--sync") || !store.snapshot.hasSynced || store.shouldAutoSync()
        Task {
            if needsSync { await store.sync() }
            await store.migrateCalendarEventsIfNeeded()
        }
    }
}

@MainActor private final class AppLifecycle: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppRuntime.start()
    }
}

@main @MainActor struct CourseWatchApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var store = AppRuntime.store

    init() {
        UNUserNotificationCenter.current().delegate = ForegroundNotifications.shared
    }

    var body: some Scene {
        Window("课讯", id: "dashboard") {
            DashboardView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        MenuBarExtra("课讯", systemImage: "bell.badge") { MenuContent().environmentObject(store) }
    }
}

private struct MenuContent: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("打开课讯") { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }
        Button("立即同步") { Task { await store.sync() } }
        Divider()
        Button("退出") { NSApp.terminate(nil) }
    }
}

private enum FeedMode: String, CaseIterable { case all = "全部动态", unread = "未读", pending = "待完成" }
private enum SortMode: String, CaseIterable { case newest = "发布时间", deadline = "截止时间" }

private enum Palette {
    static let ink = Color(red: 0.10, green: 0.24, blue: 0.25)
    static let muted = Color(red: 0.34, green: 0.46, blue: 0.47)
    static let teal = Color(red: 0.05, green: 0.46, blue: 0.47)
    static let tealSoft = Color(red: 0.82, green: 0.93, blue: 0.92)
    static let coral = Color(red: 0.65, green: 0.29, blue: 0.24)
    static let coralSoft = Color(red: 0.98, green: 0.89, blue: 0.86)
    static let sidebarTop = Color(red: 0.93, green: 0.98, blue: 0.98)
    static let sidebarBottom = Color(red: 0.89, green: 0.95, blue: 0.95)
    static let canvas = Color(red: 0.97, green: 0.99, blue: 0.99)
    static let settledCard = Color(red: 0.94, green: 0.97, blue: 0.97)
    static let line = Color(red: 0.82, green: 0.89, blue: 0.89)
}

struct DashboardView: View {
    @EnvironmentObject private var store: Store
    @State private var mode: FeedMode = .all
    @State private var courseFilter = "all"
    @State private var sort: SortMode = .newest
    @State private var kindFilter: EntryKind? = nil
    @State private var showLogin = false
    @State private var showClassLogin = false
    @State private var showGradescopeLogin = false
    @State private var showSettings = false
    @State private var showManual = false
    @State private var noteEntry: Entry? = nil
    @State private var sourceEntry: Entry? = nil
    @State private var openingSourceID: String? = nil
    @State private var errorText: String? = nil
    private let calendar = CalendarService()

    private struct CourseAttention {
        var unread = 0
        var pending = 0
        var needsAttention: Bool { unread > 0 || pending > 0 }
    }

    private var selectedEntries: [Entry] {
        let selectedIDs = store.selectedCourseIDs
        return store.snapshot.entries.filter { selectedIDs.contains($0.courseID) }
    }

    private var attentionByCourse: [String: CourseAttention] {
        var result: [String: CourseAttention] = [:]
        for entry in selectedEntries {
            var attention = result[entry.courseID, default: CourseAttention()]
            if isUnread(entry) { attention.unread += 1 }
            if entry.kind == .assignment && !entry.done { attention.pending += 1 }
            result[entry.courseID] = attention
        }
        return result
    }

    private func isSettled(_ entry: Entry) -> Bool {
        entry.kind == .assignment ? entry.done : entry.seen
    }

    private func isUnread(_ entry: Entry) -> Bool {
        entry.kind != .assignment && !entry.seen
    }

    private func displayDetail(_ entry: Entry) -> String? {
        var detail = entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.hasPrefix("打开快速链接") {
            guard entry.kind == .assignment, let marker = detail.range(of: "作业信息") else { return nil }
            detail = String(detail[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if detail.contains("DWREngine") || detail.contains("page.ContextMenu") {
            detail = detail.replacingOccurrences(of: #"\(function\(\)\s*\{[\s\S]*?\}\)\(\);"#,
                                                  with: " ", options: .regularExpression)
            if let incompleteCode = detail.range(of: "(function(){") {
                detail = String(detail[..<incompleteCode.lowerBound])
            }
            detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if detail.hasPrefix(entry.title) {
            detail = String(detail.dropFirst(entry.title.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return detail.isEmpty ? nil : detail
    }

    private var entries: [Entry] {
        var items = selectedEntries
        if courseFilter != "all" { items = items.filter { $0.courseID == courseFilter } }
        if let kindFilter { items = items.filter { $0.kind == kindFilter } }
        switch mode {
        case .all: break
        case .unread: items = items.filter(isUnread)
        case .pending: items = items.filter { $0.kind == .assignment && !$0.done }
        }
        return items.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if mode == .all {
                let leftSettled = isSettled($0)
                let rightSettled = isSettled($1)
                if leftSettled != rightSettled { return !leftSettled }
            }
            if sort == .deadline, ($0.dueAt ?? .distantFuture) != ($1.dueAt ?? .distantFuture) {
                return ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture)
            }
            if $0.postedAt != $1.postedAt { return $0.postedAt > $1.postedAt }
            return $0.id < $1.id
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                if store.needsLogin { loginBanner }
                if store.needsClassLogin { classLoginBanner }
                if store.needsGradescopeLogin { gradescopeLoginBanner }
                if !store.warnings.isEmpty { warningBanner }
                filters
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if entries.isEmpty { emptyState }
                        ForEach(entries) { item in entryCard(item) }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 30)
                }
                footer
            }
            .background(Palette.canvas)
        }
        .tint(Palette.teal)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showLogin) {
            BrowserSheet(url: URL(string: "https://course.pku.edu.cn/webapps/bb-sso-BBLEARN/login.html")!,
                         title: "登录北京大学教学网", buttonTitle: "我已登录，开始同步") {
                showLogin = false
                Task { await store.sync() }
            }
        }
        .sheet(isPresented: $showManual) { ManualSheet().environmentObject(store) }
        .sheet(item: $noteEntry) { NoteSheet(entry: $0).environmentObject(store) }
        .sheet(item: $sourceEntry) { SourceSheet(entry: $0).environmentObject(store) }
        .sheet(isPresented: $showSettings) { SettingsSheet().environmentObject(store) }
        .sheet(isPresented: $showClassLogin) {
            BrowserSheet(url: URL(string: "https://class.pku.edu.cn/login/iaaa")!,
                         title: "登录北大问学", buttonTitle: "我已登录，开始同步") {
                showClassLogin = false
                Task { await store.sync() }
            }
        }
        .sheet(isPresented: $showGradescopeLogin) {
            BrowserSheet(url: URL(string: "https://www.gradescope.com/login")!,
                         title: "登录 Gradescope", buttonTitle: "我已登录，开始同步") {
                showGradescopeLogin = false
                Task { await store.sync() }
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好") { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill").font(.title2).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(Palette.teal.gradient, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 1) {
                    Text("课讯").font(.system(size: 21, weight: .bold)).foregroundStyle(Palette.ink)
                    Text("课程动态 · 一目了然").font(.caption).foregroundStyle(Palette.muted)
                }
            }.padding(.bottom, 25)
            sidebarButton("全部动态", symbol: "rectangle.stack", count: nil, selected: mode == .all && courseFilter == "all") { mode = .all; courseFilter = "all" }
            sidebarButton("未读", symbol: "circle.dotted", count: selectedEntries.filter(isUnread).count, selected: mode == .unread && courseFilter == "all", countColor: Palette.teal) { mode = .unread; courseFilter = "all" }
            sidebarButton("待完成", symbol: "checklist", count: selectedEntries.filter { $0.kind == .assignment && !$0.done }.count, selected: mode == .pending && courseFilter == "all", countColor: Palette.coral) { mode = .pending; courseFilter = "all" }
            Text("本学期课程").font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                .padding(.top, 25).padding(.bottom, 2)
            HStack(spacing: 10) {
                Label("未读", systemImage: "circle.fill").foregroundStyle(Palette.teal)
                Label("待完成", systemImage: "circle.fill").foregroundStyle(Palette.coral)
            }
            .font(.system(size: 10, weight: .medium))
            .labelStyle(.titleAndIcon)
            .padding(.leading, 2).padding(.bottom, 7)
            if store.snapshot.courses.isEmpty {
                Text("登录后显示课程").font(.caption).foregroundStyle(.tertiary).padding(.leading, 11)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(store.snapshot.courses.filter { $0.current == true || !store.snapshot.courses.contains(where: { $0.current == true }) }) { course in
                        let attention = attentionByCourse[course.id, default: CourseAttention()]
                        ZStack(alignment: .leading) {
                            Button {
                                courseFilter = course.id; mode = .all
                                if course.selected && !store.snapshot.hasSynced { Task { await store.sync() } }
                            } label: {
                                HStack(spacing: 5) {
                                    Color.clear.frame(width: 20, height: 20)
                                    HStack(spacing: 4) {
                                        Text(course.name)
                                            .font(.system(size: 13, weight: attention.needsAttention && course.selected ? .semibold : .regular))
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if course.selected && attention.unread > 0 {
                                            courseCount(attention.unread, color: Palette.teal, background: Palette.tealSoft)
                                                .help("未读 \(attention.unread) 条")
                                        }
                                        if course.selected && attention.pending > 0 {
                                            courseCount(attention.pending, color: Palette.coral, background: Palette.coralSoft)
                                                .help("待完成 \(attention.pending) 项")
                                        }
                                    }
                                }
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                                .background(courseFilter == course.id ? Palette.tealSoft :
                                                (course.selected && attention.needsAttention ? Color.white.opacity(0.55) : .clear),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看\(course.name)动态")
                                .foregroundStyle(course.selected ? Palette.ink : Palette.muted)
                            Button {
                                let selected = !course.selected
                                store.setCourse(course.id, selected: selected)
                                if selected { Task { await store.sync() } }
                            } label: {
                                Image(systemName: course.selected ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(course.selected ? Palette.teal : Palette.muted)
                                    .frame(width: 24, height: 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 5)
                            .help(course.selected ? "取消显示此课程" : "显示此课程")
                            .accessibilityLabel("\(course.name)，\(course.selected ? "已选择" : "未选择")")
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            Spacer(minLength: 12)
            Button { showSettings = true } label: {
                HStack {
                    Label("设置", systemImage: "gearshape")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
            Text("每天 09:00 自动检查").font(.caption).foregroundStyle(Palette.muted)
        }
        .padding(20).frame(width: 268)
        .background(LinearGradient(colors: [Palette.sidebarTop, Palette.sidebarBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(alignment: .trailing) { Palette.line.frame(width: 1) }
    }

    private func courseCount(_ count: Int, color: Color, background: Color) -> some View {
        Text("\(count)").font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(minWidth: 17)
            .padding(.horizontal, 3).padding(.vertical, 2)
            .background(background, in: Capsule())
    }

    private func sidebarButton(_ title: String, symbol: String, count: Int?, selected: Bool, countColor: Color = Palette.teal, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if let count, count > 0 {
                    courseCount(count, color: countColor, background: countColor == Palette.coral ? Palette.coralSoft : Palette.tealSoft)
                }
            }.padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(selected ? Palette.tealSoft : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Palette.teal : Palette.ink)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(courseFilter == "all" ? mode.rawValue : (store.snapshot.courses.first { $0.id == courseFilter }?.name ?? "课程动态"))
                    .font(.system(size: 27, weight: .bold))
                Text(store.status).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showManual = true } label: { Label("添加作业", systemImage: "plus") }
                .disabled(store.snapshot.courses.filter(\.selected).isEmpty)
            Button { Task { await store.sync() } } label: {
                if store.isSyncing { ProgressView().controlSize(.small) } else { Label("立即同步", systemImage: "arrow.clockwise") }
            }.buttonStyle(.borderedProminent).disabled(store.isSyncing)
        }.padding(.horizontal, 28).padding(.top, 27).padding(.bottom, 22)
    }

    private var loginBanner: some View {
        HStack {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
            Text("教学网登录已过期，登录后才能继续获取新动态。")
            Spacer()
            Button("去登录") { showLogin = true }
        }.font(.subheadline).padding(12).background(.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 28).padding(.bottom, 12)
    }

    private var classLoginBanner: some View {
        HStack {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
            Text("北大问学需要登录，问学作业暂未更新。")
            Spacer()
            Button("去登录") { showClassLogin = true }
        }.font(.subheadline).padding(12).background(.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 28).padding(.bottom, 12)
    }

    private var gradescopeLoginBanner: some View {
        HStack {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
            Text("Gradescope 需要登录，相关课程作业暂未更新。")
            Spacer()
            Button("去登录") { showGradescopeLogin = true }
        }.font(.subheadline).padding(12).background(.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 28).padding(.bottom, 12)
    }

    private var warningBanner: some View {
        Text(store.warnings.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .padding(11).background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 28).padding(.bottom, 10)
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("类型", selection: $kindFilter) {
                Text("所有类型").tag(EntryKind?.none)
                ForEach(EntryKind.allCases) { kind in Text(kind.rawValue).tag(Optional(kind)) }
            }.frame(width: 160)
            Picker("排序", selection: $sort) {
                ForEach(SortMode.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
            }.frame(width: 155)
            Spacer()
            if selectedEntries.contains(where: isUnread) {
                Button("全部标为已读") { store.markAllSeen() }.buttonStyle(.link).font(.caption).foregroundStyle(Palette.teal)
            }
            let visibleUnread = entries.filter(isUnread).count
            let visiblePending = entries.filter { $0.kind == .assignment && !$0.done }.count
            if visibleUnread > 0 { Text("未读 \(visibleUnread)").foregroundStyle(Palette.teal) }
            if visiblePending > 0 { Text("待完成 \(visiblePending)").foregroundStyle(Palette.coral) }
            Text("\(entries.count) 条动态").font(.caption).foregroundStyle(.secondary)
        }.font(.caption.weight(.medium)).padding(.horizontal, 28).padding(.bottom, 15)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 38)).foregroundStyle(Palette.teal.opacity(0.6))
            Text(store.snapshot.courses.isEmpty ? "先登录教学网" : store.selectedCourseIDs.isEmpty ? "勾选本学期课程" : "这里还没有动态")
                .font(.headline)
            Text(store.snapshot.courses.isEmpty ? "登录后点击“立即同步”，课程会显示在左侧。" : store.selectedCourseIDs.isEmpty ? "只会显示你勾选的课程。" : "你可以立即同步，也可以手动添加作业。")
                .font(.subheadline).foregroundStyle(.secondary)
            if store.snapshot.courses.isEmpty { Button("登录教学网") { showLogin = true }.buttonStyle(.borderedProminent) }
            else if !store.selectedCourseIDs.isEmpty { Button("立即同步") { Task { await store.sync() } }.buttonStyle(.bordered) }
        }.frame(maxWidth: .infinity).padding(.vertical, 110)
    }

    private func entryCard(_ item: Entry) -> some View {
        let settled = isSettled(item)
        let statusColor = item.kind == .assignment ? Palette.coral : Palette.teal
        let statusBackground = item.kind == .assignment ? Palette.coralSoft : Palette.tealSoft
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: item.kind.symbol).font(.system(size: 18))
                    .foregroundStyle(statusColor)
                    .frame(width: 36, height: 36)
                    .background(statusBackground,
                                in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(item.courseName).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Text("·").foregroundStyle(.tertiary)
                        Text(item.kind.rawValue).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text(item.kind == .assignment ? (item.done ? "已完成" : "待完成") : (item.seen ? "已读" : "未读"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(settled ? Palette.muted : statusColor)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(settled ? Palette.settledCard : statusBackground, in: Capsule())
                        if item.isPinned {
                            Label("置顶", systemImage: "pin.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Palette.coral)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Palette.coralSoft, in: Capsule())
                        }
                        if item.isManual { Text("手动添加").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2).background(.gray.opacity(0.12), in: Capsule()) }
                        Spacer()
                        Text("\(item.isManual ? "添加于 " : (item.observedOnly == true ? "发现于 " : ""))\(item.postedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(item.title).font(.system(size: 17, weight: settled ? .medium : .semibold)).lineLimit(2)
                    if let detail = displayDetail(item) {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let note = item.note, !note.isEmpty {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "note.text").foregroundStyle(Palette.teal)
                            Text(note).foregroundStyle(Palette.ink).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                        .padding(8)
                        .background(Palette.tealSoft.opacity(0.42), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if !settled { Circle().fill(statusColor).frame(width: 7, height: 7).padding(.top, 5) }
            }
            VStack(alignment: .leading, spacing: 9) {
                if let due = item.dueAt {
                    HStack(spacing: 8) {
                    Label("截止 \(due.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar.badge.clock")
                        .foregroundStyle(due < Date() && !item.done ? Palette.coral : Palette.muted)
                    if item.kind == .assignment && !item.done && due < Date().addingTimeInterval(48 * 3600) {
                        Text(due < Date() ? "已逾期" : "两天内截止")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.coral)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Palette.coralSoft, in: Capsule())
                    }
                    }
                    .font(.caption)
                }
                HStack(spacing: 13) {
                Button(item.isPinned ? "取消置顶" : "置顶") { store.setPinned(item.id, !item.isPinned) }
                Button(item.note == nil ? "添加备注" : "编辑备注") { noteEntry = item }
                Spacer()
                if item.kind == .assignment {
                    Button(item.done ? "已完成" : "标为完成") { store.setDone(item.id, !item.done) }
                }
                if item.dueAt != nil {
                    Button(item.calendarID == nil ? "加入日历" : "更新日历") {
                        Task {
                            do { store.setCalendarID(item.id, try await calendar.save(item)) }
                            catch { errorText = error.localizedDescription }
                        }
                    }
                }
                if item.kind != .assignment {
                    Button(item.seen ? "标为未读" : "标为已读") { store.setSeen(item.id, !item.seen) }
                }
                if item.isManual {
                    Button("删除") { store.deleteManual(item.id) }
                } else if URL(string: item.url)?.scheme == "https" {
                    Button(openingSourceID == item.id ? "正在打开…" : "查看原文") {
                        openingSourceID = item.id
                        Task {
                            let ready = await store.prepareSource(item)
                            openingSourceID = nil
                            if ready {
                                sourceEntry = item
                                if item.kind != .assignment { store.setSeen(item.id, true) }
                            } else {
                                errorText = "自动恢复登录未成功，请稍后重试；若网站要求额外验证，请使用左侧设置中的登录入口。"
                            }
                        }
                    }.disabled(openingSourceID != nil)
                }
                }
                .buttonStyle(.link).font(.caption).foregroundStyle(Palette.teal)
            }
        }
        .padding(17)
        .background(settled ? Palette.settledCard : .white, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Palette.line, lineWidth: 1))
        .opacity(settled ? 0.67 : 1)
        .shadow(color: Palette.ink.opacity(settled ? 0 : 0.045), radius: 9, y: 3)
    }

    private var footer: some View {
        HStack {
            Text("仅在本机保存课程和状态 · 首次同步不会推送旧动态")
            Spacer()
            Text("下次检查：每天 09:00")
        }.font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 28).padding(.vertical, 11)
    }

}

private enum SettingsPage: String, Identifiable {
    case courseLogin, courseCredentials, classLogin, gradescopeLogin, gradescopeCredentials, externalCourses
    var id: String { rawValue }
}

private struct SettingsSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var page: SettingsPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设置").font(.title2.bold()).foregroundStyle(Palette.ink)
                    Text("管理课程网站的登录与外部课程同步")
                        .font(.subheadline).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(.bottom, 10)

            settingsRow("登录教学网", detail: "手动恢复教学网登录", symbol: "person.crop.circle") { page = .courseLogin }
            settingsRow("自动登录设置", detail: "管理校园卡账号与密码", symbol: "key.fill") { page = .courseCredentials }
            settingsRow("外部课程同步", detail: "选择问学同步，配置 Gradescope 课程", symbol: "square.stack.3d.up") { page = .externalCourses }
            settingsRow("北大问学登录修复", detail: "平时共用校园卡自动登录；仅登录失效时使用", symbol: "book.closed") { page = .classLogin }
            settingsRow("登录 Gradescope", detail: "手动恢复 Gradescope 登录", symbol: "checkmark.seal") { page = .gradescopeLogin }
            settingsRow("Gradescope 自动登录", detail: "管理 Gradescope 账号与密码", symbol: "key.horizontal") { page = .gradescopeCredentials }
        }
        .padding(24).frame(width: 500)
        .background(Palette.canvas)
        .sheet(item: $page) { selected in
            switch selected {
            case .courseLogin:
                BrowserSheet(url: URL(string: "https://course.pku.edu.cn/webapps/bb-sso-BBLEARN/login.html")!,
                             title: "登录北京大学教学网", buttonTitle: "我已登录，开始同步") {
                    page = nil
                    Task { await store.sync() }
                }
            case .courseCredentials:
                CredentialsSheet()
            case .classLogin:
                BrowserSheet(url: URL(string: "https://class.pku.edu.cn/login/iaaa")!,
                             title: "登录北大问学", buttonTitle: "我已登录，开始同步") {
                    page = nil
                    Task { await store.sync() }
                }
            case .gradescopeLogin:
                BrowserSheet(url: URL(string: "https://www.gradescope.com/login")!,
                             title: "登录 Gradescope", buttonTitle: "我已登录，开始同步") {
                    page = nil
                    Task { await store.sync() }
                }
            case .gradescopeCredentials:
                GradescopeCredentialsSheet().environmentObject(store)
            case .externalCourses:
                ExternalCoursesSheet().environmentObject(store)
            }
        }
    }

    private func settingsRow(_ title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.teal)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text(detail).font(.caption).foregroundStyle(Palette.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Palette.muted)
            }
            .padding(12).frame(maxWidth: .infinity)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ExternalCoursesSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var mappings: [String: String] = [:]

    private var currentCourses: [Course] {
        let courses = store.snapshot.courses
        return courses.filter { $0.current == true || !courses.contains(where: { $0.current == true }) }
    }

    private func normalizedID(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.allSatisfy(\.isNumber) { return value }
        guard let url = URL(string: value), url.host == "www.gradescope.com",
              let index = url.pathComponents.firstIndex(of: "courses"),
              url.pathComponents.indices.contains(index + 1) else { return value }
        return url.pathComponents[index + 1]
    }

    private var cleanMappings: [String: String] {
        let visibleIDs = Set(currentCourses.map(\.id))
        return mappings.filter { visibleIDs.contains($0.key) }
            .mapValues(normalizedID).filter { !$0.value.isEmpty }
    }

    private var validMappings: Bool {
        let values = Array(cleanMappings.values)
        return values.allSatisfy { $0.allSatisfy(\.isNumber) } && Set(values).count == values.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("外部课程同步").font(.title2.bold()).foregroundStyle(Palette.ink)
            Toggle("同步北大问学中的本学期课程", isOn: Binding(
                get: { store.isClassSyncEnabled },
                set: { enabled in
                    store.setClassSyncEnabled(enabled)
                    if enabled { Task { await store.sync() } }
                }
            ))
            Text("按教学网中已勾选课程的名称匹配问学课程。")
                .font(.caption).foregroundStyle(Palette.muted)
            Divider()
            Text("Gradescope 课程对应").font(.headline)
            Text("从 Gradescope 课程网址复制 /courses/ 后面的数字，也可以粘贴完整网址。留空的课程不会检查 Gradescope。")
                .font(.caption).foregroundStyle(Palette.muted)
            if currentCourses.isEmpty {
                Text("先同步教学网，再回来设置课程对应。")
                    .font(.subheadline).foregroundStyle(Palette.muted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(currentCourses) { course in
                            HStack(spacing: 12) {
                                Text(course.name).font(.subheadline).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                TextField("课程网址或编号", text: Binding(
                                    get: { mappings[course.id, default: ""] },
                                    set: { mappings[course.id] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 185)
                            }
                        }
                    }
                }.frame(height: 245)
            }
            if !validMappings {
                Text("请填写有效且不重复的 Gradescope 课程编号。")
                    .font(.caption).foregroundStyle(Palette.coral)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存并同步") {
                    store.setGradescopeCourseIDs(cleanMappings)
                    dismiss()
                    Task { await store.sync() }
                }.buttonStyle(.borderedProminent).disabled(!validMappings)
            }
        }
        .padding(24).frame(width: 580)
        .background(Palette.canvas)
        .onAppear { mappings = store.snapshot.gradescopeCourseIDs ?? [:] }
    }
}

private struct CredentialsSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var username = CredentialsVault.load()?.username ?? ""
    @State private var password = ""
    @State private var status = "账号和密码保存在此 Mac 的私人文件中，仅当前用户可读。"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自动登录设置").font(.title2.bold())
            Text("教学网登录过期时，程序会尝试自动重新登录。遇到验证码或二次验证时会提醒你手动完成。")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("校园卡账号", text: $username)
            SecureField("校园卡密码", text: $password)
            Text(status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("删除已保存的账号") {
                    CredentialsVault.delete()
                    password = ""; status = "已删除本地记录。"
                }
                Spacer()
                Button("关闭") { dismiss() }
                Button("保存到本机") {
                    if CredentialsVault.save(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password) {
                        password = ""; status = "已保存。下次同步会自动尝试登录。"
                    } else { status = "请填写账号和密码后重试。" }
                }.buttonStyle(.borderedProminent).disabled(username.isEmpty || password.isEmpty)
            }
        }.padding(26).frame(width: 480)
    }
}

private struct GradescopeCredentialsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var email = CredentialsVault.loadGradescope()?.username ?? ""
    @State private var password = ""
    @State private var status = "账号和密码保存在此 Mac 的私人文件中，仅当前用户可读。"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gradescope 自动登录").font(.title2.bold())
            Text("会话过期时，课讯会尝试自动登录。若网站要求额外验证，会提醒你手动完成。")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("Gradescope 邮箱", text: $email)
            SecureField("Gradescope 密码", text: $password)
            Text(status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("删除已保存的账号") {
                    CredentialsVault.deleteGradescope()
                    password = ""; status = "已删除本地记录。"
                }
                Spacer()
                Button("关闭") { dismiss() }
                Button("保存并同步") {
                    if CredentialsVault.saveGradescope(username: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) {
                        password = ""; dismiss()
                        Task { await store.sync() }
                    } else { status = "请填写邮箱和密码后重试。" }
                }.buttonStyle(.borderedProminent).disabled(email.isEmpty || password.isEmpty)
            }
        }.padding(26).frame(width: 480)
    }
}

private struct NoteSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let entry: Entry
    @State private var text: String

    init(entry: Entry) {
        self.entry = entry
        _text = State(initialValue: entry.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("动态备注").font(.title2.bold()).foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.headline).lineLimit(2)
                Text(entry.courseName).font(.caption).foregroundStyle(Palette.muted)
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 190)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            Text("备注保存在此 Mac。清空后保存即可删除备注。")
                .font(.caption).foregroundStyle(Palette.muted)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存备注") {
                    store.setNote(entry.id, text)
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 500)
        .background(Palette.canvas)
    }
}

private struct ManualSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var courseID = ""
    @State private var title = ""
    @State private var detail = ""
    @State private var due = Date().addingTimeInterval(86400)

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("添加课程作业").font(.title2.bold())
            Picker("课程", selection: $courseID) {
                ForEach(store.snapshot.courses.filter(\.selected)) { course in
                    Text(course.name).tag(course.id)
                }
            }
            TextField("作业名称", text: $title)
            TextField("作业说明（可选）", text: $detail)
            DatePicker("截止时间", selection: $due, displayedComponents: [.date, .hourAndMinute])
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") {
                    store.addManual(courseID: courseID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), detail: detail, dueAt: due)
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || courseID.isEmpty)
            }
        }.padding(26).frame(width: 440)
            .onAppear { courseID = store.snapshot.courses.first(where: \.selected)?.id ?? "" }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

private struct SourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: Store
    @State private var downloadedFile: URL?
    @State private var downloadError: String?
    @State private var displayedURL: URL?
    let entry: Entry

    private var courseURL: URL? {
        guard let raw = store.snapshot.courses.first(where: { $0.id == entry.courseID })?.url,
              let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }

    private var initialURL: URL? {
        guard let original = URL(string: entry.url), original.scheme == "https" else { return nil }
        guard original.path.hasPrefix("/bbcswebdav/") else { return original }
        if let raw = entry.sourcePageURL, let page = URL(string: raw),
           page.scheme == "https", page.host == "course.pku.edu.cn" { return page }
        return courseURL ?? original
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title).font(.headline).lineLimit(1)
                    Text(entry.courseName).font(.caption).foregroundStyle(.secondary)
                    if URL(string: entry.url)?.path.hasPrefix("/bbcswebdav/") == true {
                        Text("附件从课程页面进入").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                let safariURL = displayedURL ?? initialURL
                if let url = safariURL, url.scheme == "https" {
                    Button("在 Safari 打开") {
                        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                            NSWorkspace.shared.open([url], withApplicationAt: safari,
                                                    configuration: NSWorkspace.OpenConfiguration())
                        } else {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button("关闭") { dismiss() }
            }.padding(13)
            if let url = displayedURL ?? initialURL, url.scheme == "https" {
                ZStack {
                    WebPage(url: url, onDownloaded: { file in
                        downloadedFile = file
                        if !NSWorkspace.shared.open(file) {
                            downloadError = "文件已下载，但没有找到能打开它的应用。"
                        }
                    }, onDownloadError: { downloadError = $0 })
                    if url.path.hasPrefix("/bbcswebdav/") {
                        Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                        VStack(spacing: 14) {
                            if let downloadedFile {
                                Image(systemName: "doc.fill").font(.largeTitle).foregroundStyle(.blue)
                                Text("原文已下载").font(.headline)
                                Text(entry.title).font(.caption).foregroundStyle(.secondary)
                                Button("重新打开") { NSWorkspace.shared.open(downloadedFile) }
                                Button("在 Finder 中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([downloadedFile])
                                }
                            } else if let downloadError {
                                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                                Text(downloadError).multilineTextAlignment(.center)
                                if let courseURL {
                                    Button("打开课程页面") {
                                        displayedURL = courseURL
                                        self.downloadError = nil
                                    }.buttonStyle(.borderedProminent)
                                }
                            } else {
                                ProgressView("正在下载并打开原文…")
                            }
                        }.padding(30)
                    }
                }
                if let downloadError, !url.path.hasPrefix("/bbcswebdav/") {
                    Text(downloadError).font(.caption).foregroundStyle(.red).padding(8)
                }
            } else {
                Text("原文链接无效").foregroundStyle(.secondary)
            }
        }.frame(width: 1050, height: 760)
    }
}

private struct BrowserSheet: View {
    let url: URL
    let title: String
    let buttonTitle: String
    let done: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(buttonTitle, action: done).buttonStyle(.borderedProminent)
            }.padding(13)
            WebPage(url: url)
        }.frame(width: 850, height: 670)
    }
}

private struct WebPage: NSViewRepresentable {
    let url: URL
    var onDownloaded: ((URL) -> Void)? = nil
    var onDownloadError: ((String) -> Void)? = nil

    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        var requestedURL: URL?
        var onDownloaded: ((URL) -> Void)?
        var onDownloadError: ((String) -> Void)?
        private var destinations: [ObjectIdentifier: URL] = [:]

        init(onDownloaded: ((URL) -> Void)?, onDownloadError: ((String) -> Void)?) {
            self.onDownloaded = onDownloaded
            self.onDownloadError = onDownloadError
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard onDownloaded != nil, navigationResponse.isForMainFrame else {
                decisionHandler(.allow); return
            }
            if let http = navigationResponse.response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                onDownloadError?(http.statusCode == 401
                                 ? "附件站点拒绝直接访问，请从课程页面进入。"
                                 : "原文服务器返回错误（\(http.statusCode)），请稍后重试。")
                decisionHandler(.cancel); return
            }
            let isAttachment = navigationResponse.response.url?.path.hasPrefix("/bbcswebdav/") == true
            decisionHandler(isAttachment || !navigationResponse.canShowMIMEType ? .download : .allow)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                     didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if onDownloaded != nil && challenge.protectionSpace.host == "course.pku.edu.cn" &&
                challenge.protectionSpace.authenticationMethod != NSURLAuthenticationMethodServerTrust {
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CourseWatch/Originals", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let filename = URL(fileURLWithPath: suggestedFilename).lastPathComponent
                let safeName = filename.isEmpty ? "课程附件" : filename
                let destination = directory.appendingPathComponent(safeName)
                destinations[ObjectIdentifier(download)] = destination
                completionHandler(destination)
            } catch {
                onDownloadError?("无法保存课程附件：\(error.localizedDescription)")
                completionHandler(nil)
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let destination = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
            onDownloaded?(destination)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            destinations.removeValue(forKey: ObjectIdentifier(download))
            onDownloadError?("原文下载失败：\(error.localizedDescription)")
        }

        func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                      completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.host == "course.pku.edu.cn" &&
                challenge.protectionSpace.authenticationMethod != NSURLAuthenticationMethodServerTrust {
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
    func makeCoordinator() -> Coordinator {
        Coordinator(onDownloaded: onDownloaded, onDownloadError: onDownloadError)
    }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.requestedURL = url
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onDownloaded = onDownloaded
        context.coordinator.onDownloadError = onDownloadError
        guard context.coordinator.requestedURL != url else { return }
        context.coordinator.requestedURL = url
        nsView.load(URLRequest(url: url))
    }
}
