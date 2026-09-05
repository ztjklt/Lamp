import SwiftUI

struct RoadmapView: View {
    @EnvironmentObject private var store: LampStore
    @State private var expandedID: UUID?
    @State private var editingGoal: PlanItem?

    private var goals: [PlanItem] { store.planItems.filter { $0.kind == .goal } }
    private var upcoming: [PlanItem] {
        store.planItems
            .filter { $0.kind != .goal && $0.deadline != nil && $0.remainingMinutes > 0 }
            .sorted { $0.deadline! < $1.deadline! }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LampTheme.Spacing.section) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("路线").font(.largeTitle.bold())
                        Text("方向稳定，路径可以随现实改变。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(goals) { goal in goalCard(goal) }
                    SectionLabel(title: "接下来")
                    if upcoming.isEmpty {
                        LampCard {
                            Label("暂时没有带截止日期的下一步。", systemImage: "flag.checkered")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(Array(upcoming.prefix(6).enumerated()), id: \.element.id) { index, item in
                            milestone(item, highlighted: index == 0)
                        }
                    }
                }
                .padding(.horizontal, LampTheme.Spacing.page)
                .padding(.top, 20)
                .padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
            .navigationBarHidden(true)
            .lampPage()
            .sheet(item: $editingGoal) { GoalEditorView(goal: $0) }
        }
    }

    private func goalCard(_ goal: PlanItem) -> some View {
        LampCard {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    withAnimation(.snappy) { expandedID = expandedID == goal.id ? nil : goal.id }
                } label: {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(goal.title).font(.title3.bold()).foregroundStyle(LampTheme.ink)
                                Text(goal.detail)
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Text(goal.progress, format: .percent.precision(.fractionLength(0)))
                                .font(.headline.monospacedDigit()).foregroundStyle(LampTheme.amber)
                        }
                        ProgressView(value: goal.progress).tint(LampTheme.amber)
                        HStack {
                            Label("已安排 \(store.scheduledSessions(for: goal)) 个时段", systemImage: "calendar.badge.clock")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: expandedID == goal.id ? "chevron.up" : "chevron.down")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("roadmap.goal.\(goal.id.uuidString)")

                if expandedID == goal.id {
                    Divider()
                    let children = store.planItems.filter { $0.parentID == goal.id }
                    if children.isEmpty {
                        Text("目前没有直接关联的下一步。你可以编辑目标，或告诉 Lamp 创建行动。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(children) { child in
                            HStack {
                                Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(LampTheme.amber)
                                Text(child.title).font(.subheadline)
                                Spacer()
                                Text(child.progress, format: .percent.precision(.fractionLength(0)))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button {
                        editingGoal = goal
                    } label: {
                        Label("编辑目标", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.lamp)
                    .accessibilityIdentifier("roadmap.edit.\(goal.id.uuidString)")
                }
            }
        }
    }

    private func milestone(_ item: PlanItem, highlighted: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Circle()
                    .fill(highlighted ? LampTheme.amber : LampTheme.secondaryBackground)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(LampTheme.amber, lineWidth: 2))
                Rectangle().fill(LampTheme.hairline).frame(width: 1, height: 42)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(deadlineLabel(item.deadline))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(highlighted ? LampTheme.amber : .secondary)
                Text(item.title).font(.body.weight(.medium))
                Text("剩余约 \(item.remainingMinutes) 分钟")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func deadlineLabel(_ date: Date?) -> String {
        guard let date else { return "未设截止日期" }
        if Calendar.current.isDateInToday(date) { return "今天" }
        let days = Calendar.current.dateComponents([.day], from: .now, to: date).day ?? 0
        return days > 0 ? "\(days) 天内" : date.formatted(date: .abbreviated, time: .omitted)
    }
}

struct GoalEditorView: View {
    @EnvironmentObject private var store: LampStore
    @Environment(\.dismiss) private var dismiss
    let goal: PlanItem
    @State private var title: String
    @State private var detail: String
    @State private var showingDeleteConfirmation = false

    init(goal: PlanItem) {
        self.goal = goal
        _title = State(initialValue: goal.title)
        _detail = State(initialValue: goal.detail)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("目标") {
                    TextField("标题", text: $title)
                        .accessibilityIdentifier("goalEditor.title")
                    TextField("这条路线最终要带你去哪里？", text: $detail, axis: .vertical)
                        .lineLimit(3...7)
                        .accessibilityIdentifier("goalEditor.detail")
                }
                Section {
                    Text("修改目标不会静默重写日程；需要大范围调整时 Lamp 会先展示预览。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("删除年度目标", systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("goalEditor.delete")
                } footer: {
                    Text("关联计划会保留并转为未关联，直接关联的时间块会删除。")
                }
            }
            .navigationTitle("编辑目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.updateGoal(goal, title: title, detail: detail)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("goalEditor.save")
                }
            }
        }
        .alert("删除年度目标？", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除目标", role: .destructive) {
                if store.deletePlanItem(goal) { dismiss() }
            }
            .accessibilityIdentifier("goalEditor.confirmDelete")
        } message: {
            Text("将删除“\(goal.title)”。关联计划会保留并转为未关联；删除后可以撤销。")
        }
    }
}
