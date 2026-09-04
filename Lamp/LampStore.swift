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
    @Published var hasCompletedOnboarding: Bool

    private let calendar: Calendar
    private let persistenceURL: URL

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "lamp.onboarding.complete")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.persistenceURL = base.appendingPathComponent("Lamp/snapshot.json")
        load()
    }

    var todayBlocks: [ScheduleBlock] {
        blocks.filter { calendar.isDateInToday($0.start) }.sorted { $0.start < $1.start }
    }

    var currentOrNextBlock: ScheduleBlock? {
        let now = Date.now
        return todayBlocks.first(where: { $0.start <= now && $0.end > now && $0.state == .planned })
            ?? todayBlocks.first(where: { $0.end > now && $0.state == .planned })
            ?? todayBlocks.first(where: { $0.state == .planned })
    }

    var focusMinutesToday: Int {
        todayBlocks.filter { $0.kind == .focus && $0.state != .missed }.reduce(0) { $0 + $1.durationMinutes }
    }

    func finishOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "lamp.onboarding.complete")
        scheduleMorningBriefIfPermitted()
    }

    func mark(_ block: ScheduleBlock, as state: CompletionState) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        blocks[index].state = state
        if let itemID = block.planItemID, let itemIndex = planItems.firstIndex(where: { $0.id == itemID }) {
            let minutes = block.durationMinutes
            if state == .completed {
                planItems[itemIndex].remainingMinutes = max(0, planItems[itemIndex].remainingMinutes - minutes)
            } else if state == .partial {
                planItems[itemIndex].remainingMinutes = max(20, planItems[itemIndex].remainingMinutes - minutes / 2)
            }
            let estimated = max(1, planItems[itemIndex].estimatedMinutes)
            planItems[itemIndex].progress = 1 - Double(planItems[itemIndex].remainingMinutes) / Double(estimated)
        }
        toast = state == .completed ? "已完成。今天向前了一点。" : state == .partial ? "已记录部分完成，可以补充发生了什么。" : "已记录，Lamp 会重新寻找合适时间。"
        save()
    }

    func process(input: String) -> String {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "告诉我发生了什么，或你想完成什么。" }

        if normalized.contains("累") || normalized.localizedCaseInsensitiveContains("exhausted") || normalized.contains("疲惫") {
            proposeFatigueReplan()
            return "知道了。我把今天的强度降下来，并保留了更多恢复时间。先看看调整方案。"
        }

        let title = inferredTitle(from: normalized)
        let deadline = normalized.contains("明天") ? calendar.date(byAdding: .day, value: 1, to: .now) : nil
        let item = PlanItem(kind: .task, title: title, detail: normalized, importance: deadline == nil ? 3 : 5, deadline: deadline, estimatedMinutes: 60)
        planItems.append(item)
        addToNextAvailableSlot(item)
        toast = "已加入计划 · 可撤销"
        save()
        return "已把“\(title)”加入计划，并放进了下一个合适的空档。"
    }

    func processWithAgent(input: String) async -> String {
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
            let item = PlanItem(
                kind: .task, title: title, detail: directive.arguments.detail ?? input,
                importance: directive.arguments.deadlineHint == nil ? 3 : 5,
                deadline: directive.arguments.deadlineHint == nil ? nil : calendar.date(byAdding: .day, value: 1, to: .now),
                estimatedMinutes: minutes
            )
            planItems.append(item)
            addToNextAvailableSlot(item)
            toast = "DeepSeek 已理解并加入计划 · 可撤销"
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
            title: "让今晚轻一点", summary: "今晚减少专注负担，留出恢复空间。",
            changes: affected.isEmpty ? ["今天的计划已经足够轻，不需要移动任务"] : affected.map { "“\(blocks[$0].title)”顺延到明天" },
            reason: "临时状态：今天疲惫", proposedBlocks: proposed
        )
    }

    func applyPendingReplan() {
        guard let proposal = pendingReplan else { return }
        blocks = proposal.proposedBlocks
        temporaryStates.append(TemporaryState(title: "疲惫", expiresAt: calendar.date(byAdding: .day, value: 1, to: .now)!, workloadMultiplier: 0.55))
        pendingReplan = nil
        toast = "新计划已应用 · 可在历史中撤销"
        save()
    }

    func deleteMemory(_ memory: MemoryFact) {
        memories.removeAll { $0.id == memory.id }
        save()
    }

    func toggleRule(_ rule: PlanningRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].isEnabled.toggle()
        save()
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
        if let newBlock = scheduled.first(where: { $0.planItemID == item.id }) { blocks.append(newBlock) }
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

    private func save() {
        let snapshot = LampSnapshot(planItems: planItems, blocks: blocks, memories: memories, rules: rules, temporaryStates: temporaryStates)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: persistenceURL, options: .atomic)
    }

    private func scheduleMorningBriefIfPermitted() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            var components = DateComponents()
            components.hour = 8
            let content = UNMutableNotificationContent()
            content.title = "早上好"
            content.body = "今天有 2 个重点。打开 Lamp 看看现在该做什么。"
            let request = UNNotificationRequest(identifier: "lamp.morning-brief", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
            UNUserNotificationCenter.current().add(request)
        }
    }
}
