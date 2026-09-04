import ActivityKit
import AppIntents
import Foundation

enum LampShared {
    static let appGroup = "group.com.lamp.planner"
    static let eventsKey = "lamp.shared.events"
}

enum LampSharedActionKind: String, Codable {
    case openToday
    case tellLamp
    case completeTask
    case partialTask
}

struct LampSharedAction: Codable, Identifiable {
    var id: UUID
    var kind: LampSharedActionKind
    var taskID: String?
    var createdAt: Date

    init(kind: LampSharedActionKind, taskID: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.taskID = taskID
        self.createdAt = .now
    }
}

enum LampSharedActionQueue {
    static func enqueue(_ action: LampSharedAction) {
        guard let defaults = UserDefaults(suiteName: LampShared.appGroup) else { return }
        var events = read(defaults)
        events.append(action)
        if let data = try? JSONEncoder().encode(Array(events.suffix(30))) {
            defaults.set(data, forKey: LampShared.eventsKey)
        }
    }

    static func drain() -> [LampSharedAction] {
        guard let defaults = UserDefaults(suiteName: LampShared.appGroup) else { return [] }
        let events = read(defaults)
        defaults.removeObject(forKey: LampShared.eventsKey)
        return events
    }

    private static func read(_ defaults: UserDefaults) -> [LampSharedAction] {
        guard let data = defaults.data(forKey: LampShared.eventsKey) else { return [] }
        return (try? JSONDecoder().decode([LampSharedAction].self, from: data)) ?? []
    }
}

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
        LampSharedActionQueue.enqueue(LampSharedAction(kind: .completeTask, taskID: taskID))
        if let activity = Activity<LampActivityAttributes>.activities.first(where: { $0.content.state.taskID == taskID }) {
            var state = activity.content.state
            state.status = "completed"
            await activity.update(ActivityContent(state: state, staleDate: state.endDate))
        }
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
        LampSharedActionQueue.enqueue(LampSharedAction(kind: .partialTask, taskID: taskID))
        return .result()
    }
}
