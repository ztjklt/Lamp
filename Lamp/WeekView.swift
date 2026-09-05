import SwiftUI

struct ScheduleView: View {
    @EnvironmentObject private var store: LampStore
    @EnvironmentObject private var router: AppRouter
    @State private var timeframe: PlanTimeframe = .week
    @State private var anchorDate = Date.now
    @State private var selectedDay = Calendar.autoupdatingCurrent.startOfDay(for: .now)
    @State private var editorContext: PlanEditorContext?

    private var calendar: Calendar { .autoupdatingCurrent }
    private var interval: DateInterval { store.periodInterval(for: timeframe, containing: anchorDate) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LampTheme.Spacing.section) {
                    header
                    Picker("时间层级", selection: $timeframe) {
                        ForEach(PlanTimeframe.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("schedule.timeframe")
                    periodNavigator
                    switch timeframe {
                    case .week: weekContent
                    case .month: monthContent
                    case .year: yearContent
                    }
                }
                .padding(.horizontal, LampTheme.Spacing.page)
                .padding(.top, 20)
                .padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
            .navigationBarHidden(true)
            .lampPage()
            .sheet(item: $editorContext) { PlanEditorView(context: $0) }
            .onChange(of: timeframe) { _, newValue in
                anchorDate = store.periodInterval(for: newValue, containing: anchorDate).start
                if newValue == .week { selectedDay = anchorDate }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("日程").font(.largeTitle.bold())
                Text("从今天排到今年，让长期目标落进现实。").foregroundStyle(.secondary)
            }
            Spacer()
            Button { editorContext = PlanEditorContext(timeframe: timeframe, anchorDate: anchorDate) } label: {
                Image(systemName: "plus").font(.headline).frame(width: 44, height: 44)
                    .background(LampTheme.amber.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新增\(timeframe.title)计划")
            .accessibilityIdentifier("schedule.add")
        }
    }

    private var periodNavigator: some View {
        HStack(spacing: 10) {
            navButton("chevron.left", label: "上一个\(timeframe.title)", id: "schedule.previous") { movePeriod(-1) }
            Button { returnToCurrentPeriod() } label: {
                VStack(spacing: 2) {
                    Text(periodTitle).font(.headline.monospacedDigit())
                    Text(isCurrentPeriod ? "当前\(timeframe.title)" : "回到当前\(timeframe.title)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("schedule.current")
            navButton("chevron.right", label: "下一个\(timeframe.title)", id: "schedule.next") { movePeriod(1) }
        }
        .padding(.horizontal, 6)
        .lampGlass(.subtle, cornerRadius: 20)
    }

    private func navButton(_ icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 44, height: 44) }
            .buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }

    private var weekContent: some View {
        VStack(alignment: .leading, spacing: LampTheme.Spacing.section) {
            dayStrip
            summaryCard(for: .week, date: anchorDate, title: "本周概览")
            planSection(title: "本周重点", items: store.planItems(for: .week, containing: anchorDate))
            SectionLabel(title: selectedDay.formatted(.dateTime.weekday(.wide).month().day().locale(Locale(identifier: "zh_CN"))))
            selectedDayContent
            insight
        }
    }

    private var daysInWeek: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    private var dayStrip: some View {
        HStack(spacing: 7) {
            ForEach(daysInWeek, id: \.self) { day in
                let selected = calendar.isDate(day, inSameDayAs: selectedDay)
                Button { withAnimation(.snappy) { selectedDay = day } } label: {
                    VStack(spacing: 7) {
                        Text(day.formatted(.dateTime.weekday(.narrow).locale(Locale(identifier: "zh_CN")))).font(.caption)
                        Text(day.formatted(.dateTime.day())).font(.body.weight(.semibold))
                        Circle().fill(calendar.isDateInToday(day) ? LampTheme.amber : .clear).frame(width: 5, height: 5)
                    }
                    .foregroundStyle(selected ? LampTheme.onPrimaryAction : LampTheme.ink)
                    .frame(maxWidth: .infinity, minHeight: 58).padding(.vertical, 6)
                    .background(selected ? LampTheme.primaryAction : LampTheme.secondaryBackground.opacity(0.76), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day().locale(Locale(identifier: "zh_CN"))))
                .accessibilityValue(selected ? "已选择" : "")
                .accessibilityIdentifier("week.day.\(calendar.component(.weekday, from: day))")
            }
        }
    }

    @ViewBuilder private var selectedDayContent: some View {
        let selectedBlocks = store.blocks(on: selectedDay)
        if selectedBlocks.isEmpty {
            LampCard {
                Label("这一天还很空，保留空白也是计划的一部分。", systemImage: "wind")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            ForEach(selectedBlocks) { block in
                Button { router.show(.task(block)) } label: {
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 2).fill(block.kind.color).frame(width: 4, height: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(block.title).font(.body.weight(.semibold)).foregroundStyle(LampTheme.ink)
                            Text("\(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(block.kind == .fixed ? "固定" : "灵活").font(.caption2.weight(.medium)).foregroundStyle(block.kind.color)
                            .padding(.horizontal, 8).padding(.vertical, 5).background(block.kind.color.opacity(0.12), in: Capsule())
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(14).background(LampTheme.secondaryBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain).accessibilityIdentifier("week.block.\(block.id.uuidString)")
            }
        }
    }

    private var monthContent: some View {
        VStack(alignment: .leading, spacing: LampTheme.Spacing.section) {
            monthCalendar
            summaryCard(for: .month, date: anchorDate, title: "本月概览")
            planSection(title: "本月重点", items: store.planItems(for: .month, containing: anchorDate))
        }
    }

    private var monthCalendar: some View {
        let count = calendar.range(of: .day, in: .month, for: interval.start)?.count ?? 30
        let leading = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        let cells: [Date?] = Array(repeating: nil, count: leading) + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: interval.start) }
        let summary = store.scheduleSummary(for: .month, containing: anchorDate)
        let maximum = max(1, summary.focusMinutesByDay.values.max() ?? 1)
        return LampCard {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                ForEach(rotatedWeekdaySymbols, id: \.self) { Text($0).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let milestoneCount = store.planItems(for: .month, containing: anchorDate).filter {
                            $0.deadline.map { calendar.isDate($0, inSameDayAs: day) } ?? false
                        }.count
                        Button {
                            selectedDay = day; anchorDate = day; timeframe = .week
                        } label: {
                            VStack(spacing: 4) {
                                Text(day.formatted(.dateTime.day())).font(.subheadline.weight(calendar.isDateInToday(day) ? .bold : .regular))
                                HStack(spacing: 3) {
                                    Capsule().fill(LampTheme.amber.opacity(0.18 + 0.72 * Double(summary.focusMinutesByDay[calendar.startOfDay(for: day), default: 0]) / Double(maximum))).frame(width: 18, height: 4)
                                    if milestoneCount > 0 { Circle().fill(LampTheme.sage).frame(width: 5, height: 5) }
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(calendar.isDateInToday(day) ? LampTheme.amber.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain).accessibilityLabel(monthDayAccessibility(day))
                        .accessibilityIdentifier("schedule.month.day.\(calendar.component(.day, from: day))")
                    } else { Color.clear.frame(minHeight: 44) }
                }
            }
        }
    }

    private var yearContent: some View {
        VStack(alignment: .leading, spacing: LampTheme.Spacing.section) {
            summaryCard(for: .year, date: anchorDate, title: "年度概览")
            SectionLabel(title: "12 个月")
            yearGrid
            planSection(title: "年度重点", items: store.planItems(for: .year, containing: anchorDate))
            quarterSections
            if !store.unassignedGoals().isEmpty { planSection(title: "待安排时间层级", items: store.unassignedGoals()) }
        }
    }

    private var yearGrid: some View {
        let start = store.periodInterval(for: .year, containing: anchorDate).start
        let months = (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: start) }
        let summaries = months.map { store.scheduleSummary(for: .month, containing: $0) }
        let maximum = max(1, summaries.map(\.focusMinutes).max() ?? 1)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(Array(months.enumerated()), id: \.offset) { index, month in
                let monthPlans = store.planItems(for: .month, containing: month)
                let monthInterval = store.periodInterval(for: .month, containing: month)
                let deadlineCount = store.planItems.filter { $0.deadline.map(monthInterval.contains) ?? false }.count
                let progress = monthPlans.isEmpty ? 0 : monthPlans.map(\.progress).reduce(0, +) / Double(monthPlans.count)
                Button { anchorDate = month; timeframe = .month } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(month.formatted(.dateTime.month(.wide).locale(Locale(identifier: "zh_CN")))).font(.headline).foregroundStyle(LampTheme.ink)
                        HStack {
                            Text("\(summaries[index].focusMinutes / 60) 小时专注")
                            Spacer()
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                        }.font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: Double(summaries[index].focusMinutes), total: Double(maximum)).tint(LampTheme.amber)
                        Text("\(monthPlans.count) 个里程碑 · \(deadlineCount) 项截止").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(LampTheme.secondaryBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain).accessibilityIdentifier("schedule.year.month.\(index + 1)")
            }
        }
    }

    private var quarterSections: some View {
        let yearStart = store.periodInterval(for: .year, containing: anchorDate).start
        return VStack(alignment: .leading, spacing: 14) {
            SectionLabel(title: "季度重点")
            ForEach(1...4, id: \.self) { quarter in
                let start = calendar.date(byAdding: .month, value: (quarter - 1) * 3, to: yearStart) ?? yearStart
                let end = calendar.date(byAdding: .month, value: 3, to: start) ?? start
                let items = store.planItems(in: DateInterval(start: start, end: end)).filter { $0.kind != .goal }
                LampCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("第 \(quarter) 季度").font(.headline)
                        if items.isEmpty { Text("还没有安排里程碑").font(.subheadline).foregroundStyle(.secondary) }
                        else {
                            ForEach(items.prefix(5)) { item in
                                Button { editorContext = context(for: item) } label: {
                                    HStack {
                                        Image(systemName: "flag.fill").foregroundStyle(LampTheme.amber)
                                        Text(item.title).foregroundStyle(LampTheme.ink); Spacer()
                                        Text(item.progress, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func summaryCard(for scope: PlanTimeframe, date: Date, title: String) -> some View {
        let summary = store.scheduleSummary(for: scope, containing: date)
        return LampCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        Text("共 \(summary.blockCount) 个日程 · \(summary.fixedEventCount) 个固定事项").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(summary.focusMinutes / 60)h \(summary.focusMinutes % 60)m").font(.title3.bold().monospacedDigit()).foregroundStyle(LampTheme.amber)
                }
                ProgressView(value: summary.completion).tint(LampTheme.sage)
                Text(summary.focusMinutes == 0 ? "还没有专注安排" : "已完成专注安排的 \(Int(summary.completion * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func planSection(title: String, items: [PlanItem]) -> some View {
        SectionLabel(title: title, trailing: items.isEmpty ? nil : "\(items.count) 项")
        if items.isEmpty {
            LampCard { Label("这里还没有计划，点右上角 ＋ 开始。", systemImage: "calendar.badge.plus").font(.subheadline).foregroundStyle(.secondary) }
        } else {
            ForEach(items) { item in
                Button { editorContext = context(for: item) } label: {
                    HStack(spacing: 13) {
                        Image(systemName: planIcon(item.kind)).foregroundStyle(LampTheme.amber).frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.body.weight(.semibold)).foregroundStyle(LampTheme.ink)
                            Text(planSubtitle(item)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(item.progress, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(14).background(LampTheme.secondaryBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain).accessibilityIdentifier("schedule.plan.\(item.id.uuidString)")
            }
        }
    }

    private var insight: some View {
        let nearest = store.planItems(in: interval).filter { $0.deadline != nil && $0.remainingMinutes > 0 }
            .sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }.first
        return HStack(alignment: .top, spacing: 13) {
            LampLight(size: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text("Lamp 的观察").font(.subheadline.weight(.semibold))
                Text(insightText(nearest)).font(.subheadline).foregroundStyle(LampTheme.muted).lineSpacing(3)
            }
        }.padding(16).background(LampTheme.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var periodTitle: String {
        switch timeframe {
        case .week:
            let end = calendar.date(byAdding: .day, value: 6, to: interval.start) ?? interval.start
            return "\(interval.start.formatted(.dateTime.month().day())) – \(end.formatted(.dateTime.month().day()))"
        case .month: return anchorDate.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN")))
        case .year: return anchorDate.formatted(.dateTime.year().locale(Locale(identifier: "zh_CN")))
        }
    }

    private var isCurrentPeriod: Bool {
        calendar.isDate(interval.start, inSameDayAs: store.periodInterval(for: timeframe, containing: .now).start)
    }

    private var rotatedWeekdaySymbols: [String] {
        let source = calendar.veryShortStandaloneWeekdaySymbols
        let offset = max(0, calendar.firstWeekday - 1)
        return Array(source[offset...] + source[..<offset])
    }

    private func movePeriod(_ value: Int) {
        let component: Calendar.Component = switch timeframe { case .week: .weekOfYear; case .month: .month; case .year: .year }
        guard let moved = calendar.date(byAdding: component, value: value, to: anchorDate) else { return }
        withAnimation(.snappy) { anchorDate = moved; if timeframe == .week { selectedDay = store.periodInterval(for: .week, containing: moved).start } }
    }

    private func returnToCurrentPeriod() {
        withAnimation(.snappy) { anchorDate = .now; if timeframe == .week { selectedDay = calendar.startOfDay(for: .now) } }
    }

    private func context(for item: PlanItem) -> PlanEditorContext {
        let scope = item.planningPeriod?.timeframe ?? inferredScope(for: item)
        return PlanEditorContext(timeframe: scope, anchorDate: item.planningPeriod?.anchorDate ?? item.deadline ?? anchorDate, item: item)
    }

    private func inferredScope(for item: PlanItem) -> PlanTimeframe {
        switch item.kind { case .goal: .year; case .milestone, .project: .month; default: .week }
    }

    private func planIcon(_ kind: PlanKind) -> String {
        switch kind { case .goal: "scope"; case .milestone: "flag.fill"; case .project: "folder.fill"; default: "checkmark.circle.fill" }
    }

    private func planSubtitle(_ item: PlanItem) -> String {
        if let deadline = item.deadline { return "目标 \(deadline.formatted(date: .abbreviated, time: .omitted)) · 优先级 \(item.importance)" }
        return item.detail.isEmpty ? "优先级 \(item.importance)" : item.detail
    }

    private func monthDayAccessibility(_ day: Date) -> String {
        let milestones = store.planItems(for: .month, containing: day).filter {
            $0.deadline.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        }.count
        return "\(day.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))，专注 \(store.focusMinutes(on: day)) 分钟，\(milestones) 个里程碑"
    }

    private func insightText(_ item: PlanItem?) -> String {
        guard let item, let deadline = item.deadline else { return "这一周没有迫近的截止日期。Lamp 会继续保留恢复时间和可调整空间。" }
        let days = max(0, calendar.dateComponents([.day], from: .now, to: deadline).day ?? 0)
        return "“\(item.title)”还有 \(days) 天，剩余约 \(item.remainingMinutes) 分钟。当前安排会优先保护它的合适时段。"
    }
}

struct PlanEditorContext: Identifiable, Hashable {
    let id = UUID()
    var timeframe: PlanTimeframe
    var anchorDate: Date
    var item: PlanItem?
}

private struct PlanEditorView: View {
    @EnvironmentObject private var store: LampStore
    @Environment(\.dismiss) private var dismiss
    let context: PlanEditorContext
    @State private var title: String
    @State private var detail: String
    @State private var importance: Int
    @State private var estimatedMinutes: Int
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var parentID: UUID?

    init(context: PlanEditorContext) {
        self.context = context
        let item = context.item
        let component: Calendar.Component = switch context.timeframe { case .week: .weekOfYear; case .month: .month; case .year: .year }
        let interval = Calendar.autoupdatingCurrent.dateInterval(of: component, for: context.anchorDate) ?? DateInterval(start: context.anchorDate, duration: 86_400)
        _title = State(initialValue: item?.title ?? "")
        _detail = State(initialValue: item?.detail ?? "")
        _importance = State(initialValue: item?.importance ?? 3)
        _estimatedMinutes = State(initialValue: item?.estimatedMinutes ?? 60)
        _hasDeadline = State(initialValue: item?.deadline != nil || context.timeframe != .year)
        _deadline = State(initialValue: item?.deadline ?? interval.end.addingTimeInterval(-86_400))
        _parentID = State(initialValue: item?.parentID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("\(context.timeframe.title)计划") {
                    TextField("标题", text: $title).accessibilityIdentifier("planEditor.title")
                    TextField("说明", text: $detail, axis: .vertical).lineLimit(2...5)
                    Stepper("优先级：\(importance)", value: $importance, in: 1...5)
                    if context.timeframe == .week { Stepper("预计用时：\(estimatedMinutes) 分钟", value: $estimatedMinutes, in: 30...480, step: 30) }
                }
                Section("目标时间") {
                    LabeledContent("时间层级", value: context.timeframe.title)
                    Toggle("设置目标日期", isOn: $hasDeadline)
                    if hasDeadline { DatePicker("目标日期", selection: $deadline, in: allowedDates, displayedComponents: .date) }
                }
                if !parentGoals.isEmpty, context.timeframe != .year {
                    Section("关联年度目标") {
                        Picker("上级目标", selection: $parentID) {
                            Text("不关联").tag(UUID?.none)
                            ForEach(parentGoals) { Text($0.title).tag(Optional($0.id)) }
                        }
                    }
                }
                if context.timeframe == .week, context.item == nil {
                    Section { Text("保存后会先展示排程预览，确认前不会修改时间线。").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(context.item == nil ? "新增计划" : "编辑计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .fontWeight(.semibold).accessibilityIdentifier("planEditor.save")
                }
            }
        }
    }

    private var parentGoals: [PlanItem] { store.planItems.filter { $0.kind == .goal && $0.id != context.item?.id } }
    private var allowedDates: ClosedRange<Date> {
        let range = store.periodInterval(for: context.timeframe, containing: context.anchorDate)
        return range.start...range.end.addingTimeInterval(-1)
    }

    private func save() {
        let target = hasDeadline ? deadline : nil
        if let item = context.item {
            store.updatePlanItem(item, title: title, detail: detail, importance: importance, timeframe: context.timeframe, anchorDate: context.anchorDate, deadline: target, estimatedMinutes: estimatedMinutes, parentID: parentID)
        } else if context.timeframe == .week {
            store.proposeWeeklyPlan(title: title, detail: detail, importance: importance, weekContaining: context.anchorDate, deadline: target, estimatedMinutes: estimatedMinutes, parentID: parentID)
        } else {
            store.createPlanItem(title: title, detail: detail, importance: importance, timeframe: context.timeframe, anchorDate: context.anchorDate, deadline: target, estimatedMinutes: estimatedMinutes, parentID: parentID)
        }
        dismiss()
    }
}

struct WeeklySchedulePreviewView: View {
    @EnvironmentObject private var store: LampStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @State private var blocks: [ScheduleBlock] = []

    var body: some View {
        NavigationStack {
            Form {
                if let proposal = store.pendingWeeklySchedule {
                    Section("待安排任务") {
                        Text(proposal.item.title).font(.headline)
                        if !proposal.item.detail.isEmpty { Text(proposal.item.detail).foregroundStyle(.secondary) }
                    }
                    ForEach(proposal.warnings, id: \.self) { warning in
                        Section { Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LampTheme.amber) }
                    }
                    Section("建议时段") {
                        ForEach($blocks) { $block in
                            VStack(alignment: .leading, spacing: 10) {
                                DatePicker("开始", selection: $block.start)
                                DatePicker("结束", selection: $block.end)
                                if let issue = store.weeklyScheduleIssue(for: block, proposalBlocks: blocks) {
                                    Label(issue, systemImage: "exclamationmark.octagon.fill").font(.caption).foregroundStyle(LampTheme.danger)
                                } else {
                                    Label(block.reason, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                                }
                            }.accessibilityIdentifier("weeklyPreview.block.\(block.id.uuidString)")
                        }
                    }
                    Section { Text("只有确认后才会同时创建任务并写入这些时间段。").font(.footnote).foregroundStyle(.secondary) }
                } else { ContentUnavailableView("预览已失效", systemImage: "calendar.badge.exclamationmark") }
            }
            .navigationTitle("周排程预览").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { store.dismissWeeklyScheduleProposal(); dismiss() }.accessibilityIdentifier("weeklyPreview.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认排入") {
                        if store.applyWeeklyScheduleProposal(blocks: blocks) { router.destination = .week; dismiss() }
                    }
                    .disabled(!canApply).fontWeight(.semibold).accessibilityIdentifier("weeklyPreview.apply")
                }
            }
            .onAppear { if blocks.isEmpty { blocks = store.pendingWeeklySchedule?.suggestedBlocks ?? [] } }
        }.interactiveDismissDisabled()
    }

    private var canApply: Bool {
        !blocks.isEmpty && blocks.allSatisfy { store.weeklyScheduleIssue(for: $0, proposalBlocks: blocks) == nil }
    }
}
