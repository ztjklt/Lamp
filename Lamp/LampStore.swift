import Foundation
import CryptoKit
import SwiftData
import Security
import OSLog
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
    @Published var pendingPlanItem: PlanItemProposal?
    @Published private(set) var syncConflicts: [SyncConflictPreview] = []
    @Published var toast: String?
    @Published var undoTransaction: LampUndoTransaction?
    @Published var hasCompletedOnboarding: Bool
    @Published var onboardingProfile: OnboardingProfile?
    @Published private(set) var cloudStateVersion = UserDefaults.standard.integer(forKey: "lamp.cloud.state-version")

    private let calendar: Calendar
    private let persistenceURL: URL
    private let localStore: any LocalStore
    private var syncEngine: (any SyncEngine)?
    private let syncLogger = Logger(subsystem: "com.lamp.planner", category: "sync")
    private let profileKey = "lamp.onboarding.profile"
    private var clarificationInput: String?

    init(calendar: Calendar = .current, localStore injectedLocalStore: (any LocalStore)? = nil) {
        self.calendar = calendar
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "lamp.onboarding.complete")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.persistenceURL = base.appendingPathComponent("Lamp/snapshot.json")
        let databaseURL = base.appendingPathComponent("Lamp/Lamp.store")
        self.localStore = injectedLocalStore
            ?? (try? SwiftDataLocalStore(databaseURL: databaseURL, legacyJSONURL: self.persistenceURL))
            ?? LegacyJSONLocalStore(url: self.persistenceURL)
        if let syncedStore = self.localStore as? any LocalStore & OutboxStore {
            self.syncEngine = OutboxSyncEngine(localStore: syncedStore, transport: SupabaseSyncTransport())
        }
        if let data = UserDefaults.standard.data(forKey: profileKey) {
            self.onboardingProfile = try? JSONDecoder().decode(OnboardingProfile.self, from: data)
        }
        load()
        syncConflicts = (try? localStore.pendingConflicts()) ?? []

        if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
            apply(DemoData.snapshot(calendar: calendar))
            if ProcessInfo.processInfo.arguments.contains("-mock-incomplete-replan-scenario") {
                applyIncompleteReplanFixture()
            }
            if ProcessInfo.processInfo.arguments.contains("-mock-language-replan-scenario") {
                applyLanguageReplanFixture()
            }
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
        if ProcessInfo.processInfo.arguments.contains("-mock-incomplete-replan-scenario"),
           let math = todayBlocks.first(where: { $0.title == "复习高数" && $0.state == .planned }) {
            return math
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
           let editable = todayBlocks.first(where: { $0.kind == .focus && $0.state == .planned }) {
            return editable
        }
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
            totalMinutes: periodBlocks.filter { $0.state != .missed }.reduce(0) { $0 + max(0, Int(min($1.end, interval.end).timeIntervalSince(max($1.start, interval.start)) / 60)) },
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
            guard let occurrence, rule.isSleep == true || calendar.isDate(occurrence.start, inSameDayAs: date) else { return nil }
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

    func proposeMissedWithAgent(_ block: ScheduleBlock, reason: String) async throws {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing") && !arguments.contains("-live-agent-core-replan") {
            proposeMissed(block, reason: reason)
            return
        }
        guard block.kind == .focus,
              let taskID = block.planItemID,
              let task = planItems.first(where: { $0.id == taskID && !$0.isPaused }) else {
            proposeMissed(block, reason: reason)
            return
        }

        beginTransaction("已撤销未做记录和重排")
        setBlock(
            block,
            state: .missed,
            completedMinutes: 0,
            reason: reason.isEmpty ? "本次未完成" : reason
        )
        save()

        let occurredAt = agentReferenceDate()
        let dayStart = calendar.startOfDay(for: occurredAt)
        guard let horizonEnd = calendar.date(byAdding: .day, value: 4, to: dayStart) else {
            throw AgentAPIClient.ClientError.invalidResponse
        }
        let horizon = DateInterval(start: dayStart, end: horizonEnd)
        let activeTasks = planItems.filter {
            ($0.kind == .task || $0.kind == .step) && !$0.isPaused && $0.remainingMinutes > 0
        }
        let activeTaskIDs = Set(activeTasks.map(\.id))
        guard activeTaskIDs.contains(taskID) else { throw AgentAPIClient.ClientError.invalidResponse }
        let requestTasks = activeTasks.map { item in
            AgentPlanDayRequest.Task(
                id: item.id,
                goalId: item.parentID,
                title: String(item.title.prefix(240)),
                detail: String(item.detail.prefix(4_000)),
                importance: min(5, max(1, item.importance)),
                deadline: item.deadline,
                estimatedMinutes: max(0, item.estimatedMinutes),
                remainingMinutes: max(0, item.remainingMinutes),
                isPaused: item.isPaused,
                isSplittable: item.isSplittable,
                minimumSessionMinutes: min(15, max(1, item.remainingMinutes)),
                maximumSessionMinutes: max(15, min(90, max(1, item.remainingMinutes))),
                preferredPeriods: item.preferredPeriod.map { [$0.rawValue] } ?? [],
                dependencyIds: item.dependencyIDs.filter(activeTaskIDs.contains),
                availableWindows: []
            )
        }
        let schedule = expandedBlocks(in: horizon)
        let fingerprint = planningStateFingerprint()
        let eventID = UUID()
        let request = AgentIncompleteReplanRequest(
            eventId: eventID,
            sourceFingerprint: fingerprint,
            occurredAt: occurredAt,
            timezone: calendar.timeZone.identifier,
            locale: Locale.current.identifier,
            planningHorizon: .init(start: horizon.start, end: horizon.end),
            taskId: taskID,
            incompleteBlockId: block.id,
            additionalMinutes: max(1, min(block.durationMinutes, task.remainingMinutes)),
            tasks: requestTasks,
            schedule: schedule.map { item in
                AgentPlanDayRequest.ExistingBlock(
                    id: item.id,
                    taskId: item.planItemID.flatMap { activeTaskIDs.contains($0) ? $0 : nil },
                    title: String(item.title.prefix(240)),
                    startsAt: item.start,
                    endsAt: item.end,
                    kind: item.kind == .breakTime ? "break" : item.kind.rawValue,
                    state: item.state.rawValue,
                    locked: item.kind == .fixed || item.recurringRuleID != nil,
                    provenance: String((item.provenance.isEmpty ? "Lamp" : item.provenance).prefix(500))
                )
            },
            preferences: planningPreferences()
        )
        let response = try await AgentAPIClient.replanIncomplete(request, expectedStateVersion: cloudStateVersion)
        guard response.status == "proposal", let proposal = response.proposal,
              proposal.sourceEventId == eventID else {
            pendingReplan = nil
            toast = response.diagnostics.first ?? "未完成已记录，目前不需要调整后续日程"
            return
        }

        let changedProposedIDs = Set(proposal.changes.compactMap { change in
            ["ADD", "MOVE", "RESIZE"].contains(change.type) ? change.proposedBlockId : nil
        })
        let affectedBlockIDs = proposal.changes.compactMap { change -> UUID? in
            guard change.type != "UNCHANGED", let previousID = change.previousBlockId,
                  previousID != block.id, blocks.contains(where: { $0.id == previousID }) else { return nil }
            return previousID
        }
        let proposed = proposal.blocks.compactMap { candidate -> ScheduleBlock? in
            guard changedProposedIDs.contains(candidate.id), activeTaskIDs.contains(candidate.taskId),
                  candidate.startsAt >= horizon.start, candidate.endsAt <= horizon.end,
                  candidate.endsAt > candidate.startsAt else { return nil }
            return ScheduleBlock(
                id: candidate.id,
                planItemID: candidate.taskId,
                title: candidate.title,
                start: candidate.startsAt,
                end: candidate.endsAt,
                kind: .focus,
                reason: localizedReason(candidate.reasonCodes),
                provenance: "Lamp Agent Core · 待确认"
            )
        }
        let occupied = schedule.filter {
            !affectedBlockIDs.contains($0.id) && $0.state != .missed
        }
        guard proposed.count == changedProposedIDs.count,
              proposedDayBlocksAreSafe(proposed, against: occupied) else {
            throw AgentAPIClient.ClientError.invalidResponse
        }
        let changes = proposed.map {
            "“\($0.title)” · \($0.start.formatted(date: .abbreviated, time: .shortened))–\($0.end.formatted(date: .omitted, time: .shortened))"
        } + proposal.warnings
        pendingReplan = ReplanProposal(
            id: proposal.id,
            title: proposal.title,
            summary: proposal.summary,
            changes: changes,
            reason: proposal.reason,
            proposedBlocks: proposed,
            mode: .incompleteTask,
            sourceFingerprint: fingerprint,
            sourceEventID: eventID,
            affectedBlockIDs: affectedBlockIDs,
            previewHash: response.previewHash,
            confirmationToken: response.confirmationToken,
            expectedStateVersion: response.expectedStateVersion,
            expiresAt: response.expiresAt
        )
        if arguments.contains("-invalidate-agent-replan-proposal") {
            let changedDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            blocks.append(ScheduleBlock(
                title: "测试中的状态变化",
                start: calendar.date(on: changedDay, hour: 6),
                end: calendar.date(on: changedDay, hour: 6, minute: 5),
                kind: .breakTime,
                reason: "仅用于验证过期提案保护"
            ))
        }
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

        let title = inferredTitle(from: normalized)
        let deadline = normalized.contains("明天") ? calendar.date(byAdding: .day, value: 1, to: .now) : nil
        proposeWeeklyPlan(
            title: title, detail: normalized, importance: deadline == nil ? 3 : 5,
            weekContaining: .now, deadline: deadline, estimatedMinutes: 60
        )
        return "已为“\(title)”生成任务与候选时段；确认前不会写入。"
    }

    func processWithAgent(input: String) async throws -> String {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing")
            && !arguments.contains("-mock-sleep-directive")
            && !arguments.contains("-live-agent-core")
            && !arguments.contains("-live-agent-core-language") {
            return process(input: input)
        }
        if isDayPlanningRequest(input) {
            return try await proposeDayPlan()
        }
        if isLanguageReplanningRequest(input) {
            return try await proposeLanguageReplan(input: input)
        }
        let combinedInput = clarificationInput.map { "原请求：\($0)\n补充回答：\(input)" } ?? input
        let directive: AgentDirective
        if ProcessInfo.processInfo.arguments.contains("-ui-testing") && ProcessInfo.processInfo.arguments.contains("-mock-sleep-directive") {
            directive = try JSONDecoder().decode(AgentDirective.self, from: Data("""
            {"name":"set_sleep_schedule","model":"fixture","arguments":{"start_minute":0,"end_minute":480,"weekdays":[1,2,3,4,5,6,7]}}
            """.utf8))
        } else {
            directive = try await AgentAPIClient.interpret(combinedInput)
        }
        if directive.name != "ask_clarification" { clarificationInput = nil }
        switch directive.name {
        case "set_sleep_schedule":
            guard let start = directive.arguments.startMinute, let end = directive.arguments.endMinute,
                  (0..<1440).contains(start), (0..<1440).contains(end), start != end else {
                return "请告诉我每晚几点睡、早上几点起床。"
            }
            let existing = recurringSchedules.first(where: { $0.isSleep == true })
            var rule = RecurringScheduleRule(
                title: "睡眠", detail: input,
                startsOn: parsedDate(directive.arguments.startsOn) ?? calendar.startOfDay(for: .now),
                endsOn: parsedDate(directive.arguments.endsOn),
                weekdays: directive.arguments.weekdays ?? Array(1...7),
                startMinute: start, durationMinutes: (end - start + 1440) % 1440,
                timezone: calendar.timeZone.identifier,
                reason: "每晚睡眠保护时段", provenance: "Lamp 对话"
            )
            rule.isSleep = true
            rule.sleepEndMinute = end
            rule.startDayOffset = start < 720 ? 1 : 0
            if let existing { rule.id = existing.id }
            let horizon = DateInterval(start: calendar.startOfDay(for: .now), end: calendar.date(byAdding: .day, value: 14, to: .now)!)
            let occupied = expandedBlocks(in: horizon)
            let sleeps = (0..<14).compactMap { offset -> ScheduleBlock? in
                guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now)) else { return nil }
                return RecurringScheduleEngine.occurrence(for: rule, on: day, override: nil, calendar: calendar)
            }
            let conflicts = blocks.filter { block in sleeps.contains { $0.start < block.end && block.start < $0.end } }
            var proposedBlocks = blocks
            if !conflicts.isEmpty {
                let movable = conflicts.filter { $0.kind == .focus && $0.planItemID != nil }
                let ids = Set(movable.map(\.id))
                let items = planItems.filter { item in movable.contains { $0.planItemID == item.id } }
                let generated = PlanningEngine(calendar: calendar).makeSchedule(
                    items: items, fixed: occupied.filter { !ids.contains($0.id) && $0.isSleep != true } + sleeps,
                    context: PlanningContext(horizonStart: .now, horizonEnd: horizon.end)
                )
                let moved = generated.filter { block in items.contains { $0.id == block.planItemID } }
                proposedBlocks = blocks.filter { !ids.contains($0.id) } + moved
            }
            pendingReplan = ReplanProposal(
                title: conflicts.isEmpty ? "设置每晚睡眠" : "睡眠与已有日程冲突",
                summary: conflicts.isEmpty ? "将从今晚开始建立重复睡眠时段。" : "请检查需要移动的专注时段；固定日程不会自动修改。",
                changes: conflicts.isEmpty ? ["每天新增“睡眠”保护时段"] : conflicts.map { "“\($0.title)”与睡眠重叠" },
                reason: "睡眠保护时段", proposedBlocks: proposedBlocks,
                proposedRecurringRule: rule
            )
            if arguments.contains("-mock-sleep-directive") { applyPendingReplanLocally() }
            return "已生成睡眠安排候选；确认前不会修改日程。"
        case "set_temporary_state":
            proposeFatigueReplan()
            return "知道了。这只作为临时状态处理。我准备了一份更轻的计划，请先确认。"
        case "ask_clarification":
            clarificationInput = combinedInput
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
            proposeWeeklyPlan(
                title: title, detail: directive.arguments.detail ?? input,
                importance: directive.arguments.importance ?? (directive.arguments.deadlineHint == nil ? 3 : 5),
                weekContaining: .now,
                deadline: parsedDate(directive.arguments.deadline ?? directive.arguments.deadlineHint),
                estimatedMinutes: minutes
            )
            return "已把“\(title)”整理为任务与候选时段；确认前不会写入。"
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

    func applyPendingReplan() async -> Bool {
        guard let proposal = pendingReplan else { return false }
        if proposal.mode != .adjustment,
           proposal.sourceFingerprint != nil,
           proposal.sourceFingerprint != planningStateFingerprint() {
            pendingReplan = nil
            toast = staleProposalMessage(for: proposal.mode)
            return false
        }
        if let expiresAt = proposal.expiresAt, expiresAt <= .now {
            pendingReplan = nil
            toast = "调整方案已过期，请重新生成"
            return false
        }
        if let previewHash = proposal.previewHash,
           let confirmationToken = proposal.confirmationToken,
           let expectedVersion = proposal.expectedStateVersion {
            do {
                cloudStateVersion = try await AgentAPIClient.confirmProposal(
                    id: proposal.id, previewHash: previewHash, confirmationToken: confirmationToken,
                    expectedStateVersion: expectedVersion, idempotencyKey: proposal.confirmationIdempotencyKey
                )
                UserDefaults.standard.set(cloudStateVersion, forKey: "lamp.cloud.state-version")
                guard await synchronize() else {
                    toast = "云端已确认，等待网络恢复后同步到本机"
                    return false
                }
                if let state = proposal.temporaryStateTitle {
                    temporaryStates.append(TemporaryState(
                        title: state,
                        expiresAt: calendar.date(byAdding: .day, value: 1, to: .now)!,
                        workloadMultiplier: 0.55
                    ))
                    save()
                }
                pendingReplan = nil
                toast = "方案已确认并同步"
                return true
            } catch {
                toast = error.localizedDescription
                return false
            }
        }
        applyPendingReplanLocally()
        return true
    }

    private func applyPendingReplanLocally() {
        guard let proposal = pendingReplan else { return }
        if proposal.mode == .languageReplan {
            guard proposal.sourceFingerprint == planningStateFingerprint() else {
                pendingReplan = nil
                toast = "任务或日程已变化，请重新生成调整方案"
                return
            }
            let affectedIDs = Set(proposal.affectedBlockIDs)
            let occupied = proposal.proposedBlocks.flatMap { blocks(on: $0.start) }.filter {
                !affectedIDs.contains($0.id) && $0.state != .missed
            }
            guard proposedDayBlocksAreSafe(proposal.proposedBlocks, against: occupied) else {
                pendingReplan = nil
                toast = "调整方案发生冲突，请重新生成"
                return
            }
            beginTransaction("已恢复语言调整前的计划")
            blocks.removeAll { affectedIDs.contains($0.id) }
            blocks.append(contentsOf: proposal.proposedBlocks)
            blocks.sort { $0.start < $1.start }
            if let state = proposal.temporaryStateTitle {
                temporaryStates.append(TemporaryState(
                    title: state,
                    expiresAt: calendar.date(byAdding: .day, value: 1, to: .now)!,
                    workloadMultiplier: 0.55
                ))
            }
            pendingReplan = nil
            toast = "已按临时状态减轻点名任务"
            save()
            return
        }
        if proposal.mode == .incompleteTask {
            guard proposal.sourceFingerprint == planningStateFingerprint() else {
                pendingReplan = nil
                toast = "任务或日程已变化，请重新生成重排"
                return
            }
            let affectedIDs = Set(proposal.affectedBlockIDs)
            let occupied = proposal.proposedBlocks.flatMap { blocks(on: $0.start) }.filter {
                !affectedIDs.contains($0.id) && $0.state != .missed
            }
            guard proposedDayBlocksAreSafe(proposal.proposedBlocks, against: occupied) else {
                pendingReplan = nil
                toast = "重排发生冲突，请重新生成"
                return
            }
            blocks.removeAll { affectedIDs.contains($0.id) }
            blocks.append(contentsOf: proposal.proposedBlocks)
            blocks.sort { $0.start < $1.start }
            pendingReplan = nil
            toast = "未完成已记录，局部重排已应用"
            save()
            return
        }
        if proposal.mode == .dayPlan {
            guard proposal.sourceFingerprint == planningStateFingerprint() else {
                pendingReplan = nil
                toast = "任务或日程已变化，请重新生成计划"
                return
            }
            let current = proposal.proposedBlocks.flatMap { blocks(on: $0.start) }
            guard proposedDayBlocksAreSafe(proposal.proposedBlocks, against: current) else {
                pendingReplan = nil
                toast = "计划发生冲突，请重新生成"
                return
            }
            beginTransaction("已移除刚加入的今日计划")
            blocks.append(contentsOf: proposal.proposedBlocks)
            blocks.sort { $0.start < $1.start }
            pendingReplan = nil
            toast = "今日计划已加入时间线"
            save()
            return
        }
        beginTransaction("已恢复调整前的计划")
        blocks = proposal.proposedBlocks
        if let rule = proposal.proposedRecurringRule {
            recurringSchedules.removeAll { $0.id == rule.id || $0.isSleep == true }
            recurringSchedules.append(rule)
        }
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
        let proposal = pendingReplan
        let mode = proposal?.mode
        pendingReplan = nil
        if let proposal, proposal.confirmationToken != nil {
            Task { try? await AgentAPIClient.rejectProposal(id: proposal.id) }
        }
        if mode == .incompleteTask {
            toast = "未完成已记录，后续计划保持不变"
        } else if mode == .languageReplan {
            toast = "没有改动当前计划"
        } else {
            toast = "已保留当前计划"
        }
    }

    private func isDayPlanningRequest(_ input: String) -> Bool {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let adjustmentSignals = ["很累", "疲惫", "没完成", "未完成", "调整", "放轻", "生病", "tired", "incomplete", "replan"]
        guard !adjustmentSignals.contains(where: normalized.contains) else { return false }
        let hasDay = ["今天", "今日", "一天", "today", "my day"].contains(where: normalized.contains)
        let hasPlanningAction = ["安排", "规划", "计划", "排程", "plan", "schedule"].contains(where: normalized.contains)
        return hasDay && hasPlanningAction
    }

    private func isLanguageReplanningRequest(_ input: String) -> Bool {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasTemporaryState = ["累", "疲惫", "精力不足", "tired", "exhausted"].contains(where: normalized.contains)
        let hasReduction = ["少", "减", "轻一点", "缩短", "reduce", "less"].contains(where: normalized.contains)
        let namesTask = planItems.contains { item in
            guard item.kind == .task || item.kind == .step else { return false }
            return normalized.contains(item.title.lowercased()) ||
                (normalized.contains("高数") && (item.title.contains("高数") || item.title.contains("微积分")))
        }
        return hasTemporaryState && hasReduction && namesTask
    }

    private func proposeLanguageReplan(input: String, now: Date = .now) async throws -> String {
        let requestedAt = agentReferenceDate(fallback: now)
        let dayStart = calendar.startOfDay(for: requestedAt)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart), requestedAt < dayEnd else {
            return "今天已经没有可调整的时间了。"
        }
        let horizon = DateInterval(start: requestedAt, end: dayEnd)
        let taskItems = planItems.filter {
            ($0.kind == .task || $0.kind == .step) && !$0.isPaused && $0.remainingMinutes > 0
        }
        let taskIDs = Set(taskItems.map(\.id))
        let schedule = expandedBlocks(in: DateInterval(start: dayStart, end: dayEnd)).filter {
            $0.end > requestedAt && $0.start < dayEnd
        }
        let requestTasks = taskItems.map { item in
            AgentPlanDayRequest.Task(
                id: item.id,
                goalId: item.parentID,
                title: String(item.title.prefix(240)),
                detail: String(item.detail.prefix(4_000)),
                importance: min(5, max(1, item.importance)),
                deadline: item.deadline,
                estimatedMinutes: max(0, item.estimatedMinutes),
                remainingMinutes: max(0, item.remainingMinutes),
                isPaused: item.isPaused,
                isSplittable: item.isSplittable,
                minimumSessionMinutes: min(15, max(1, item.remainingMinutes)),
                maximumSessionMinutes: max(15, min(90, max(1, item.remainingMinutes))),
                preferredPeriods: item.preferredPeriod.map { [$0.rawValue] } ?? [],
                dependencyIds: item.dependencyIDs.filter(taskIDs.contains),
                availableWindows: []
            )
        }
        guard !requestTasks.isEmpty else { return "当前没有可以减轻的任务。" }

        let fingerprint = planningStateFingerprint()
        let requestID = UUID()
        let request = AgentLanguageReplanRequest(
            requestId: requestID,
            sourceFingerprint: fingerprint,
            requestedAt: requestedAt,
            timezone: calendar.timeZone.identifier,
            locale: Locale.current.identifier,
            input: String(input.prefix(4_000)),
            planningHorizon: .init(start: horizon.start, end: horizon.end),
            tasks: requestTasks,
            schedule: schedule.map { block in
                AgentPlanDayRequest.ExistingBlock(
                    id: block.id,
                    taskId: block.planItemID.flatMap { taskIDs.contains($0) ? $0 : nil },
                    title: String(block.title.prefix(240)),
                    startsAt: max(block.start, horizon.start),
                    endsAt: min(block.end, horizon.end),
                    kind: block.kind == .breakTime ? "break" : block.kind.rawValue,
                    state: block.state.rawValue,
                    locked: block.kind == .fixed || block.recurringRuleID != nil,
                    provenance: String((block.provenance.isEmpty ? "Lamp" : block.provenance).prefix(500))
                )
            },
            preferences: planningPreferences()
        )
        let response = try await AgentAPIClient.replanLanguage(request, expectedStateVersion: cloudStateVersion)
        guard response.trace.intent == "replan_schedule",
              response.trace.decision.intent == "replan_schedule",
              response.trace.decision.action == "reduce_task_workload",
              response.trace.decision.temporaryState == "tired",
              taskIDs.contains(response.trace.decision.taskId) else {
            throw AgentAPIClient.ClientError.invalidResponse
        }
        guard response.status == "proposal", let proposal = response.proposal,
              proposal.sourceRequestId == requestID else {
            return response.trace.diagnostics.first ?? "当前约束下无法安全地减轻这项任务。"
        }

        let changedProposedIDs = Set(proposal.changes.compactMap { change in
            ["ADD", "MOVE", "RESIZE"].contains(change.type) ? change.proposedBlockId : nil
        })
        let affectedBlockIDs = proposal.changes.compactMap { change -> UUID? in
            guard change.type != "UNCHANGED", let previousID = change.previousBlockId,
                  blocks.contains(where: { $0.id == previousID }) else { return nil }
            return previousID
        }
        let proposed = proposal.blocks.compactMap { candidate -> ScheduleBlock? in
            guard changedProposedIDs.contains(candidate.id), taskIDs.contains(candidate.taskId),
                  candidate.startsAt >= horizon.start, candidate.endsAt <= horizon.end,
                  candidate.endsAt > candidate.startsAt else { return nil }
            return ScheduleBlock(
                id: candidate.id,
                planItemID: candidate.taskId,
                title: candidate.title,
                start: candidate.startsAt,
                end: candidate.endsAt,
                kind: .focus,
                reason: localizedReason(candidate.reasonCodes),
                provenance: "Lamp Agent Core · LLM + Planner · 待确认"
            )
        }
        let occupied = schedule.filter {
            !affectedBlockIDs.contains($0.id) && $0.state != .missed
        }
        guard proposed.count == changedProposedIDs.count,
              proposedDayBlocksAreSafe(proposed, against: occupied) else {
            throw AgentAPIClient.ClientError.invalidResponse
        }
        let modelLabel = response.trace.model.provider == "deepseek" ? "DeepSeek" : "本地模型桩"
        let changes = ["\(modelLabel) 识别：临时疲惫，点名减少“\(planItems.first(where: { $0.id == response.trace.decision.taskId })?.title ?? "任务")”"] +
            proposed.map { "Planner：\($0.start.formatted(date: .omitted, time: .shortened))–\($0.end.formatted(date: .omitted, time: .shortened))，\($0.durationMinutes) 分钟" } +
            proposal.warnings
        pendingReplan = ReplanProposal(
            id: proposal.id,
            title: proposal.title,
            summary: proposal.summary,
            changes: changes,
            reason: proposal.reason,
            proposedBlocks: proposed,
            mode: .languageReplan,
            sourceFingerprint: fingerprint,
            affectedBlockIDs: affectedBlockIDs,
            temporaryStateTitle: "疲惫",
            previewHash: response.previewHash,
            confirmationToken: response.confirmationToken,
            expectedStateVersion: response.expectedStateVersion,
            expiresAt: response.expiresAt
        )
        if ProcessInfo.processInfo.arguments.contains("-invalidate-agent-language-proposal") {
            let changedDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            blocks.append(ScheduleBlock(
                title: "测试中的状态变化",
                start: calendar.date(on: changedDay, hour: 6),
                end: calendar.date(on: changedDay, hour: 6, minute: 5),
                kind: .breakTime,
                reason: "仅用于验证过期提案保护"
            ))
        }
        return "我先把你的话理解成结构化调整，再由 Planner 生成了候选；确认前不会改动时间线。"
    }

    private func proposeDayPlan(now: Date = .now) async throws -> String {
        let planningNow = agentReferenceDate(fallback: now)
        let dayStart = calendar.startOfDay(for: planningNow)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return "无法确定今天的结束时间。"
        }
        let minute = calendar.component(.minute, from: planningNow)
        let roundedStart = calendar.date(byAdding: .minute, value: (15 - minute % 15) % 15, to: planningNow) ?? planningNow
        guard roundedStart < dayEnd else { return "今天已经没有可安排的时间了。" }

        let horizon = DateInterval(start: roundedStart, end: dayEnd)
        let todayBlocks = expandedBlocks(in: DateInterval(start: dayStart, end: dayEnd))
        let occupied = todayBlocks.filter { $0.start < horizon.end && $0.end > horizon.start }
        let taskItems = planItems.filter {
            ($0.kind == .task || $0.kind == .step) && !$0.isPaused && $0.remainingMinutes > 0
        }
        let scheduledMinutes = Dictionary(grouping: todayBlocks.filter {
            $0.kind == .focus && ($0.state == .planned || $0.state == .active)
                && $0.planItemID != nil
        }, by: { $0.planItemID! }).mapValues { blocks in
            blocks.reduce(0) { $0 + $1.durationMinutes }
        }
        let requestTasks = taskItems.compactMap { item -> AgentPlanDayRequest.Task? in
            let unplannedMinutes = max(0, item.remainingMinutes - (scheduledMinutes[item.id] ?? 0))
            guard unplannedMinutes > 0 else { return nil }
            return AgentPlanDayRequest.Task(
                id: item.id,
                goalId: item.parentID,
                title: String(item.title.prefix(240)),
                detail: String(item.detail.prefix(4_000)),
                importance: min(5, max(1, item.importance)),
                deadline: item.deadline,
                estimatedMinutes: max(0, item.estimatedMinutes),
                remainingMinutes: unplannedMinutes,
                isPaused: item.isPaused,
                isSplittable: item.isSplittable,
                minimumSessionMinutes: min(20, unplannedMinutes),
                maximumSessionMinutes: max(20, min(90, unplannedMinutes)),
                preferredPeriods: item.preferredPeriod.map { [$0.rawValue] } ?? [],
                dependencyIds: item.dependencyIDs,
                availableWindows: []
            )
        }
        guard !requestTasks.isEmpty else { return "今天的任务都已经安排好了。" }
        let requestTaskIDs = Set(requestTasks.map(\.id))

        let fingerprint = planningStateFingerprint()
        let request = AgentPlanDayRequest(
            requestId: UUID(),
            sourceFingerprint: fingerprint,
            requestedAt: planningNow,
            timezone: calendar.timeZone.identifier,
            locale: Locale.current.identifier,
            horizon: .init(start: roundedStart, end: dayEnd),
            focusMinutesBeforeHorizon: todayBlocks.filter {
                $0.kind == .focus && $0.state != .missed && $0.start < roundedStart
            }.reduce(0) { total, block in
                total + max(0, Int(min(block.end, roundedStart).timeIntervalSince(max(block.start, dayStart)) / 60))
            },
            tasks: requestTasks,
            schedule: occupied.map { block in
                AgentPlanDayRequest.ExistingBlock(
                    id: block.id,
                    taskId: block.planItemID.flatMap { requestTaskIDs.contains($0) ? $0 : nil },
                    title: String(block.title.prefix(240)),
                    startsAt: max(block.start, roundedStart),
                    endsAt: min(block.end, dayEnd),
                    kind: block.kind == .breakTime ? "break" : block.kind.rawValue,
                    state: block.state.rawValue,
                    locked: block.kind == .fixed || block.recurringRuleID != nil,
                    provenance: String((block.provenance.isEmpty ? "Lamp" : block.provenance).prefix(500))
                )
            },
            preferences: planningPreferences()
        )
        let response = try await AgentAPIClient.planDay(request, expectedStateVersion: cloudStateVersion)
        guard response.status == "proposal", let proposal = response.proposal else {
            return response.diagnostics.first ?? "今天没有足够的可用时间容纳待安排任务。"
        }
        let proposed = proposal.blocks.compactMap { block -> ScheduleBlock? in
            guard requestTaskIDs.contains(block.taskId), block.startsAt >= roundedStart, block.endsAt <= dayEnd,
                  block.endsAt > block.startsAt else { return nil }
            return ScheduleBlock(
                id: block.id,
                planItemID: block.taskId,
                title: block.title,
                start: block.startsAt,
                end: block.endsAt,
                kind: .focus,
                reason: localizedReason(block.reasonCodes),
                provenance: "Lamp Agent Core · 待确认"
            )
        }
        guard proposed.count == proposal.blocks.count,
              proposedDayBlocksAreSafe(proposed, against: occupied) else {
            throw AgentAPIClient.ClientError.invalidResponse
        }
        let changes = proposed.map {
            "“\($0.title)” · \($0.start.formatted(date: .omitted, time: .shortened))–\($0.end.formatted(date: .omitted, time: .shortened))"
        } + proposal.warnings
        pendingReplan = ReplanProposal(
            id: proposal.id,
            title: proposal.title,
            summary: proposal.summary,
            changes: changes,
            reason: proposal.reason,
            proposedBlocks: proposed,
            mode: .dayPlan,
            sourceFingerprint: fingerprint,
            previewHash: response.previewHash,
            confirmationToken: response.confirmationToken,
            expectedStateVersion: response.expectedStateVersion,
            expiresAt: response.expiresAt
        )
        if ProcessInfo.processInfo.arguments.contains("-invalidate-agent-plan-proposal") {
            blocks.append(ScheduleBlock(
                title: "测试中的状态变化",
                start: calendar.date(on: dayStart, hour: 6),
                end: calendar.date(on: dayStart, hour: 6, minute: 5),
                kind: .breakTime,
                reason: "仅用于验证过期提案保护"
            ))
        }
        return "我生成了一份今日计划候选。确认前不会写入时间线。"
    }

    private func proposedDayBlocksAreSafe(_ proposed: [ScheduleBlock], against occupied: [ScheduleBlock]) -> Bool {
        guard !proposed.isEmpty else { return false }
        for (index, block) in proposed.enumerated() {
            guard block.kind == .focus, block.planItemID != nil, block.end > block.start else { return false }
            if occupied.contains(where: { $0.state != .missed && $0.start < block.end && block.start < $0.end }) {
                return false
            }
            if proposed.dropFirst(index + 1).contains(where: { $0.start < block.end && block.start < $0.end }) {
                return false
            }
        }
        return true
    }

    private func planningPreferences() -> AgentPlanDayRequest.Preferences {
        let sleepRule = recurringSchedules.first(where: { $0.isSleep == true })
        let preferredPeriods = planItems.compactMap(\.preferredPeriod)
        let morningCount = preferredPeriods.filter { $0 == .morning }.count
        let eveningCount = preferredPeriods.filter { $0 == .evening }.count
        let total = max(1, preferredPeriods.count)
        return AgentPlanDayRequest.Preferences(
            preferredSleepTime: sleepRule.map { localTimeString(minutes: $0.startMinute) }
                ?? onboardingProfile.map { localTimeString(date: $0.sleepTime) },
            preferredWakeTime: sleepRule?.sleepEndMinute.map(localTimeString(minutes:))
                ?? onboardingProfile.map { localTimeString(date: $0.wakeTime) },
            preferredFocusMinutes: 50,
            preferredBreakMinutes: 10,
            morningStudyPreference: Double(morningCount) / Double(total),
            eveningStudyPreference: Double(eveningCount) / Double(total)
        )
    }

    private func localTimeString(minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    private func localTimeString(date: Date) -> String {
        localTimeString(minutes: calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date))
    }

    private func localizedReason(_ codes: [String]) -> String {
        if codes.contains("USER_REQUESTED_REPLAN") { return "根据你的临时状态缩短点名任务" }
        if codes.contains("TASK_INCOMPLETE_REQUIRES_REALLOCATION") { return "因本次未完成，只调整受影响时段" }
        if codes.contains("PREFERENCE_MATCH") { return "匹配你的专注时段偏好" }
        if codes.contains("DEADLINE_AWARE") { return "结合截止时间安排" }
        return "安排在今天最早可用的安全时段"
    }

    private func planningStateFingerprint() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = (try? encoder.encode(makeSnapshot())) ?? Data()
        if let onboardingProfile, let profileData = try? encoder.encode(onboardingProfile) {
            data.append(profileData)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func agentReferenceDate(fallback: Date = .now) -> Date {
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing"),
              let fixture = ProcessInfo.processInfo.environment["LAMP_AGENT_REFERENCE_DATE"],
              let date = ISO8601DateFormatter().date(from: fixture) else { return fallback }
        return date
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

    @discardableResult
    func synchronize() async -> Bool {
        guard !ProcessInfo.processInfo.arguments.contains("-ui-testing") else { return false }
        guard let syncEngine else { return false }
        do {
            let result = try await syncEngine.synchronize()
            syncConflicts = result.conflicts
            if let snapshot = try localStore.loadSnapshot() { apply(snapshot) }
            if !result.conflicts.isEmpty {
                toast = "发现 \(result.conflicts.count) 项云端冲突，请在合并预览中选择"
            }
            if let remoteVersion = try? await AgentAPIClient.fetchStateVersion() {
                cloudStateVersion = remoteVersion
                UserDefaults.standard.set(remoteVersion, forKey: "lamp.cloud.state-version")
            }
            syncLogger.info("sync completed pushed=\(result.pushed, privacy: .public) pulled=\(result.pulled, privacy: .public) conflicts=\(result.conflicts.count, privacy: .public)")
            return true
        } catch {
            syncLogger.error("sync failed code=SYNC_UNAVAILABLE")
            return false
        }
    }

    func resolveSyncConflict(_ conflict: SyncConflictPreview, useRemote: Bool) {
        do {
            try localStore.resolveConflict(id: conflict.id, useRemote: useRemote)
            syncConflicts = try localStore.pendingConflicts()
            if let snapshot = try localStore.loadSnapshot() { apply(snapshot) }
            toast = useRemote ? "已采用云端版本" : "已保留本机版本，将在下次联网时提交"
            Task { _ = await synchronize() }
        } catch {
            syncLogger.error("conflict resolution failed code=SYNC_RESOLUTION_FAILED")
            toast = "冲突处理失败，本机和云端数据均未覆盖"
        }
    }

    func deleteAllLocalData() {
        try? localStore.deleteAll()
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
        pendingPlanItem = nil
        syncConflicts = []
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
            proposePlanItem(title: title, detail: detail, importance: importance, timeframe: .month,
                            anchorDate: anchorDate, deadline: deadline, estimatedMinutes: estimatedMinutes)
            return "已生成“\(title)”本月里程碑候选，请确认后写入。"
        case .year:
            proposePlanItem(title: title, detail: detail, importance: importance, timeframe: .year,
                            anchorDate: anchorDate, deadline: deadline, estimatedMinutes: estimatedMinutes)
            return "已生成“\(title)”年度目标候选，请确认后写入。"
        }
    }

    private func proposePlanItem(
        title: String, detail: String, importance: Int, timeframe: PlanTimeframe,
        anchorDate: Date, deadline: Date?, estimatedMinutes: Int
    ) {
        let item = PlanItem(
            kind: timeframe == .year ? .goal : .milestone,
            title: title, detail: detail, importance: min(5, max(1, importance)),
            deadline: deadline, estimatedMinutes: max(20, estimatedMinutes),
            isSplittable: false, planningPeriod: normalizedPeriod(timeframe, containing: anchorDate)
        )
        pendingPlanItem = PlanItemProposal(
            item: item,
            title: timeframe == .year ? "年度目标预览" : "里程碑预览",
            summary: "只有点击确认后，这项内容才会写入路线。"
        )
    }

    func applyPendingPlanItem() {
        guard let proposal = pendingPlanItem else { return }
        beginTransaction("已撤销新增路线计划")
        planItems.append(proposal.item)
        pendingPlanItem = nil
        toast = "已确认并加入路线"
        save()
    }

    func dismissPendingPlanItem() {
        pendingPlanItem = nil
        toast = "未保存这项路线计划"
    }

    private func staleProposalMessage(for mode: ReplanProposalMode) -> String {
        switch mode {
        case .dayPlan: "任务或日程已变化，请重新生成计划"
        case .incompleteTask: "任务或日程已变化，请重新生成重排"
        case .languageReplan: "任务或日程已变化，请重新生成调整方案"
        case .adjustment: "任务或日程已变化，请重新生成方案"
        }
    }

    private func load() {
        if let snapshot = try? localStore.loadSnapshot() {
            apply(snapshot)
        } else {
            apply(DemoData.snapshot(calendar: calendar))
        }
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
        do {
            try localStore.saveSnapshotAndEnqueueChanges(makeSnapshot())
        } catch {
            toast = "本地保存失败，当前修改尚未持久化"
        }
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
        var day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: interval.start))!
        while day < interval.end {
            result.append(contentsOf: blocks(on: day).filter { $0.start < interval.end && $0.end > interval.start })
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return Dictionary(grouping: result, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.start < $1.start }
    }

    private func applyIncompleteReplanFixture() {
        let day = calendar.startOfDay(for: .now)
        let mathID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
        let englishID = UUID(uuidString: "30000000-0000-4000-8000-000000000002")!
        planItems = [
            PlanItem(
                id: mathID, kind: .task, title: "复习高数", detail: "第二章",
                importance: 5, deadline: calendar.date(byAdding: .day, value: 1, to: day),
                estimatedMinutes: 60, remainingMinutes: 60, preferredPeriod: .evening
            ),
            PlanItem(
                id: englishID, kind: .task, title: "复习英语", detail: "阅读",
                importance: 3, deadline: calendar.date(byAdding: .day, value: 2, to: day),
                estimatedMinutes: 50, remainingMinutes: 50, preferredPeriod: .evening
            )
        ]
        blocks = [
            ScheduleBlock(
                id: UUID(uuidString: "30000000-0000-4000-8000-000000000003")!,
                planItemID: mathID, title: "复习高数",
                start: calendar.date(on: day, hour: 19), end: calendar.date(on: day, hour: 20),
                kind: .focus, reason: "今晚优先复习", provenance: "Lamp"
            ),
            ScheduleBlock(
                id: UUID(uuidString: "30000000-0000-4000-8000-000000000004")!,
                planItemID: englishID, title: "复习英语",
                start: calendar.date(on: day, hour: 20, minute: 10), end: calendar.date(on: day, hour: 21),
                kind: .focus, reason: "按原计划复习", provenance: "Lamp"
            ),
            ScheduleBlock(
                id: UUID(uuidString: "30000000-0000-4000-8000-000000000005")!,
                title: "固定课程",
                start: calendar.date(on: day, hour: 21, minute: 15), end: calendar.date(on: day, hour: 22),
                kind: .fixed, reason: "外部固定日程", provenance: "Calendar"
            )
        ]
        recurringSchedules = []
        occurrenceOverrides = []
    }

    private func applyLanguageReplanFixture() {
        let day = calendar.startOfDay(for: .now)
        let mathID = UUID(uuidString: "50000000-0000-4000-8000-000000000001")!
        let englishID = UUID(uuidString: "50000000-0000-4000-8000-000000000002")!
        planItems = [
            PlanItem(
                id: mathID, kind: .task, title: "复习高数", detail: "第二章",
                importance: 5, deadline: calendar.date(byAdding: .day, value: 1, to: day),
                estimatedMinutes: 60, remainingMinutes: 60, preferredPeriod: .evening
            ),
            PlanItem(
                id: englishID, kind: .task, title: "复习英语", detail: "阅读",
                importance: 3, deadline: calendar.date(byAdding: .day, value: 2, to: day),
                estimatedMinutes: 50, remainingMinutes: 50, preferredPeriod: .evening
            )
        ]
        blocks = [
            ScheduleBlock(
                id: UUID(uuidString: "50000000-0000-4000-8000-000000000003")!,
                planItemID: mathID, title: "复习高数",
                start: calendar.date(on: day, hour: 20), end: calendar.date(on: day, hour: 21),
                kind: .focus, reason: "今晚复习", provenance: "Lamp"
            ),
            ScheduleBlock(
                id: UUID(uuidString: "50000000-0000-4000-8000-000000000004")!,
                planItemID: englishID, title: "复习英语",
                start: calendar.date(on: day, hour: 21, minute: 10), end: calendar.date(on: day, hour: 22),
                kind: .focus, reason: "按原计划复习", provenance: "Lamp"
            ),
            ScheduleBlock(
                id: UUID(uuidString: "50000000-0000-4000-8000-000000000005")!,
                title: "固定课程",
                start: calendar.date(on: day, hour: 22, minute: 15), end: calendar.date(on: day, hour: 23),
                kind: .fixed, reason: "外部固定日程", provenance: "Calendar"
            )
        ]
        recurringSchedules = []
        occurrenceOverrides = []
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

@MainActor
protocol LocalStore: AnyObject {
    func loadSnapshot() throws -> LampSnapshot?
    func saveSnapshotAndEnqueueChanges(_ snapshot: LampSnapshot) throws
    func deleteAll() throws
    func currentSyncCursor() throws -> Int64
    func mergeRemoteChanges(_ changes: [RemoteSyncChange], forceConflicts: Bool) throws -> [SyncConflictPreview]
    func pendingConflicts() throws -> [SyncConflictPreview]
    func resolveConflict(id: UUID, useRemote: Bool) throws
}

@MainActor
protocol OutboxStore: AnyObject {
    func pendingOutbox(limit: Int, now: Date) throws -> [LocalOutboxMutation]
    func acknowledgeOutbox(ids: [UUID]) throws
    func deferOutbox(id: UUID, retryAt: Date, errorCode: String) throws
}

@MainActor
protocol SyncEngine: AnyObject {
    func synchronize() async throws -> SyncResult
}

@MainActor
protocol SyncTransport: AnyObject {
    func push(_ mutations: [LocalOutboxMutation]) async throws
    func pull(after cursor: Int64, limit: Int) async throws -> [RemoteSyncChange]
}

struct RemoteSyncChange: Sendable, Equatable {
    var cursor: Int64
    var entityType: String
    var entityID: UUID
    var entityVersion: Int
    var operation: String
    var payload: Data?
    var clientMutationID: UUID
}

struct SyncResult: Sendable, Equatable {
    var pushed: Int
    var pulled: Int
    var conflicts: [SyncConflictPreview]
}

struct SyncConflictPreview: Identifiable, Sendable, Equatable {
    var id: UUID
    var entityType: String
    var entityID: UUID
    var localVersion: Int
    var remoteVersion: Int
    var requiresManualChoice: Bool
}

struct LocalOutboxMutation: Identifiable, Sendable, Equatable {
    var id: UUID
    var clientMutationID: UUID
    var deviceID: UUID
    var entityType: String
    var entityID: UUID
    var entityVersion: Int
    var operation: String
    var contentHash: String
    var payload: Data?
    var attemptCount: Int
    var nextAttemptAt: Date
}

@Model
private final class LocalSnapshotRecord {
    @Attribute(.unique) var key: String
    var payload: Data
    var updatedAt: Date

    init(payload: Data, updatedAt: Date = .now) {
        self.key = "current"
        self.payload = payload
        self.updatedAt = updatedAt
    }
}

@Model
private final class LocalEntityRecord {
    @Attribute(.unique) var key: String
    var entityType: String
    var entityID: UUID
    var version: Int
    var payload: Data?
    var contentHash: String
    var updatedAt: Date
    var deletedAt: Date?

    init(entityType: String, entityID: UUID, payload: Data, contentHash: String) {
        self.key = "\(entityType):\(entityID.uuidString.lowercased())"
        self.entityType = entityType
        self.entityID = entityID
        self.version = 1
        self.payload = payload
        self.contentHash = contentHash
        self.updatedAt = .now
    }
}

@Model
private final class LocalOutboxRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var clientMutationID: UUID
    var deviceID: UUID
    var entityType: String
    var entityID: UUID
    var entityVersion: Int
    var operation: String
    var contentHash: String
    var payload: Data?
    var attemptCount: Int
    var nextAttemptAt: Date
    var lastErrorCode: String?
    var createdAt: Date

    init(deviceID: UUID, entity: LocalEntityRecord, operation: String) {
        self.id = UUID()
        self.clientMutationID = UUID()
        self.deviceID = deviceID
        self.entityType = entity.entityType
        self.entityID = entity.entityID
        self.entityVersion = entity.version
        self.operation = operation
        self.contentHash = entity.contentHash
        self.payload = entity.payload
        self.attemptCount = 0
        self.nextAttemptAt = .now
        self.createdAt = .now
    }
}

@Model
private final class LocalSyncState {
    @Attribute(.unique) var key: String
    var deviceID: UUID
    var cursor: Int64

    init() {
        self.key = "primary"
        self.deviceID = UUID()
        self.cursor = 0
    }
}

@Model
private final class LocalConflictRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var key: String
    var entityType: String
    var entityID: UUID
    var localVersion: Int
    var remoteVersion: Int
    var remoteCursor: Int64
    var remoteOperation: String
    var remotePayload: Data?
    var remoteClientMutationID: UUID
    var requiresManualChoice: Bool
    var createdAt: Date

    init(change: RemoteSyncChange, localVersion: Int) {
        self.id = UUID()
        self.key = "\(change.entityType):\(change.entityID.uuidString.lowercased())"
        self.entityType = change.entityType
        self.entityID = change.entityID
        self.localVersion = localVersion
        self.remoteVersion = change.entityVersion
        self.remoteCursor = change.cursor
        self.remoteOperation = change.operation
        self.remotePayload = change.payload
        self.remoteClientMutationID = change.clientMutationID
        self.requiresManualChoice = change.operation == "delete" ||
            ["plan_node", "schedule_block", "memory", "planning_rule"].contains(change.entityType)
        self.createdAt = .now
    }

    var preview: SyncConflictPreview {
        SyncConflictPreview(
            id: id, entityType: entityType, entityID: entityID,
            localVersion: localVersion, remoteVersion: remoteVersion,
            requiresManualChoice: requiresManualChoice
        )
    }

    var remoteChange: RemoteSyncChange {
        RemoteSyncChange(
            cursor: remoteCursor, entityType: entityType, entityID: entityID,
            entityVersion: remoteVersion, operation: remoteOperation,
            payload: remotePayload, clientMutationID: remoteClientMutationID
        )
    }
}

@MainActor
final class SwiftDataLocalStore: LocalStore, OutboxStore {
    private static let migrationMarker = "lamp.swiftdata.migration.v1"
    private let container: ModelContainer
    private let context: ModelContext
    private let legacyJSONURL: URL
    private let defaults: UserDefaults

    init(databaseURL: URL, legacyJSONURL: URL, defaults: UserDefaults = .standard) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let schema = Schema([
            LocalSnapshotRecord.self, LocalEntityRecord.self, LocalOutboxRecord.self,
            LocalSyncState.self, LocalConflictRecord.self,
        ])
        self.container = try ModelContainer(for: schema, configurations: [ModelConfiguration(url: databaseURL)])
        self.context = ModelContext(container)
        self.legacyJSONURL = legacyJSONURL
        self.defaults = defaults
    }

    func loadSnapshot() throws -> LampSnapshot? {
        if !defaults.bool(forKey: Self.migrationMarker), FileManager.default.fileExists(atPath: legacyJSONURL.path) {
            let legacyData = try Data(contentsOf: legacyJSONURL)
            let snapshot = try JSONDecoder().decode(LampSnapshot.self, from: legacyData)
            try createEncryptedMigrationBackup(legacyData)
            do {
                try saveSnapshotAndEnqueueChanges(snapshot)
                defaults.set(true, forKey: Self.migrationMarker)
            } catch {
                context.rollback()
                return snapshot
            }
            return snapshot
        }
        let records = try context.fetch(FetchDescriptor<LocalSnapshotRecord>())
        guard let data = records.first(where: { $0.key == "current" })?.payload else { return nil }
        return try JSONDecoder().decode(LampSnapshot.self, from: data)
    }

    func saveSnapshotAndEnqueueChanges(_ snapshot: LampSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let snapshotData = try encoder.encode(snapshot)
        let snapshots = try context.fetch(FetchDescriptor<LocalSnapshotRecord>())
        if let record = snapshots.first(where: { $0.key == "current" }) {
            record.payload = snapshotData
            record.updatedAt = .now
        } else {
            context.insert(LocalSnapshotRecord(payload: snapshotData))
        }

        var encodedEntities: [(String, UUID, Data)] = []
        encodedEntities += try snapshot.planItems.map { ("plan_node", $0.id, try encoder.encode($0)) }
        encodedEntities += try snapshot.blocks.map { ("schedule_block", $0.id, try encoder.encode($0)) }
        encodedEntities += try snapshot.memories.map { ("memory", $0.id, try encoder.encode($0)) }
        encodedEntities += try snapshot.rules.map { ("planning_rule", $0.id, try encoder.encode($0)) }
        encodedEntities += try snapshot.temporaryStates.map { ("temporary_state", $0.id, try encoder.encode($0)) }
        encodedEntities += try snapshot.recurringSchedules.map { ("recurring_rule", $0.id, try encoder.encode($0)) }
        encodedEntities += try snapshot.occurrenceOverrides.map { ("occurrence_override", $0.id, try encoder.encode($0)) }
        try synchronizeEntities(encodedEntities)
        try context.save()
    }

    func pendingOutbox(limit: Int, now: Date) throws -> [LocalOutboxMutation] {
        var descriptor = FetchDescriptor<LocalOutboxRecord>(
            predicate: #Predicate { $0.nextAttemptAt <= now },
            sortBy: [SortDescriptor(\LocalOutboxRecord.createdAt)]
        )
        descriptor.fetchLimit = min(100, max(1, limit))
        return try context.fetch(descriptor).map {
            LocalOutboxMutation(
                id: $0.id, clientMutationID: $0.clientMutationID, deviceID: $0.deviceID,
                entityType: $0.entityType, entityID: $0.entityID, entityVersion: $0.entityVersion,
                operation: $0.operation, contentHash: $0.contentHash, payload: $0.payload,
                attemptCount: $0.attemptCount, nextAttemptAt: $0.nextAttemptAt
            )
        }
    }

    func acknowledgeOutbox(ids: [UUID]) throws {
        let selected = Set(ids)
        for record in try context.fetch(FetchDescriptor<LocalOutboxRecord>()) where selected.contains(record.id) {
            context.delete(record)
        }
        try context.save()
    }

    func deferOutbox(id: UUID, retryAt: Date, errorCode: String) throws {
        guard let record = try context.fetch(FetchDescriptor<LocalOutboxRecord>()).first(where: { $0.id == id }) else { return }
        record.attemptCount = min(record.attemptCount + 1, 12)
        record.nextAttemptAt = retryAt
        record.lastErrorCode = String(errorCode.prefix(80))
        try context.save()
    }

    func deleteAll() throws {
        for value in try context.fetch(FetchDescriptor<LocalOutboxRecord>()) { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<LocalEntityRecord>()) { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<LocalSnapshotRecord>()) { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<LocalSyncState>()) { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<LocalConflictRecord>()) { context.delete(value) }
        try context.save()
        try? FileManager.default.removeItem(at: legacyJSONURL)
        try? FileManager.default.removeItem(at: encryptedBackupURL)
        defaults.removeObject(forKey: Self.migrationMarker)
        MigrationBackupKey.delete()
    }

    func currentSyncCursor() throws -> Int64 { try deviceState().cursor }

    func mergeRemoteChanges(_ changes: [RemoteSyncChange], forceConflicts: Bool) throws -> [SyncConflictPreview] {
        let entities = try context.fetch(FetchDescriptor<LocalEntityRecord>())
        let byKey = Dictionary(uniqueKeysWithValues: entities.map { ($0.key, $0) })
        let pending = try context.fetch(FetchDescriptor<LocalOutboxRecord>())
        let pendingKeys = Set(pending.map { "\($0.entityType):\($0.entityID.uuidString.lowercased())" })
        let existingConflicts = try context.fetch(FetchDescriptor<LocalConflictRecord>())
        var conflictsByKey = Dictionary(uniqueKeysWithValues: existingConflicts.map { ($0.key, $0) })
        var latestByKey: [String: RemoteSyncChange] = [:]
        for change in changes {
            let key = "\(change.entityType):\(change.entityID.uuidString.lowercased())"
            if change.cursor > (latestByKey[key]?.cursor ?? -1) { latestByKey[key] = change }
        }
        let orderedChanges = latestByKey.values.sorted(by: { $0.cursor < $1.cursor })
        var snapshot = try loadSnapshot() ?? LampSnapshot(
            planItems: [], blocks: [], memories: [], rules: [], temporaryStates: []
        )
        for change in orderedChanges {
            let key = "\(change.entityType):\(change.entityID.uuidString.lowercased())"
            let local = byKey[key]
            if forceConflicts || pendingKeys.contains(key) {
                if let conflict = conflictsByKey[key] {
                    conflict.localVersion = local?.version ?? 0
                    conflict.remoteVersion = change.entityVersion
                    conflict.remoteCursor = change.cursor
                    conflict.remoteOperation = change.operation
                    conflict.remotePayload = change.payload
                    conflict.remoteClientMutationID = change.clientMutationID
                    conflict.requiresManualChoice = change.operation == "delete" ||
                        ["plan_node", "schedule_block", "memory", "planning_rule"].contains(change.entityType)
                } else {
                    let conflict = LocalConflictRecord(change: change, localVersion: local?.version ?? 0)
                    if forceConflicts { conflict.requiresManualChoice = true }
                    context.insert(conflict)
                    conflictsByKey[key] = conflict
                }
                continue
            }
            guard change.entityVersion > (local?.version ?? 0) else { continue }
            try applyRemote(change, to: &snapshot)
            let hash = change.payload.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
                ?? SHA256.hash(data: Data("deleted:\(key):\(change.entityVersion)".utf8)).map { String(format: "%02x", $0) }.joined()
            if let local {
                local.version = change.entityVersion
                local.payload = change.payload
                local.contentHash = hash
                local.updatedAt = .now
                local.deletedAt = change.operation == "delete" ? .now : nil
            } else if let payload = change.payload {
                let record = LocalEntityRecord(entityType: change.entityType, entityID: change.entityID, payload: payload, contentHash: hash)
                record.version = change.entityVersion
                context.insert(record)
            }
        }
        if forceConflicts {
            let remoteKeys = Set(orderedChanges.map { "\($0.entityType):\($0.entityID.uuidString.lowercased())" })
            let remoteCursor = orderedChanges.map(\.cursor).max() ?? 0
            for item in pending where !remoteKeys.contains("\(item.entityType):\(item.entityID.uuidString.lowercased())") {
                let key = "\(item.entityType):\(item.entityID.uuidString.lowercased())"
                guard conflictsByKey[key] == nil else { continue }
                let absence = RemoteSyncChange(
                    cursor: remoteCursor, entityType: item.entityType, entityID: item.entityID,
                    entityVersion: 0, operation: "delete", payload: nil,
                    clientMutationID: UUID()
                )
                let conflict = LocalConflictRecord(change: absence, localVersion: item.entityVersion)
                conflict.requiresManualChoice = true
                context.insert(conflict)
                conflictsByKey[key] = conflict
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        if let record = try context.fetch(FetchDescriptor<LocalSnapshotRecord>()).first(where: { $0.key == "current" }) {
            record.payload = data
            record.updatedAt = .now
        } else {
            context.insert(LocalSnapshotRecord(payload: data))
        }
        if let maximum = changes.map(\.cursor).max() { try deviceState().cursor = max(try deviceState().cursor, maximum) }
        try context.save()
        return try pendingConflicts()
    }

    func pendingConflicts() throws -> [SyncConflictPreview] {
        try context.fetch(FetchDescriptor<LocalConflictRecord>(
            sortBy: [SortDescriptor(\LocalConflictRecord.createdAt)]
        )).map(\.preview)
    }

    func resolveConflict(id: UUID, useRemote: Bool) throws {
        guard let conflict = try context.fetch(FetchDescriptor<LocalConflictRecord>()).first(where: { $0.id == id }) else { return }
        let key = conflict.key
        let entity = try context.fetch(FetchDescriptor<LocalEntityRecord>()).first(where: { $0.key == key })
        let pending = try context.fetch(FetchDescriptor<LocalOutboxRecord>()).filter {
            $0.entityType == conflict.entityType && $0.entityID == conflict.entityID
        }
        var snapshot = try loadSnapshot() ?? LampSnapshot(
            planItems: [], blocks: [], memories: [], rules: [], temporaryStates: []
        )

        for record in pending { context.delete(record) }
        if useRemote {
            let change = conflict.remoteChange
            try applyRemote(change, to: &snapshot)
            let hash = change.payload.map(Self.contentHash) ?? Self.contentHash(Data("deleted:\(key):\(change.entityVersion)".utf8))
            if let entity {
                entity.version = change.entityVersion
                entity.payload = change.payload
                entity.contentHash = hash
                entity.updatedAt = .now
                entity.deletedAt = change.operation == "delete" ? .now : nil
            } else if let payload = change.payload {
                let inserted = LocalEntityRecord(
                    entityType: change.entityType, entityID: change.entityID,
                    payload: payload, contentHash: hash
                )
                inserted.version = change.entityVersion
                context.insert(inserted)
            }
        } else if let entity {
            entity.version = conflict.remoteVersion + 1
            entity.updatedAt = .now
            context.insert(LocalOutboxRecord(
                deviceID: try deviceState().deviceID,
                entity: entity,
                operation: entity.deletedAt == nil ? "upsert" : "delete"
            ))
        } else {
            let hash = Self.contentHash(Data("deleted:\(key):\(conflict.remoteVersion + 1)".utf8))
            let tombstone = LocalEntityRecord(
                entityType: conflict.entityType, entityID: conflict.entityID,
                payload: Data(), contentHash: hash
            )
            tombstone.version = conflict.remoteVersion + 1
            tombstone.payload = nil
            tombstone.deletedAt = .now
            context.insert(tombstone)
            context.insert(LocalOutboxRecord(
                deviceID: try deviceState().deviceID, entity: tombstone, operation: "delete"
            ))
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshotData = try encoder.encode(snapshot)
        if let record = try context.fetch(FetchDescriptor<LocalSnapshotRecord>()).first(where: { $0.key == "current" }) {
            record.payload = snapshotData
            record.updatedAt = .now
        } else {
            context.insert(LocalSnapshotRecord(payload: snapshotData))
        }
        context.delete(conflict)
        try context.save()
    }

    private static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func synchronizeEntities(_ desired: [(String, UUID, Data)]) throws {
        let syncState = try deviceState()
        let existing = try context.fetch(FetchDescriptor<LocalEntityRecord>())
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })
        let desiredKeys = Set(desired.map { "\($0.0):\($0.1.uuidString.lowercased())" })
        for (entityType, entityID, payload) in desired {
            let key = "\(entityType):\(entityID.uuidString.lowercased())"
            let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            if let record = existingByKey[key] {
                guard record.contentHash != hash || record.deletedAt != nil else { continue }
                record.version += 1
                record.payload = payload
                record.contentHash = hash
                record.updatedAt = .now
                record.deletedAt = nil
                context.insert(LocalOutboxRecord(deviceID: syncState.deviceID, entity: record, operation: "upsert"))
            } else {
                let record = LocalEntityRecord(entityType: entityType, entityID: entityID, payload: payload, contentHash: hash)
                context.insert(record)
                context.insert(LocalOutboxRecord(deviceID: syncState.deviceID, entity: record, operation: "upsert"))
            }
        }
        for record in existing where record.deletedAt == nil && !desiredKeys.contains(record.key) {
            record.version += 1
            record.payload = nil
            record.contentHash = SHA256.hash(data: Data("deleted:\(record.key):\(record.version)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            record.updatedAt = .now
            record.deletedAt = .now
            context.insert(LocalOutboxRecord(deviceID: syncState.deviceID, entity: record, operation: "delete"))
        }
    }

    private func deviceState() throws -> LocalSyncState {
        if let state = try context.fetch(FetchDescriptor<LocalSyncState>()).first(where: { $0.key == "primary" }) { return state }
        let state = LocalSyncState()
        context.insert(state)
        return state
    }

    private var encryptedBackupURL: URL {
        legacyJSONURL.deletingLastPathComponent().appendingPathComponent("snapshot.migration-backup.aesgcm")
    }

    private func createEncryptedMigrationBackup(_ data: Data) throws {
        let sealed = try AES.GCM.seal(data, using: MigrationBackupKey.loadOrCreate())
        guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        try combined.write(to: encryptedBackupURL, options: .atomic)
    }

    private func applyRemote(_ change: RemoteSyncChange, to snapshot: inout LampSnapshot) throws {
        if change.operation == "delete" {
            switch change.entityType {
            case "plan_node": snapshot.planItems.removeAll { $0.id == change.entityID }
            case "schedule_block": snapshot.blocks.removeAll { $0.id == change.entityID }
            case "memory": snapshot.memories.removeAll { $0.id == change.entityID }
            case "planning_rule": snapshot.rules.removeAll { $0.id == change.entityID }
            case "temporary_state": snapshot.temporaryStates.removeAll { $0.id == change.entityID }
            case "recurring_rule": snapshot.recurringSchedules.removeAll { $0.id == change.entityID }
            case "occurrence_override": snapshot.occurrenceOverrides.removeAll { $0.id == change.entityID }
            default: break
            }
            return
        }
        guard let payload = change.payload else { throw CocoaError(.coderInvalidValue) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch change.entityType {
        case "plan_node": replace(&snapshot.planItems, with: try decoder.decode(PlanItem.self, from: payload))
        case "schedule_block": replace(&snapshot.blocks, with: try decoder.decode(ScheduleBlock.self, from: payload))
        case "memory": replace(&snapshot.memories, with: try decoder.decode(MemoryFact.self, from: payload))
        case "planning_rule": replace(&snapshot.rules, with: try decoder.decode(PlanningRule.self, from: payload))
        case "temporary_state": replace(&snapshot.temporaryStates, with: try decoder.decode(TemporaryState.self, from: payload))
        case "recurring_rule": replace(&snapshot.recurringSchedules, with: try decoder.decode(RecurringScheduleRule.self, from: payload))
        case "occurrence_override": replace(&snapshot.occurrenceOverrides, with: try decoder.decode(ScheduleOccurrenceOverride.self, from: payload))
        default: throw CocoaError(.coderInvalidValue)
        }
    }

    private func replace<T: Identifiable>(_ values: inout [T], with value: T) where T.ID == UUID {
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value } else { values.append(value) }
    }
}

@MainActor
private final class LegacyJSONLocalStore: LocalStore {
    private let url: URL
    init(url: URL) { self.url = url }
    func loadSnapshot() throws -> LampSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(LampSnapshot.self, from: Data(contentsOf: url))
    }
    func saveSnapshotAndEnqueueChanges(_ snapshot: LampSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
    func deleteAll() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
    func currentSyncCursor() throws -> Int64 { 0 }
    func mergeRemoteChanges(_ changes: [RemoteSyncChange], forceConflicts: Bool) throws -> [SyncConflictPreview] {
        changes.map { SyncConflictPreview(
            id: UUID(), entityType: $0.entityType, entityID: $0.entityID,
            localVersion: 0, remoteVersion: $0.entityVersion, requiresManualChoice: true
        ) }
    }
    func pendingConflicts() throws -> [SyncConflictPreview] { [] }
    func resolveConflict(id: UUID, useRemote: Bool) throws {}
}

@MainActor
final class OutboxSyncEngine: SyncEngine {
    private let localStore: any LocalStore & OutboxStore
    private let transport: any SyncTransport
    private let now: () -> Date

    init(localStore: any LocalStore & OutboxStore, transport: any SyncTransport, now: @escaping () -> Date = { .now }) {
        self.localStore = localStore
        self.transport = transport
        self.now = now
    }

    func synchronize() async throws -> SyncResult {
        let pending = try localStore.pendingOutbox(limit: 100, now: now())
        let cursor = try localStore.currentSyncCursor()
        if cursor == 0, !pending.isEmpty {
            let remote = try await transport.pull(after: 0, limit: 500)
            if !remote.isEmpty {
                let conflicts = try localStore.mergeRemoteChanges(remote, forceConflicts: true)
                return SyncResult(pushed: 0, pulled: 0, conflicts: conflicts)
            }
        }
        do {
            if !pending.isEmpty {
                try await transport.push(pending)
                try localStore.acknowledgeOutbox(ids: pending.map(\.id))
            }
        } catch SyncTransportFailure.conflict {
            let remote = try await transport.pull(after: localStore.currentSyncCursor(), limit: 500)
            let conflicts = try localStore.mergeRemoteChanges(remote, forceConflicts: false)
            return SyncResult(pushed: 0, pulled: remote.count - conflicts.count, conflicts: conflicts)
        } catch {
            for item in pending {
                let exponent = min(10, item.attemptCount)
                let delay = min(3_600.0, pow(2.0, Double(exponent)) * 2.0)
                try? localStore.deferOutbox(id: item.id, retryAt: now().addingTimeInterval(delay), errorCode: "SYNC_PUSH_FAILED")
            }
            throw error
        }
        let remote = try await transport.pull(after: localStore.currentSyncCursor(), limit: 500)
        let conflicts = try localStore.mergeRemoteChanges(remote, forceConflicts: false)
        return SyncResult(pushed: pending.count, pulled: remote.count - conflicts.count, conflicts: conflicts)
    }
}

private enum MigrationBackupKey {
    private static let service = "com.lamp.swiftdata-migration"
    private static let account = "snapshot-backup-key-v1"

    static func loadOrCreate() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return SymmetricKey(data: data)
        }
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteNoPermission) }
        return SymmetricKey(data: data)
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
