import Foundation
import UserNotifications

@MainActor
final class LampStore: ObservableObject {
    @Published var planItems: [PlanItem] = []
    @Published var blocks: [ScheduleBlock] = []
    @Published var memories: [MemoryFact] = []
    @Published var rules: [PlanningRule] = []
    @Published var temporaryStates: [TemporaryState] = []
    @Published var pendingReplan: ReplanProposal?
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
        let interval = calendar.dateInterval(of: .weekOfYear, for: .now)
        return blocks.filter {
            guard let interval else { return false }
            return interval.contains($0.start) && $0.kind == .focus && $0.state != .missed
        }.reduce(0) { $0 + $1.durationMinutes }
    }

    func blocks(on date: Date) -> [ScheduleBlock] {
        blocks.filter { calendar.isDate($0.start, inSameDayAs: date) }.sorted { $0.start < $1.start }
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
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        blocks[index].state = .partial
        blocks[index].reason = feedback.note.isEmpty ? "已完成一部分" : feedback.note
        updatePlanProgress(for: block, completedMinutes: feedback.completedMinutes)

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
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        blocks[index].state = .missed
        blocks[index].reason = reason.isEmpty ? "本次未完成" : reason

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
        guard block.kind != .fixed else {
            toast = "固定日程请在来源日历中修改"
            return false
        }
        guard end > start else {
            toast = "结束时间需要晚于开始时间"
            return false
        }
        let conflicts = blocks.contains {
            $0.id != block.id && $0.kind == .fixed && start < $0.end && end > $0.start
        }
        guard !conflicts else {
            toast = "这个时间与固定日程冲突"
            return false
        }
        beginTransaction("已撤销日程修改")
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return false }
        blocks[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? block.title : title
        blocks[index].start = start
        blocks[index].end = end
        blocks[index].provenance = "手动调整"
        toast = "日程已更新"
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

    func importOCRLines(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        beginTransaction("已撤销图片导入")
        for line in lines.prefix(12) {
            let title = String(line.prefix(40))
            let item = PlanItem(kind: .task, title: title, detail: "从图片识别并由用户确认", estimatedMinutes: 60)
            planItems.append(item)
            addToNextAvailableSlot(item)
        }
        toast = "已导入 \(min(lines.count, 12)) 条候选事项"
        save()
    }

    func undoLastAction() {
        guard let transaction = undoTransaction else { return }
        apply(transaction.snapshot)
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
            beginTransaction("已撤销新增事项")
            let title = directive.arguments.title ?? inferredTitle(from: input)
            let minutes = min(480, max(20, directive.arguments.estimatedMinutes ?? 60))
            let item = PlanItem(
                kind: .task,
                title: title,
                detail: directive.arguments.detail ?? input,
                importance: directive.arguments.deadlineHint == nil ? 3 : 5,
                deadline: directive.arguments.deadlineHint == nil ? nil : calendar.date(byAdding: .day, value: 1, to: .now),
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
        pendingReplan = nil
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

    private func setBlock(_ block: ScheduleBlock, state: CompletionState, completedMinutes: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        blocks[index].state = state
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
    }

    private func makeSnapshot() -> LampSnapshot {
        LampSnapshot(
            planItems: planItems,
            blocks: blocks,
            memories: memories,
            rules: rules,
            temporaryStates: temporaryStates
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
}
