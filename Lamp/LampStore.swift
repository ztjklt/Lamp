import Foundation
import UserNotifications

@MainActor
final class LampStore: ObservableObject {
    @Published var planItems: [PlanItem] = []
    @Published var blocks: [ScheduleBlock] = []
    @Published var memories: [MemoryFact] = []
    @Published var rules: [PlanningRule] = []
    @Published var temporaryStates: [TemporaryState] = []
    @Published var recurringSchedules: [RecurringScheduleRule] = []
    @Published var occurrenceOverrides: [ScheduleOccurrenceOverride] = []
    @Published var highlightedBlockIDs: Set<UUID> = []
    @Published var pendingReplan: ReplanProposal?
    @Published var pendingWeeklySchedule: WeeklyScheduleProposal?
    @Published var toast: String?
    @Published var undoTransaction: LampUndoTransaction?
    @Published var hasCompletedOnboarding: Bool
    @Published var onboardingProfile: OnboardingProfile?

    private let calendar: Calendar
    private let persistenceURL: URL
    private let profileKey = "lamp.onboarding.profile"

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "lamp.onboarding.complete")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.persistenceURL = base.appendingPathComponent("Lamp/snapshot.json")
        if let data = UserDefaults.standard.data(forKey: profileKey) {
            self.onboardingProfile = try? JSONDecoder().decode(OnboardingProfile.self, from: data)
        }
        load()

        if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
            apply(DemoData.snapshot(calendar: calendar))
            if ProcessInfo.processInfo.arguments.contains("-mock-recurring-schedule") {
                let today = calendar.startOfDay(for: .now)
                recurringSchedules.append(RecurringScheduleRule(
                    title: "每周设计复盘",
                    detail: "用于验证单次与整组删除",
                    startsOn: today,
                    weekdays: [calendar.component(.weekday, from: today)],
                    startMinute: 16 * 60 + 30,
                    durationMinutes: 45,
                    timezone: calendar.timeZone.identifier
                ))
            }
            hasCompletedOnboarding = !ProcessInfo.processInfo.arguments.contains("-show-onboarding")
        }
    }

    var todayBlocks: [ScheduleBlock] {
        blocks(on: .now)
    }

    var currentOrNextBlock: ScheduleBlock? {
        let now = Date.now
        return todayBlocks.first(where: { $0.start <= now && $0.end > now && $0.state == .planned })
            ?? todayBlocks.first(where: { $0.end > now && $0.state == .planned })
            ?? todayBlocks.first(where: { $0.state == .planned })
    }

    var focusMinutesToday: Int {
        focusMinutes(on: .now)
    }

    var weeklyFocusMinutes: Int {
        scheduleSummary(for: .week, containing: .now).focusMinutes
    }

    func periodInterval(for timeframe: PlanTimeframe, containing date: Date) -> DateInterval {
        let result: DateInterval? = switch timeframe {
        case .week:
            calendar.dateInterval(of: .weekOfYear, for: date)
        case .month:
            calendar.dateInterval(of: .month, for: date)
        case .year:
            calendar.dateInterval(of: .year, for: date)
        }
        return result ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    }

    func normalizedPeriod(_ timeframe: PlanTimeframe, containing date: Date) -> PlanningPeriod {
        PlanningPeriod(timeframe: timeframe, anchorDate: periodInterval(for: timeframe, containing: date).start)
    }

    func planItems(for timeframe: PlanTimeframe, containing date: Date) -> [PlanItem] {
        let interval = periodInterval(for: timeframe, containing: date)
        return planItems.filter { item in
            if let period = item.planningPeriod {
                return period.timeframe == timeframe &&
                    calendar.isDate(periodInterval(for: timeframe, containing: period.anchorDate).start,
                                    inSameDayAs: interval.start)
            }
            return item.deadline.map(interval.contains) ?? false
        }
        .sorted(by: planItemSort)
    }

    func planItems(in interval: DateInterval) -> [PlanItem] {
        planItems.filter { item in
            if let period = item.planningPeriod {
                return interval.contains(period.anchorDate)
            }
            return item.deadline.map(interval.contains) ?? false
        }
        .sorted(by: planItemSort)
    }

    func unassignedGoals() -> [PlanItem] {
        planItems
            .filter { $0.kind == .goal && $0.planningPeriod == nil && $0.deadline == nil }
            .sorted(by: planItemSort)
    }

    func scheduleSummary(for timeframe: PlanTimeframe, containing date: Date) -> SchedulePeriodSummary {
        let interval = periodInterval(for: timeframe, containing: date)
        let periodBlocks = expandedBlocks(in: interval)
        var byDay: [Date: Int] = [:]
        for block in periodBlocks where block.kind == .focus && block.state != .missed {
            byDay[calendar.startOfDay(for: block.start), default: 0] += block.durationMinutes
        }
        return SchedulePeriodSummary(
            totalMinutes: periodBlocks.filter { $0.state != .missed }.reduce(0) { $0 + $1.durationMinutes },
            focusMinutes: periodBlocks.filter { $0.kind == .focus && $0.state != .missed }.reduce(0) { $0 + $1.durationMinutes },
            completedMinutes: periodBlocks.filter { $0.kind == .focus && $0.state == .completed }.reduce(0) { $0 + $1.durationMinutes },
            fixedEventCount: periodBlocks.filter { $0.kind == .fixed }.count,
            blockCount: periodBlocks.count,
            focusMinutesByDay: byDay
        )
    }

    func blocks(on date: Date) -> [ScheduleBlock] {
        let oneOff = blocks.filter { calendar.isDate($0.start, inSameDayAs: date) }
        var recurring = recurringSchedules.compactMap { rule -> ScheduleBlock? in
            let occurrenceOverride = occurrenceOverrides.first {
                $0.recurringRuleID == rule.id && calendar.isDate($0.occurrenceDate, inSameDayAs: date)
            }
            let occurrence = RecurringScheduleEngine.occurrence(
                for: rule,
                on: date,
                override: occurrenceOverride,
                calendar: calendar
            )
            guard let occurrence, calendar.isDate(occurrence.start, inSameDayAs: date) else { return nil }
            return occurrence
        }
        let movedHere = occurrenceOverrides.compactMap { occurrenceOverride -> ScheduleBlock? in
            guard let movedStart = occurrenceOverride.start,
                  calendar.isDate(movedStart, inSameDayAs: date),
                  !calendar.isDate(occurrenceOverride.occurrenceDate, inSameDayAs: date),
                  let rule = recurringSchedules.first(where: { $0.id == occurrenceOverride.recurringRuleID }) else {
                return nil
            }
            return RecurringScheduleEngine.occurrence(
                for: rule,
                on: occurrenceOverride.occurrenceDate,
                override: occurrenceOverride,
                calendar: calendar
            )
        }
        recurring.append(contentsOf: movedHere)
        return (oneOff + recurring).sorted { $0.start < $1.start }
    }

    func focusMinutes(on date: Date) -> Int {
        blocks(on: date)
            .filter { $0.kind == .focus && $0.state != .missed }
            .reduce(0) { $0 + $1.durationMinutes }
    }

    func scheduledSessions(for goal: PlanItem) -> Int {
        let childIDs = Set(planItems.filter { $0.parentID == goal.id }.map(\.id))
        return blocks.filter { block in
            guard let itemID = block.planItemID else { return false }
            return childIDs.contains(itemID)
        }.count
    }

    func finishOnboarding(profile: OnboardingProfile) {
        onboardingProfile = profile
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "lamp.onboarding.complete")
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
        }
        if !ProcessInfo.processInfo.arguments.contains("-ui-testing") {
            requestAndScheduleMorningBrief()
        }
    }

    func finishOnboarding() {
        let profile = OnboardingProfile(
            context: "其他",
            wakeTime: calendar.date(on: .now, hour: 8),
            sleepTime: calendar.date(on: .now, hour: 23, minute: 30),
            scheduleSource: "稍后设置"
        )
        finishOnboarding(profile: profile)
    }

    func complete(_ block: ScheduleBlock) {
        beginTransaction("已撤销完成操作")
        setBlock(block, state: .completed, completedMinutes: block.durationMinutes)
        toast = "已完成。今天向前了一点。"
        save()
        Task { await LampActivityManager.update(blockID: block.id, status: "completed") }
    }

    func submitPartial(_ block: ScheduleBlock, feedback: PartialCompletionFeedback) {
        beginTransaction("已撤销部分完成")
        setBlock(
            block,
            state: .partial,
            completedMinutes: feedback.completedMinutes,
            reason: feedback.note.isEmpty ? "已完成一部分" : feedback.note
        )

        if feedback.remainingMinutes > 0 {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: block.start) ?? block.start
            let end = calendar.date(byAdding: .minute, value: feedback.remainingMinutes, to: tomorrow) ?? block.end
            blocks.append(ScheduleBlock(
                planItemID: block.planItemID,
                title: block.title,
                start: tomorrow,
                end: end,
                kind: block.kind,
                reason: "根据部分完成反馈安排剩余内容",
                provenance: "Lamp · 自动重排"
            ))
        }
        toast = "已记录并安排剩余部分"
        save()
        Task { await LampActivityManager.update(blockID: block.id, status: "partial") }
    }

    func proposeMissed(_ block: ScheduleBlock, reason: String) {
        beginTransaction("已撤销未做记录")
        setBlock(
            block,
            state: .missed,
            completedMinutes: 0,
            reason: reason.isEmpty ? "本次未完成" : reason
        )

        var proposed = blocks
        if block.kind == .focus {
            let nextStart = calendar.date(byAdding: .day, value: 1, to: block.start) ?? block.start
            let nextEnd = calendar.date(byAdding: .minute, value: block.durationMinutes, to: nextStart) ?? block.end
            proposed.append(ScheduleBlock(
                planItemID: block.planItemID,
                title: block.title,
                start: nextStart,
                end: nextEnd,
                kind: block.kind,
                reason: "因本次未完成，建议顺延",
                provenance: "Lamp · 重排建议"
            ))
        }
        pendingReplan = ReplanProposal(
            title: "重新安放这项任务",
            summary: "本次未完成已记录，是否把任务放进明天的相同时段？",
            changes: block.kind == .focus ? ["“\(block.title)”移动到明天"] : ["保留未完成记录，不新增日程"],
            reason: reason.isEmpty ? "现实计划发生了变化" : reason,
            proposedBlocks: proposed
        )
        save()
    }

    func mark(_ block: ScheduleBlock, as state: CompletionState) {
        switch state {
        case .completed:
            complete(block)
        case .partial:
            let half = max(1, block.durationMinutes / 2)
            submitPartial(block, feedback: PartialCompletionFeedback(
                completedMinutes: half,
                remainingMinutes: max(0, block.durationMinutes - half),
                note: ""
            ))
        case .missed:
            proposeMissed(block, reason: "")
        case .planned, .active:
            setBlock(block, state: state, completedMinutes: 0)
            save()
        }
    }

    func updateBlock(_ block: ScheduleBlock, title: String, start: Date, end: Date) -> Bool {
        guard block.kind != .fixed || block.recurringRuleID != nil else {
            toast = "固定日程请在来源日历中修改"
            return false
        }
        guard end > start else {
            toast = "结束时间需要晚于开始时间"
            return false
        }
        let conflicts = blocks(on: start).contains {
            $0.id != block.id && $0.kind == .fixed && start < $0.end && end > $0.start
        }
        guard !conflicts else {
            toast = "这个时间与固定日程冲突"
            return false
        }
        beginTransaction("已撤销日程修改")
        let updatedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? block.title : title
        if let ruleID = block.recurringRuleID, let occurrenceDate = block.occurrenceDate {
            if let index = occurrenceOverrides.firstIndex(where: {
                $0.recurringRuleID == ruleID && calendar.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate)
            }) {
                occurrenceOverrides[index].title = updatedTitle
                occurrenceOverrides[index].start = start
                occurrenceOverrides[index].end = end
            } else {
                occurrenceOverrides.append(ScheduleOccurrenceOverride(
                    recurringRuleID: ruleID,
                    occurrenceDate: occurrenceDate,
                    state: block.state,
                    title: updatedTitle,
                    start: start,
                    end: end
                ))
            }
        } else {
            guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return false }
            blocks[index].title = updatedTitle
            blocks[index].start = start
            blocks[index].end = end
            blocks[index].provenance = "手动调整"
        }
        toast = "日程已更新"
        save()
        return true
    }

    @discardableResult
    func deleteScheduleBlock(
        _ block: ScheduleBlock,
        scope: ScheduleDeletionScope = .singleOccurrence
    ) -> Bool {
        if let ruleID = block.recurringRuleID {
            guard recurringSchedules.contains(where: { $0.id == ruleID }) else {
                toast = "找不到这条重复日程"
                return false
            }
            beginTransaction(scope == .entireSeries ? "已恢复整个重复日程" : "已恢复本次日程")
            guard ScheduleDeletionEngine.delete(
                block: block,
                scope: scope,
                blocks: &blocks,
                recurringSchedules: &recurringSchedules,
                occurrenceOverrides: &occurrenceOverrides,
                calendar: calendar
            ) else {
                undoTransaction = nil
                toast = "无法确定要删除的日程范围"
                return false
            }
            toast = scope == .entireSeries ? "已从 Lamp 删除整个重复日程" : "已从 Lamp 删除本次日程"
            save()
            return true
        }

        guard blocks.contains(where: { $0.id == block.id }) else {
            toast = "这条日程已经不存在"
            return false
        }
        beginTransaction("已恢复删除的日程")
        guard ScheduleDeletionEngine.delete(
            block: block,
            scope: scope,
            blocks: &blocks,
            recurringSchedules: &recurringSchedules,
            occurrenceOverrides: &occurrenceOverrides,
            calendar: calendar
        ) else {
            undoTransaction = nil
            toast = "这条日程已经不存在"
            return false
        }
        if block.kind == .fixed {
            toast = "已从 Lamp 删除，不会修改“\(block.provenance)”中的原日程"
        } else if block.planItemID != nil {
            toast = "已删除这个时段，关联任务仍然保留"
        } else {
            toast = "已从 Lamp 删除日程"
        }
        save()
        return true
    }

    @discardableResult
    func deletePlanItem(_ item: PlanItem) -> Bool {
        guard planItems.contains(where: { $0.id == item.id }) else {
            toast = "这项计划已经不存在"
            return false
        }
        beginTransaction("已恢复删除的计划")
        guard ScheduleDeletionEngine.delete(item: item, planItems: &planItems, blocks: &blocks) else {
            undoTransaction = nil
            toast = "这项计划已经不存在"
            return false
        }
        if pendingWeeklySchedule?.item.id == item.id { pendingWeeklySchedule = nil }
        toast = item.kind == .goal
            ? "已删除年度目标，关联计划已转为未关联"
            : "已删除计划和它的日程时段"
        save()
        return true
    }

    func updateGoal(_ goal: PlanItem, title: String, detail: String) {
        beginTransaction("已撤销目标修改")
        guard let index = planItems.firstIndex(where: { $0.id == goal.id }) else { return }
        planItems[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? goal.title : title
        planItems[index].detail = detail
        toast = "目标已更新"
        save()
    }

    @discardableResult
    func createPlanItem(
        title: String,
        detail: String,
        importance: Int,
        timeframe: PlanTimeframe,
        anchorDate: Date,
        deadline: Date?,
        estimatedMinutes: Int,
        parentID: UUID? = nil
    ) -> PlanItem {
        beginTransaction("已撤销新增计划")
        let kind: PlanKind = switch timeframe {
        case .week: .task
        case .month: .milestone
        case .year: .goal
        }
        let item = PlanItem(
            parentID: parentID,
            kind: kind,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: detail,
            importance: min(5, max(1, importance)),
            deadline: deadline,
            estimatedMinutes: max(20, estimatedMinutes),
            isSplittable: timeframe == .week,
            planningPeriod: normalizedPeriod(timeframe, containing: anchorDate)
        )
        planItems.append(item)
        toast = timeframe == .year ? "年度目标已加入路线" : "\(timeframe.title)计划已创建"
        save()
        return item
    }

    func updatePlanItem(
        _ item: PlanItem,
        title: String,
        detail: String,
        importance: Int,
        timeframe: PlanTimeframe,
        anchorDate: Date,
        deadline: Date?,
        estimatedMinutes: Int,
        parentID: UUID?
    ) {
        guard let index = planItems.firstIndex(where: { $0.id == item.id }) else { return }
        beginTransaction("已撤销计划修改")
        planItems[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        planItems[index].detail = detail
        planItems[index].importance = min(5, max(1, importance))
        planItems[index].deadline = deadline
        let newEstimate = max(20, estimatedMinutes)
        let alreadyCompleted = max(0, planItems[index].estimatedMinutes - planItems[index].remainingMinutes)
        planItems[index].estimatedMinutes = newEstimate
        planItems[index].remainingMinutes = max(0, newEstimate - alreadyCompleted)
        planItems[index].progress = min(1, max(0, 1 - Double(planItems[index].remainingMinutes) / Double(newEstimate)))
        planItems[index].parentID = parentID
        planItems[index].planningPeriod = normalizedPeriod(timeframe, containing: anchorDate)
        planItems[index].kind = switch timeframe {
        case .week: .task
        case .month: .milestone
        case .year: .goal
        }
        for blockIndex in blocks.indices where blocks[blockIndex].planItemID == item.id {
            blocks[blockIndex].title = planItems[index].title
        }
        toast = "计划已更新"
        save()
    }

    @discardableResult
    func proposeWeeklyPlan(
        title: String,
        detail: String,
        importance: Int,
        weekContaining anchorDate: Date,
        deadline: Date?,
        estimatedMinutes: Int,
        parentID: UUID? = nil
    ) -> WeeklyScheduleProposal {
        let week = periodInterval(for: .week, containing: anchorDate)
        let item = PlanItem(
            parentID: parentID,
            kind: .task,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: detail,
            importance: min(5, max(1, importance)),
            deadline: deadline,
            estimatedMinutes: max(20, estimatedMinutes),
            isSplittable: true,
            planningPeriod: PlanningPeriod(timeframe: .week, anchorDate: week.start)
        )
        let occupied = expandedBlocks(in: week)
        let horizonStart = week.contains(.now) ? max(Date.now, week.start) : week.start
        let generated = PlanningEngine(calendar: calendar).makeSchedule(
            items: [item],
            fixed: occupied,
            context: PlanningContext(horizonStart: horizonStart, horizonEnd: week.end)
        )
        let suggestions = generated.filter { $0.planItemID == item.id }
        let warnings = suggestions.isEmpty ? ["本周没有找到无冲突空档，请手动选择时间。"] : []
        let fallbackStart = fallbackWeeklyStart(in: week)
        let fallback = ScheduleBlock(
            planItemID: item.id,
            title: item.title,
            start: fallbackStart,
            end: fallbackStart.addingTimeInterval(TimeInterval(min(90, item.estimatedMinutes) * 60)),
            kind: .focus,
            reason: "手动选择本周时间"
        )
        let proposal = WeeklyScheduleProposal(
            item: item,
            weekStart: week.start,
            suggestedBlocks: suggestions.isEmpty ? [fallback] : suggestions,
            warnings: warnings
        )
        pendingWeeklySchedule = proposal
        return proposal
    }

    func weeklyScheduleIssue(for block: ScheduleBlock, proposalBlocks: [ScheduleBlock]) -> String? {
        guard block.end > block.start else { return "结束时间需要晚于开始时间" }
        guard let proposal = pendingWeeklySchedule else { return "排程预览已失效" }
        let week = periodInterval(for: .week, containing: proposal.weekStart)
        guard block.start >= week.start, block.end <= week.end else { return "时段需要位于所选周内" }
        let interval = DateInterval(start: block.start, end: block.end)
        if expandedBlocks(in: week).contains(where: {
            interval.intersects(DateInterval(start: $0.start, end: $0.end))
        }) {
            return "与已有日程冲突"
        }
        if proposalBlocks.contains(where: {
            $0.id != block.id && interval.intersects(DateInterval(start: $0.start, end: $0.end))
        }) {
            return "与另一个候选时段重叠"
        }
        return nil
    }

    @discardableResult
    func applyWeeklyScheduleProposal(blocks proposedBlocks: [ScheduleBlock]) -> Bool {
        guard let proposal = pendingWeeklySchedule,
              !proposedBlocks.isEmpty,
              proposedBlocks.allSatisfy({ weeklyScheduleIssue(for: $0, proposalBlocks: proposedBlocks) == nil }) else {
            toast = "请先解决排程冲突"
            return false
        }
        beginTransaction("已撤销周计划排程")
        planItems.append(proposal.item)
        blocks.append(contentsOf: proposedBlocks.map { block in
            var inserted = block
            inserted.planItemID = proposal.item.id
            inserted.title = proposal.item.title
            return inserted
        })
        pendingWeeklySchedule = nil
        toast = "周计划已排入时间线"
        save()
        return true
    }

    func dismissWeeklyScheduleProposal() {
        pendingWeeklySchedule = nil
        toast = "未保存这项周计划"
    }

    func updateMemory(_ memory: MemoryFact, title: String, detail: String) {
        beginTransaction("已撤销记忆修改")
        guard let index = memories.firstIndex(where: { $0.id == memory.id }) else { return }
        memories[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? memory.title : title
        memories[index].detail = detail
        memories[index].source = "由你编辑"
        memories[index].confidence = 1
        memories[index].status = .confirmed
        toast = "记忆已更新"
        save()
    }

    func deleteMemory(_ memory: MemoryFact) {
        beginTransaction("已恢复删除的记忆")
        memories.removeAll { $0.id == memory.id }
        toast = "记忆已删除"
        save()
    }

    func toggleRule(id: UUID, isEnabled: Bool) {
        beginTransaction("已撤销规则修改")
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = isEnabled
        toast = isEnabled ? "规则已启用" : "规则已暂停"
        save()
    }

    func toggleRule(_ rule: PlanningRule) {
        toggleRule(id: rule.id, isEnabled: !rule.isEnabled)
    }

    @discardableResult
    func importScheduleCandidates(_ candidates: [ImageScheduleCandidate]) -> [UUID] {
        let valid = candidates.filter { candidate in
            guard !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let start = candidate.startAt,
                  let end = candidate.endAt,
                  end > start else { return false }
            return conflictDescription(for: candidate) == nil
        }
        guard !valid.isEmpty else { return [] }

        beginTransaction("已撤销图片导入")
        var insertedIDs: [UUID] = []
        for candidate in valid.prefix(24) {
            guard let start = candidate.startAt, let end = candidate.endAt else { continue }
            if candidate.recurrence.kind == .weekly {
                var candidateCalendar = calendar
                candidateCalendar.timeZone = TimeZone(identifier: candidate.timezone) ?? calendar.timeZone
                let rule = RecurringScheduleRule(
                    title: candidate.title,
                    detail: candidate.detail,
                    startsOn: candidate.recurrence.startsOn ?? start,
                    endsOn: candidate.recurrence.endsOn,
                    weekdays: candidate.recurrence.weekdays.isEmpty
                        ? [candidateCalendar.component(.weekday, from: start)]
                        : candidate.recurrence.weekdays,
                    startMinute: candidateCalendar.component(.hour, from: start) * 60 + candidateCalendar.component(.minute, from: start),
                    durationMinutes: max(1, Int(end.timeIntervalSince(start) / 60)),
                    timezone: candidate.timezone
                )
                recurringSchedules.append(rule)
                let firstDay = nextOccurrenceDate(for: rule, onOrAfter: .now) ?? rule.startsOn
                insertedIDs.append(RecurringScheduleEngine.occurrenceID(ruleID: rule.id, day: firstDay, calendar: calendar))
            } else {
                let block = ScheduleBlock(
                    title: candidate.title,
                    start: start,
                    end: end,
                    kind: .fixed,
                    reason: candidate.detail,
                    provenance: "DeepSeek 图片识别 · 用户确认"
                )
                blocks.append(block)
                insertedIDs.append(block.id)
            }
        }
        highlightedBlockIDs = Set(insertedIDs)
        toast = "已将 \(insertedIDs.count) 项日程加入时间线"
        save()
        return insertedIDs
    }

    func conflictDescription(for candidate: ImageScheduleCandidate) -> String? {
        ScheduleCandidateValidator.issue(
            for: candidate,
            blocks: blocks,
            recurringSchedules: recurringSchedules,
            occurrenceOverrides: occurrenceOverrides,
            calendar: calendar
        )
    }

    func undoLastAction() {
        guard let transaction = undoTransaction else { return }
        apply(transaction.snapshot)
        highlightedBlockIDs = []
        undoTransaction = nil
        toast = transaction.message
        save()
    }

    func postStatus(_ message: String) {
        undoTransaction = nil
        toast = message
    }

    func process(input: String) -> String {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "告诉我发生了什么，或你想完成什么。" }

        if normalized.contains("累") || normalized.localizedCaseInsensitiveContains("exhausted") || normalized.contains("疲惫") {
            proposeFatigueReplan()
            return "知道了。我把今天的强度降下来，并保留了更多恢复时间。先看看调整方案。"
        }

        if let scope = inferredPlanningScope(from: normalized) {
            return createPlanFromConversation(
                title: inferredTitle(from: normalized),
                detail: normalized,
                scope: scope,
                anchorDate: .now,
                deadline: normalized.contains("明天") ? calendar.date(byAdding: .day, value: 1, to: .now) : nil,
                estimatedMinutes: 60,
                importance: scope == .week ? 4 : 5
            )
        }

        beginTransaction("已撤销新增事项")
        let title = inferredTitle(from: normalized)
        let deadline = normalized.contains("明天") ? calendar.date(byAdding: .day, value: 1, to: .now) : nil
        let item = PlanItem(kind: .task, title: title, detail: normalized, importance: deadline == nil ? 3 : 5, deadline: deadline, estimatedMinutes: 60)
        planItems.append(item)
        addToNextAvailableSlot(item)
        toast = "已加入计划"
        save()
        return "已把“\(title)”加入计划，并放进了下一个合适的空档。"
    }

    func processWithAgent(input: String) async -> String {
        if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
            return process(input: input)
        }
        guard let directive = try? await AgentAPIClient.interpret(input) else {
            return process(input: input)
        }
        switch directive.name {
        case "set_temporary_state":
            proposeFatigueReplan()
            return "知道了。这只作为临时状态处理。我准备了一份更轻的计划，请先确认。"
        case "ask_clarification":
            return directive.arguments.question ?? "这件事最晚需要在什么时候完成？"
        case "create_item":
            let title = directive.arguments.title ?? inferredTitle(from: input)
            let minutes = min(480, max(20, directive.arguments.estimatedMinutes ?? 60))
            if let scope = planningScope(from: directive, fallbackInput: input) {
                return createPlanFromConversation(
                    title: title,
                    detail: directive.arguments.detail ?? input,
                    scope: scope,
                    anchorDate: parsedDate(directive.arguments.periodAnchor) ?? .now,
                    deadline: parsedDate(directive.arguments.deadline ?? directive.arguments.deadlineHint),
                    estimatedMinutes: minutes,
                    importance: directive.arguments.importance ?? (scope == .week ? 4 : 5)
                )
            }
            beginTransaction("已撤销新增事项")
            let item = PlanItem(
                kind: .task,
                title: title,
                detail: directive.arguments.detail ?? input,
                importance: directive.arguments.importance ?? (directive.arguments.deadlineHint == nil ? 3 : 5),
                deadline: parsedDate(directive.arguments.deadline ?? directive.arguments.deadlineHint),
                estimatedMinutes: minutes
            )
            planItems.append(item)
            addToNextAvailableSlot(item)
            toast = "DeepSeek 已理解并加入计划"
            save()
            return "已把“\(title)”转成 \(minutes) 分钟的行动，并安排到合适空档。"
        default:
            return process(input: input)
        }
    }

    func proposeFatigueReplan() {
        let today = calendar.startOfDay(for: .now)
        let eveningStart = calendar.date(on: today, hour: 18)
        var proposed = blocks
        let affected = proposed.indices.filter {
            calendar.isDateInToday(proposed[$0].start) && proposed[$0].start >= eveningStart && proposed[$0].kind == .focus
        }
        for index in affected {
            proposed[index].start = calendar.date(byAdding: .day, value: 1, to: proposed[index].start) ?? proposed[index].start
            proposed[index].end = calendar.date(byAdding: .day, value: 1, to: proposed[index].end) ?? proposed[index].end
            proposed[index].reason = "因今天疲惫，顺延到明天"
        }
        pendingReplan = ReplanProposal(
            title: "让今晚轻一点",
            summary: "今晚减少专注负担，留出恢复空间。",
            changes: affected.isEmpty ? ["今天的计划已经足够轻，不需要移动任务"] : affected.map { "“\(blocks[$0].title)”顺延到明天" },
            reason: "临时状态：今天疲惫",
            proposedBlocks: proposed
        )
    }

    func applyPendingReplan() {
        guard let proposal = pendingReplan else { return }
        beginTransaction("已恢复调整前的计划")
        blocks = proposal.proposedBlocks
        if proposal.reason.contains("疲惫") {
            temporaryStates.append(TemporaryState(
                title: "疲惫",
                expiresAt: calendar.date(byAdding: .day, value: 1, to: .now)!,
                workloadMultiplier: 0.55
            ))
        }
        pendingReplan = nil
        toast = "新计划已应用"
        save()
    }

    func dismissPendingReplan() {
        pendingReplan = nil
        toast = "已保留当前计划"
    }

    func exportData() throws -> URL {
        let snapshot = makeSnapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Lamp-Export", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Lamp-data-\(Date.now.formatted(.iso8601.year().month().day())).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func clearCaches() -> Int {
        undoTransaction = nil
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let children = (try? FileManager.default.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for child in children where (try? FileManager.default.removeItem(at: child)) != nil {
            removed += 1
        }
        toast = removed == 0 ? "缓存已经是空的" : "已清除 \(removed) 项缓存，计划数据未受影响"
        return removed
    }

    func deleteAllLocalData() {
        try? FileManager.default.removeItem(at: persistenceURL)
        planItems = []
        blocks = []
        memories = []
        rules = []
        temporaryStates = []
        recurringSchedules = []
        occurrenceOverrides = []
        highlightedBlockIDs = []
        pendingReplan = nil
        pendingWeeklySchedule = nil
        undoTransaction = nil
        onboardingProfile = nil
        hasCompletedOnboarding = false
        UserDefaults.standard.removeObject(forKey: "lamp.onboarding.complete")
        UserDefaults.standard.removeObject(forKey: profileKey)
        toast = nil
    }

    func drainSharedActions() -> [LampSharedAction] {
        LampSharedActionQueue.drain()
    }

    private func setBlock(
        _ block: ScheduleBlock,
        state: CompletionState,
        completedMinutes: Int,
        reason: String? = nil
    ) {
        if let ruleID = block.recurringRuleID, let occurrenceDate = block.occurrenceDate {
            if let index = occurrenceOverrides.firstIndex(where: {
                $0.recurringRuleID == ruleID && calendar.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate)
            }) {
                occurrenceOverrides[index].state = state
                if let reason { occurrenceOverrides[index].reason = reason }
            } else {
                occurrenceOverrides.append(ScheduleOccurrenceOverride(
                    recurringRuleID: ruleID,
                    occurrenceDate: occurrenceDate,
                    state: state,
                    reason: reason ?? ""
                ))
            }
        } else if let index = blocks.firstIndex(where: { $0.id == block.id }) {
            blocks[index].state = state
            if let reason { blocks[index].reason = reason }
        }
        updatePlanProgress(for: block, completedMinutes: completedMinutes)
    }

    private func updatePlanProgress(for block: ScheduleBlock, completedMinutes: Int) {
        guard let itemID = block.planItemID,
              let itemIndex = planItems.firstIndex(where: { $0.id == itemID }) else { return }
        planItems[itemIndex].remainingMinutes = max(0, planItems[itemIndex].remainingMinutes - completedMinutes)
        let estimated = max(1, planItems[itemIndex].estimatedMinutes)
        planItems[itemIndex].progress = min(1, max(0, 1 - Double(planItems[itemIndex].remainingMinutes) / Double(estimated)))
    }

    private func beginTransaction(_ message: String) {
        undoTransaction = LampUndoTransaction(message: message, snapshot: makeSnapshot())
    }

    private func inferredTitle(from input: String) -> String {
        if let quoted = input.firstMatch(of: /[“\"]([^”\"]+)[”\"]/)?.1 { return String(quoted) }
        let cleaned = input
            .replacingOccurrences(of: "我想", with: "")
            .replacingOccurrences(of: "帮我", with: "")
            .replacingOccurrences(of: "安排", with: "")
        return String(cleaned.prefix(22)).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    private func inferredPlanningScope(from input: String) -> PlanTimeframe? {
        if input.contains("本周") || input.contains("这周") || input.localizedCaseInsensitiveContains("this week") { return .week }
        if input.contains("本月") || input.contains("这个月") || input.localizedCaseInsensitiveContains("this month") { return .month }
        if input.contains("今年") || input.contains("本年度") || input.localizedCaseInsensitiveContains("this year") { return .year }
        return nil
    }

    private func planningScope(from directive: AgentDirective, fallbackInput: String) -> PlanTimeframe? {
        if let raw = directive.arguments.planningScope?.lowercased(), let scope = PlanTimeframe(rawValue: raw) {
            return scope
        }
        switch directive.arguments.kind?.lowercased() {
        case "goal": return .year
        case "milestone", "project": return .month
        default: return inferredPlanningScope(from: fallbackInput)
        }
    }

    private func parsedDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if value == "tomorrow" || value == "明天" { return calendar.date(byAdding: .day, value: 1, to: .now) }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private func createPlanFromConversation(
        title: String,
        detail: String,
        scope: PlanTimeframe,
        anchorDate: Date,
        deadline: Date?,
        estimatedMinutes: Int,
        importance: Int
    ) -> String {
        switch scope {
        case .week:
            proposeWeeklyPlan(
                title: title,
                detail: detail,
                importance: importance,
                weekContaining: anchorDate,
                deadline: deadline,
                estimatedMinutes: estimatedMinutes
            )
            return "已为“\(title)”生成本周候选时段，请确认后再写入时间线。"
        case .month:
            createPlanItem(
                title: title,
                detail: detail,
                importance: importance,
                timeframe: .month,
                anchorDate: anchorDate,
                deadline: deadline,
                estimatedMinutes: estimatedMinutes
            )
            return "已把“\(title)”加入本月里程碑。"
        case .year:
            createPlanItem(
                title: title,
                detail: detail,
                importance: importance,
                timeframe: .year,
                anchorDate: anchorDate,
                deadline: deadline,
                estimatedMinutes: estimatedMinutes
            )
            return "已把“\(title)”加入年度目标，并同步到路线。"
        }
    }

    private func addToNextAvailableSlot(_ item: PlanItem) {
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
        let context = PlanningContext(
            horizonStart: calendar.date(on: startOfTomorrow, hour: 9),
            horizonEnd: calendar.date(byAdding: .day, value: 7, to: startOfTomorrow)!
        )
        let scheduled = PlanningEngine(calendar: calendar).makeSchedule(items: [item], fixed: blocks, context: context)
        if let newBlock = scheduled.first(where: { $0.planItemID == item.id }) {
            blocks.append(newBlock)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let snapshot = try? JSONDecoder().decode(LampSnapshot.self, from: data) else {
            apply(DemoData.snapshot(calendar: calendar))
            return
        }
        apply(snapshot)
    }

    private func apply(_ snapshot: LampSnapshot) {
        planItems = snapshot.planItems
        blocks = snapshot.blocks
        memories = snapshot.memories
        rules = snapshot.rules
        temporaryStates = snapshot.temporaryStates
        recurringSchedules = snapshot.recurringSchedules
        occurrenceOverrides = snapshot.occurrenceOverrides
        pendingWeeklySchedule = nil
    }

    private func makeSnapshot() -> LampSnapshot {
        LampSnapshot(
            planItems: planItems,
            blocks: blocks,
            memories: memories,
            rules: rules,
            temporaryStates: temporaryStates,
            recurringSchedules: recurringSchedules,
            occurrenceOverrides: occurrenceOverrides
        )
    }

    private func save() {
        guard !ProcessInfo.processInfo.arguments.contains("-ui-testing") else { return }
        guard let data = try? JSONEncoder().encode(makeSnapshot()) else { return }
        try? FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: persistenceURL, options: .atomic)
    }

    private func requestAndScheduleMorningBrief() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            var components = DateComponents()
            components.hour = 8
            let content = UNMutableNotificationContent()
            content.title = "早上好"
            content.body = "打开 Lamp，看看现在最值得做什么。"
            let request = UNNotificationRequest(
                identifier: "lamp.morning-brief",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func nextOccurrenceDate(for rule: RecurringScheduleRule, onOrAfter date: Date) -> Date? {
        let start = max(calendar.startOfDay(for: date), calendar.startOfDay(for: rule.startsOn))
        for offset in 0..<14 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            if let endsOn = rule.endsOn, day > calendar.startOfDay(for: endsOn) { return nil }
            if rule.weekdays.contains(calendar.component(.weekday, from: day)) { return day }
        }
        return nil
    }

    private func expandedBlocks(in interval: DateInterval) -> [ScheduleBlock] {
        var result: [ScheduleBlock] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            result.append(contentsOf: blocks(on: day).filter { $0.start < interval.end && $0.end > interval.start })
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return Dictionary(grouping: result, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.start < $1.start }
    }

    private func fallbackWeeklyStart(in week: DateInterval) -> Date {
        var day = week.contains(.now) ? calendar.startOfDay(for: .now) : week.start
        var candidate = calendar.date(on: day, hour: 9)
        if candidate < .now, week.contains(.now) {
            let minutes = calendar.component(.minute, from: .now)
            let rounded = calendar.date(byAdding: .minute, value: 30 - minutes % 30, to: .now) ?? .now
            candidate = rounded
        }
        if candidate >= week.end {
            day = week.start
            candidate = calendar.date(on: day, hour: 9)
        }
        return candidate
    }

    private func planItemSort(_ lhs: PlanItem, _ rhs: PlanItem) -> Bool {
        if lhs.importance != rhs.importance { return lhs.importance > rhs.importance }
        switch (lhs.deadline, rhs.deadline) {
        case let (left?, right?): return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}
