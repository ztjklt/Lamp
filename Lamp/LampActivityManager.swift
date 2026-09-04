import ActivityKit

enum LampActivityManager {
    static func start(for block: ScheduleBlock) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for activity in Activity<LampActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let attributes = LampActivityAttributes(startedAt: block.start)
        let state = LampActivityAttributes.ContentState(
            taskID: block.id.uuidString, title: block.title, endDate: block.end, status: "planned"
        )
        _ = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: block.end),
            pushType: nil
        )
    }
}
