import Foundation

enum Scheduler {
    static func install() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let target = launchAgents.appendingPathComponent("cn.pku.coursewatch.daily.plist")
        let bundle = Bundle.main.bundleURL.path
        let plist: [String: Any] = [
            "Label": "cn.pku.coursewatch.daily",
            "ProgramArguments": ["/usr/bin/open", "-g", "-a", bundle],
            "StartCalendarInterval": ["Hour": 9, "Minute": 0],
            "RunAtLoad": false
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        let changed = (try? Data(contentsOf: target)) != data
        guard changed else { return }
        do { try data.write(to: target, options: .atomic) } catch { return }
        let uid = getuid()
        let domain = "gui/\(uid)"
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        old.arguments = ["bootout", domain + "/cn.pku.coursewatch.daily"]
        try? old.run(); old.waitUntilExit()
        let fresh = Process()
        fresh.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        fresh.arguments = ["bootstrap", domain, target.path]
        try? fresh.run(); fresh.waitUntilExit()
    }
}
