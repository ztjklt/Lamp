import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: LampStore
    @EnvironmentObject private var router: AppRouter
    var showTellLamp: () -> Void

    private var dayTitle: String {
        Date.now.formatted(.dateTime.month(.wide).day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LampTheme.Spacing.section) {
                    header
                    nowSection
                    SectionLabel(
                        title: "Today",
                        trailing: "专注 \(store.focusMinutesToday / 60) 小时 \(store.focusMinutesToday % 60) 分"
                    )
                    timeline
                }
                .padding(.horizontal, LampTheme.Spacing.page)
                .padding(.top, 18)
                .padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
            .navigationBarHidden(true)
            .lampPage()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting).font(.largeTitle.bold()).foregroundStyle(LampTheme.ink)
                Text(dayTitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: showTellLamp) {
                LampLight(size: 42)
                    .frame(width: 58, height: 58)
            }
            .accessibilityLabel("告诉 Lamp")
            .accessibilityIdentifier("today.lampButton")
        }
    }

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Now")
            if let block = store.currentOrNextBlock {
                LampCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(block.title)
                                    .font(.title2.bold())
                                    .foregroundStyle(LampTheme.ink)
                                Text("\(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened)) · \(block.durationMinutes) 分钟")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                router.show(.task(block.id))
                            } label: {
                                Image(systemName: "arrow.up.right")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .lampGlass(.subtle, cornerRadius: 22)
                            .accessibilityLabel("查看任务详情")
                            .accessibilityIdentifier("today.now.details")
                        }
                        ProgressView(value: progress(for: block))
                            .tint(LampTheme.amber)
                            .accessibilityLabel("当前时段进度")
                        HStack(spacing: 8) {
                            taskButton("完成", "checkmark", id: "today.now.complete") {
                                store.complete(block)
                            }
                            taskButton("部分", "circle.lefthalf.filled", id: "today.now.partial") {
                                router.show(.partial(block.id))
                            }
                            taskButton("未做", "xmark", id: "today.now.missed") {
                                router.show(.missed(block.id))
                            }
                        }
                        if !block.reason.isEmpty {
                            Label(block.reason, systemImage: "lightbulb.min")
                                .font(.caption)
                                .foregroundStyle(LampTheme.muted)
                        }
                        Button {
                            Task {
                                do {
                                    try await LampActivityManager.start(for: block)
                                    store.postStatus("已在锁屏与灵动岛跟随当前任务")
                                } catch {
                                    store.postStatus("暂时无法启动锁屏活动，请检查系统设置")
                                }
                            }
                        } label: {
                            Label("在锁屏上跟随", systemImage: "iphone.gen3")
                                .font(.caption.weight(.semibold))
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(LampTheme.ink)
                        .accessibilityIdentifier("today.now.liveActivity")
                    }
                }
            } else {
                LampCard {
                    HStack(spacing: 14) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.title2)
                            .foregroundStyle(LampTheme.sage)
                        VStack(alignment: .leading) {
                            Text("现在可以休息").font(.headline)
                            Text("Lamp 没有必要把每个空档都填满。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.todayBlocks.enumerated()), id: \.element.id) { index, block in
                HStack(alignment: .top, spacing: 13) {
                    Text(block.start.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                        .padding(.top, 15)
                    VStack(spacing: 0) {
                        Circle().fill(block.kind.color).frame(width: 9, height: 9).padding(.top, 19)
                        if index < store.todayBlocks.count - 1 {
                            Rectangle().fill(LampTheme.hairline).frame(width: 1).frame(maxHeight: .infinity)
                        }
                    }
                    Button {
                        router.show(.task(block.id))
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(block.title)
                                    .font(.body.weight(.semibold))
                                    .strikethrough(block.state == .completed)
                                    .foregroundStyle(LampTheme.ink)
                                Text("\(block.durationMinutes) 分钟 · \(block.provenance)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: block.state == .planned ? "chevron.right" : stateIcon(block.state))
                                .foregroundStyle(block.state == .completed ? LampTheme.sage : LampTheme.amber)
                        }
                        .padding(14)
                        .frame(minHeight: 64)
                        .background(LampTheme.secondaryBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .opacity(block.state == .missed ? 0.58 : 1)
                    .accessibilityIdentifier("today.timeline.\(block.id.uuidString)")
                }
                .frame(minHeight: 78)
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        if hour < 11 { return "早上好" }
        if hour < 18 { return "下午好" }
        return "晚上好"
    }

    private func progress(for block: ScheduleBlock) -> Double {
        guard Date.now >= block.start else { return 0 }
        return min(1, max(0, Date.now.timeIntervalSince(block.start) / max(1, block.end.timeIntervalSince(block.start))))
    }

    private func taskButton(
        _ title: String,
        _ icon: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .background(LampTheme.controlBackground.opacity(0.96), in: Capsule())
        .overlay(Capsule().stroke(LampTheme.hairline, lineWidth: 0.7))
        .accessibilityIdentifier(id)
    }

    private func stateIcon(_ state: CompletionState) -> String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .missed: "xmark.circle"
        case .active: "play.circle.fill"
        case .planned: "circle"
        }
    }
}

struct TaskDetailView: View {
    @EnvironmentObject private var store: LampStore
    @Environment(\.dismiss) private var dismiss
    let block: ScheduleBlock
    @State private var title: String
    @State private var start: Date
    @State private var end: Date

    init(block: ScheduleBlock) {
        self.block = block
        _title = State(initialValue: block.title)
        _start = State(initialValue: block.start)
        _end = State(initialValue: block.end)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    if block.kind == .fixed {
                        LabeledContent("名称", value: block.title)
                    } else {
                        TextField("名称", text: $title)
                            .accessibilityIdentifier("taskEditor.title")
                    }
                    LabeledContent("类型", value: block.kind == .fixed ? "固定日程" : "灵活任务")
                    LabeledContent("来源", value: block.provenance)
                }
                Section("时间") {
                    DatePicker("开始", selection: $start)
                        .disabled(block.kind == .fixed)
                    DatePicker("结束", selection: $end)
                        .disabled(block.kind == .fixed)
                }
                if !block.reason.isEmpty {
                    Section("为什么这样安排") { Text(block.reason) }
                }
                if block.kind == .fixed {
                    Section {
                        Label("固定日程需要在“\(block.provenance)”中修改，Lamp 会在下次同步后更新。", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("任务详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if block.kind != .fixed {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            if store.updateBlock(block, title: title, start: start, end: end) { dismiss() }
                        }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("taskEditor.save")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct PartialCompletionView: View {
    @EnvironmentObject private var store: LampStore
    @Environment(\.dismiss) private var dismiss
    let block: ScheduleBlock
    @State private var completedMinutes: Int
    @State private var note = ""

    init(block: ScheduleBlock) {
        self.block = block
        _completedMinutes = State(initialValue: max(5, block.durationMinutes / 2))
    }

    private var remainingMinutes: Int { max(0, block.durationMinutes - completedMinutes) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(block.title).font(.headline)
                        Text("已完成 \(completedMinutes) 分钟，剩余 \(remainingMinutes) 分钟")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Stepper("调整已完成时间", value: $completedMinutes, in: 5...max(5, block.durationMinutes), step: 5)
                        .accessibilityIdentifier("partial.minutes")
                }
                Section("发生了什么（可选）") {
                    TextField("例如：先完成了阅读，练习还没做", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("partial.note")
                }
                Section {
                    Text(remainingMinutes == 0 ? "这项任务会标记为完成。" : "剩余内容会安排到明天的合适时段。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("部分完成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("记录") {
                        if remainingMinutes == 0 {
                            store.complete(block)
                        } else {
                            store.submitPartial(block, feedback: PartialCompletionFeedback(
                                completedMinutes: completedMinutes,
                                remainingMinutes: remainingMinutes,
                                note: note
                            ))
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("partial.submit")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MissedTaskView: View {
    @EnvironmentObject private var store: LampStore
    @Environment(\.dismiss) private var dismiss
    let block: ScheduleBlock
    @State private var reason = "临时有其他事情"

    private let reasons = ["临时有其他事情", "精力不足", "预计时间不够", "任务不再需要"]

    var body: some View {
        NavigationStack {
            Form {
                Section("为什么没做") {
                    Picker("原因", selection: $reason) {
                        ForEach(reasons, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("missed.reason")
                }
                Section {
                    Text("Lamp 会先展示调整建议，不会静默改写后续计划。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("记录变化")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("查看重排") {
                        store.proposeMissed(block, reason: reason)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("missed.submit")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
