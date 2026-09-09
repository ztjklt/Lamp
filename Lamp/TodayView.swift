import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: LampStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
            LampLight(size: 38)
                .frame(width: 54, height: 54)
                .accessibilityLabel("Lamp 已准备好")
                .accessibilityIdentifier("today.lampStatus")
        }
    }

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Now")
            if let block = store.currentOrNextBlock {
                if block.isSleep == true {
                    nowBlockContent(block, sleepStyle: true)
                        .padding(LampTheme.Spacing.card)
                        .lampSleepSurface()
                        .accessibilityIdentifier("today.now.sleep")
                } else {
                    LampCard {
                        nowBlockContent(block, sleepStyle: false)
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
                        router.show(.task(block))
                    } label: {
                        timelineCard(block)
                    }
                    .buttonStyle(.plain)
                    .opacity(block.state == .missed ? 0.58 : 1)
                    .accessibilityIdentifier(block.isSleep == true ? "today.sleepCard" : "today.timeline.\(block.id.uuidString)")
                }
                .frame(minHeight: 78)
            }
        }
    }

    private func nowBlockContent(_ block: ScheduleBlock, sleepStyle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if sleepStyle && dynamicTypeSize.isAccessibilitySize {
                nowText(block, sleepStyle: true)
                HStack {
                    Spacer()
                    LampRestAnimation(size: 84)
                    Spacer()
                }
                detailButton(block, sleepStyle: true)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    nowText(block, sleepStyle: sleepStyle)
                    Spacer(minLength: 8)
                    if sleepStyle { LampRestAnimation(size: 100) }
                    detailButton(block, sleepStyle: sleepStyle)
                }
            }
            ProgressView(value: progress(for: block))
                .tint(sleepStyle ? LampSleepTheme.accent : LampTheme.amber)
                .accessibilityLabel("当前时段进度")
            HStack(spacing: 8) {
                taskButton("完成", "checkmark", id: "today.now.complete", sleepStyle: sleepStyle) { store.complete(block) }
                taskButton("部分", "circle.lefthalf.filled", id: "today.now.partial", sleepStyle: sleepStyle) { router.show(.partial(block)) }
                taskButton("未做", "xmark", id: "today.now.missed", sleepStyle: sleepStyle) { router.show(.missed(block)) }
            }
            if !block.reason.isEmpty {
                Label(block.reason, systemImage: "lightbulb.min")
                    .font(.caption)
                    .foregroundStyle(sleepStyle ? LampSleepTheme.secondary : LampTheme.muted)
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
            .foregroundStyle(sleepStyle ? LampSleepTheme.foreground : LampTheme.ink)
            .accessibilityIdentifier("today.now.liveActivity")
        }
    }

    private func nowText(_ block: ScheduleBlock, sleepStyle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if sleepStyle {
                Label("睡眠时间", systemImage: "moon.stars.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LampSleepTheme.accent)
            }
            Text(block.title)
                .font(.title2.bold())
                .foregroundStyle(sleepStyle ? LampSleepTheme.foreground : LampTheme.ink)
            Text("\(block.displayTime) · \(block.durationMinutes) 分钟")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(sleepStyle ? LampSleepTheme.secondary : Color.secondary)
        }
    }

    private func detailButton(_ block: ScheduleBlock, sleepStyle: Bool) -> some View {
        Button { router.show(.task(block)) } label: {
            Image(systemName: "arrow.up.right").frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(sleepStyle ? LampSleepTheme.foreground : LampTheme.ink)
        .lampGlass(.subtle, cornerRadius: 22)
        .accessibilityLabel("查看任务详情")
        .accessibilityIdentifier("today.now.details")
    }

    @ViewBuilder private func timelineCard(_ block: ScheduleBlock) -> some View {
        if block.isSleep == true {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        sleepTimelineText(block)
                        HStack {
                            Spacer()
                            LampRestAnimation(size: 72)
                            Spacer()
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 10) {
                        sleepTimelineText(block)
                        Spacer(minLength: 4)
                        LampRestAnimation(size: 88)
                        Image(systemName: block.state == .planned ? "chevron.right" : stateIcon(block.state))
                            .foregroundStyle(block.state == .completed ? LampTheme.sage : LampSleepTheme.accent)
                    }
                }
            }
            .padding(12)
            .frame(minHeight: 92)
            .lampSleepSurface(cornerRadius: 18, highlighted: store.highlightedBlockIDs.contains(block.id))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(block.title)，\(block.displayTime)，\(block.provenance)")
        } else {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(block.title)
                        .font(.body.weight(.semibold))
                        .strikethrough(block.state == .completed)
                        .foregroundStyle(LampTheme.ink)
                    Text("\(block.displayTime) · \(block.provenance)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: block.state == .planned ? "chevron.right" : stateIcon(block.state))
                    .foregroundStyle(block.state == .completed ? LampTheme.sage : LampTheme.amber)
            }
            .padding(14)
            .frame(minHeight: 64)
            .background(LampTheme.secondaryBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        store.highlightedBlockIDs.contains(block.id) ? LampTheme.amber : LampTheme.hairline,
                        lineWidth: store.highlightedBlockIDs.contains(block.id) ? 2 : 0.8
                    )
            }
        }
    }

    private func sleepTimelineText(_ block: ScheduleBlock) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(block.title, systemImage: "moon.stars.fill")
                .font(.body.weight(.semibold))
                .strikethrough(block.state == .completed)
                .foregroundStyle(LampSleepTheme.foreground)
            Text(block.displayTime)
                .font(.caption.monospacedDigit())
                .foregroundStyle(LampSleepTheme.secondary)
            Text(block.provenance)
                .font(.caption2)
                .foregroundStyle(LampSleepTheme.secondary.opacity(0.86))
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
        sleepStyle: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(sleepStyle ? LampSleepTheme.foreground : LampTheme.ink)
        .background(sleepStyle ? Color.white.opacity(0.11) : LampTheme.controlBackground.opacity(0.96), in: Capsule())
        .overlay(Capsule().stroke(sleepStyle ? Color.white.opacity(0.18) : LampTheme.hairline, lineWidth: 0.7))
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
    @State private var showingDeleteConfirmation = false
    @State private var showingRecurringDeleteOptions = false

    private var canEdit: Bool {
        block.kind != .fixed
    }

    init(block: ScheduleBlock) {
        self.block = block
        _title = State(initialValue: block.title)
        _start = State(initialValue: block.start)
        _end = State(initialValue: block.end)
    }

    var body: some View {
        NavigationStack {
            Form {
                if block.isSleep == true {
                    Section {
                        VStack(spacing: 4) {
                            LampRestAnimation(size: 132)
                            Label("舒缓入睡", systemImage: "moon.stars.fill")
                                .font(.headline)
                                .foregroundStyle(LampSleepTheme.foreground)
                            Text(block.displayTime)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(LampSleepTheme.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .lampSleepSurface(cornerRadius: 22)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("睡眠，\(block.displayTime)")
                        .accessibilityIdentifier("task.sleepHero")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
                Section("任务") {
                    if !canEdit {
                        LabeledContent("名称", value: block.title)
                    } else {
                        TextField("名称", text: $title)
                            .accessibilityIdentifier("taskEditor.title")
                    }
                    LabeledContent("类型", value: blockTypeLabel)
                    LabeledContent("来源", value: block.provenance)
                }
                Section("时间") {
                    DatePicker("开始", selection: $start)
                        .disabled(!canEdit)
                    DatePicker("结束", selection: $end)
                        .disabled(!canEdit)
                }
                if !block.reason.isEmpty {
                    Section("为什么这样安排") { Text(block.reason) }
                }
                if !canEdit {
                    Section {
                        Label("固定日程不能在 Lamp 中改写，但可以从 Lamp 删除；外部来源不会受影响。", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                } else if block.recurringRuleID != nil {
                    Section {
                        Label("保存只会修改这一次，其他重复日程保持不变。", systemImage: "repeat.1")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        if block.recurringRuleID == nil {
                            showingDeleteConfirmation = true
                        } else {
                            showingRecurringDeleteOptions = true
                        }
                    } label: {
                        Label("删除日程", systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("taskEditor.delete")
                } footer: {
                    Text(block.kind == .fixed
                         ? "只会从 Lamp 删除，不会修改“\(block.provenance)”中的原日程。"
                         : "删除后可以通过顶部提示立即撤销。")
                }
            }
            .navigationTitle("任务详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if canEdit {
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
        .alert("从 Lamp 删除这条日程？", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除日程", role: .destructive) { deleteBlock(scope: .singleOccurrence) }
                .accessibilityIdentifier("taskEditor.confirmDelete")
        } message: {
            Text("将删除“\(block.title)”。\(block.kind == .fixed ? "“\(block.provenance)”中的原日程不会改变。" : "关联任务本身会继续保留。")")
        }
        .confirmationDialog("删除重复日程", isPresented: $showingRecurringDeleteOptions, titleVisibility: .visible) {
            Button("仅删除本次", role: .destructive) { deleteBlock(scope: .singleOccurrence) }
                .accessibilityIdentifier("taskEditor.deleteSingle")
            Button("删除整个重复日程", role: .destructive) { deleteBlock(scope: .entireSeries) }
                .accessibilityIdentifier("taskEditor.deleteSeries")
            Button("取消", role: .cancel) {}
        } message: {
            Text("“\(block.title)”是重复日程。请选择只删除这一次，或删除整个系列。")
        }
    }

    private var blockTypeLabel: String {
        switch block.kind {
        case .fixed: "固定日程"
        case .focus: "灵活任务"
        case .breakTime: "休息"
        case .free: "空闲"
        }
    }

    private func deleteBlock(scope: ScheduleDeletionScope) {
        if store.deleteScheduleBlock(block, scope: scope) { dismiss() }
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
    @State private var isSubmitting = false

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
                    Button {
                        isSubmitting = true
                        Task {
                            do {
                                try await store.proposeMissedWithAgent(block, reason: reason)
                            } catch {
                                store.toast = "未完成已记录，但暂时无法生成重排"
                            }
                            dismiss()
                        }
                    } label: {
                        if isSubmitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("查看重排")
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("missed.submit")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
