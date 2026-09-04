import ActivityKit
import Foundation

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

    static func update(blockID: UUID, status: String) async {
        guard let activity = Activity<LampActivityAttributes>.activities.first(where: {
            $0.content.state.taskID == blockID.uuidString
        }) else { return }
        var state = activity.content.state
        state.status = status
        await activity.update(ActivityContent(state: state, staleDate: state.endDate))
    }
}
