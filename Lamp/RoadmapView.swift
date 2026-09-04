import SwiftUI

struct RoadmapView: View {
    @EnvironmentObject private var store: LampStore
    @State private var expandedID: UUID?

    private var goals: [PlanItem] { store.planItems.filter { $0.kind == .goal } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("路线").font(.largeTitle.bold())
                    Text("方向稳定，路径可以随现实改变。").foregroundStyle(.secondary)
                }
                ForEach(goals) { goal in
                    goalCard(goal)
                }
                SectionLabel(title: "接下来")
                milestone("今天", "完成 Tool Calling 天气工具", true)
                milestone("8 天内", "完成微积分考试复习", false)
                milestone("本月", "做出第一个可用的 AI Agent", false)
                milestone("本季度", "完成三家公司财报拆解", false)
            }
            .padding(.horizontal, 20).padding(.top, 20)
        }
        .scrollIndicators(.hidden)
    }

    private func goalCard(_ goal: PlanItem) -> some View {
        Button { withAnimation(.snappy) { expandedID = expandedID == goal.id ? nil : goal.id } } label: {
            LampCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(goal.title).font(.title3.bold()).foregroundStyle(LampTheme.ink)
                            Text(goal.detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Text("\(Int(goal.progress * 100))%")
                            .font(.headline.monospacedDigit()).foregroundStyle(LampTheme.amber)
                    }
                    ProgressView(value: goal.progress).tint(LampTheme.amber)
                    HStack {
                        Label("本周 3 个时段", systemImage: "calendar.badge.clock").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: expandedID == goal.id ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                    if expandedID == goal.id {
                        Divider()
                        Text("Lamp 会根据完成速度、依赖和新截止日期动态调整这条路线。重大变化会先让你确认。")
                            .font(.caption).foregroundStyle(LampTheme.muted).multilineTextAlignment(.leading)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func milestone(_ time: String, _ title: String, _ highlighted: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Circle().fill(highlighted ? LampTheme.amber : .white).frame(width: 13, height: 13).overlay(Circle().stroke(LampTheme.amber, lineWidth: 2))
                Rectangle().fill(.black.opacity(0.08)).frame(width: 1, height: 42)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(time).font(.caption.weight(.semibold)).foregroundStyle(highlighted ? LampTheme.amber : .secondary)
                Text(title).font(.body.weight(.medium))
            }
            Spacer()
        }
    }
}

