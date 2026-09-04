import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LampWidgetBundle: WidgetBundle {
    var body: some Widget {
        LampLiveActivity()
    }
}

struct LampLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LampActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Circle()
                    .fill(RadialGradient(colors: [.white, .orange], center: .topLeading, startRadius: 2, endRadius: 26))
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("现在").font(.caption).foregroundStyle(.secondary)
                    Text(context.state.title).font(.headline).lineLimit(1)
                    Text(timerInterval: Date.now...context.state.endDate, countsDown: true)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                if context.state.status == "completed" {
                    Label("完成", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                } else {
                    Button(intent: PartialLampTaskIntent(taskID: context.state.taskID)) {
                        Image(systemName: "circle.lefthalf.filled")
                    }
                    .buttonStyle(.plain).tint(.orange)
                    .accessibilityLabel("部分完成")
                    Button(intent: CompleteLampTaskIntent(taskID: context.state.taskID)) {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .buttonStyle(.plain).tint(.green)
                    .accessibilityLabel("完成任务")
                }
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.97, green: 0.96, blue: 0.93))
            .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date.now...context.state.endDate, countsDown: true)
                        .font(.caption.monospacedDigit()).foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.status == "completed" {
                        Label("任务已完成", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        HStack {
                            Button(intent: PartialLampTaskIntent(taskID: context.state.taskID)) {
                                Label("部分", systemImage: "circle.lefthalf.filled")
                            }.tint(.orange)
                            Button(intent: CompleteLampTaskIntent(taskID: context.state.taskID)) {
                                Label("完成", systemImage: "checkmark")
                            }.tint(.green)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "lightbulb.fill").foregroundStyle(.orange)
            } compactTrailing: {
                Text(timerInterval: Date.now...context.state.endDate, countsDown: true)
                    .font(.caption2.monospacedDigit()).frame(width: 42)
            } minimal: {
                Image(systemName: "lightbulb.fill").foregroundStyle(.orange)
            }
            .keylineTint(.orange)
        }
    }
}
