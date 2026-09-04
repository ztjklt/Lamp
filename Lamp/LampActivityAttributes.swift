import ActivityKit
import AppIntents
import Foundation

struct LampActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var taskID: String
        var title: String
        var endDate: Date
        var status: String
    }

    var startedAt: Date
}

struct CompleteLampTaskIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "完成当前任务"
    @Parameter(title: "任务 ID") var taskID: String

    init() {}
    init(taskID: String) { self.taskID = taskID }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("completed", forKey: "lamp.activity.\(taskID)")
        return .result()
    }
}

struct PartialLampTaskIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "部分完成"
    static var openAppWhenRun = true
    @Parameter(title: "任务 ID") var taskID: String

    init() {}
    init(taskID: String) { self.taskID = taskID }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("partial", forKey: "lamp.activity.\(taskID)")
        return .result()
    }
}

