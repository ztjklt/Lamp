import Foundation

enum DemoData {
    static func snapshot(now: Date = .now, calendar: Calendar = .current) -> LampSnapshot {
        let today = calendar.startOfDay(for: now)
        var calculus = PlanItem(
            kind: .task, title: "微积分复习", detail: "第 4 章 · 积分应用", importance: 5,
            deadline: calendar.date(byAdding: .day, value: 8, to: today), estimatedMinutes: 240,
            remainingMinutes: 180, progress: 0.25, preferredPeriod: .afternoon
        )
        var agent = PlanItem(
            kind: .task, title: "Tool Calling 实践", detail: "完成天气工具练习", importance: 4,
            deadline: calendar.date(byAdding: .day, value: 4, to: today), estimatedMinutes: 150,
            remainingMinutes: 90, progress: 0.4, preferredPeriod: .morning
        )
        var finance = PlanItem(
            kind: .task, title: "财报阅读", detail: "学习现金流量表", importance: 2,
            deadline: calendar.date(byAdding: .day, value: 18, to: today), estimatedMinutes: 90,
            remainingMinutes: 90, progress: 0, preferredPeriod: .evening
        )
        let aiGoal = PlanItem(kind: .goal, title: "系统学习 AI", detail: "建立能独立做 Agent 产品的能力", importance: 5, estimatedMinutes: 2_400, remainingMinutes: 1_620, progress: 0.32)
        let mathGoal = PlanItem(kind: .goal, title: "掌握大学微积分", detail: "为 8 天后的考试做好准备", importance: 5, deadline: calculus.deadline, estimatedMinutes: 1_800, remainingMinutes: 720, progress: 0.6)
        let investingGoal = PlanItem(kind: .goal, title: "理解价值投资", detail: "能独立阅读公司财报", importance: 3, estimatedMinutes: 1_200, remainingMinutes: 930, progress: 0.22)

        calculus.parentID = mathGoal.id
        agent.parentID = aiGoal.id
        finance.parentID = investingGoal.id

        let blocks = [
            ScheduleBlock(title: "晨间准备", start: calendar.date(on: today, hour: 8), end: calendar.date(on: today, hour: 8, minute: 30), kind: .breakTime, reason: "给早晨留出缓冲"),
            ScheduleBlock(planItemID: agent.id, title: agent.title, start: calendar.date(on: today, hour: 9), end: calendar.date(on: today, hour: 10, minute: 30), kind: .focus, reason: "上午更适合需要专注的编程任务"),
            ScheduleBlock(title: "课程：金融学", start: calendar.date(on: today, hour: 11), end: calendar.date(on: today, hour: 12, minute: 30), kind: .fixed, reason: "已导入的固定课程", provenance: "系统日历"),
            ScheduleBlock(title: "午餐与休息", start: calendar.date(on: today, hour: 12, minute: 30), end: calendar.date(on: today, hour: 14), kind: .breakTime, reason: "保护恢复时间"),
            ScheduleBlock(planItemID: calculus.id, title: calculus.title, start: calendar.date(on: today, hour: 14), end: calendar.date(on: today, hour: 15, minute: 30), kind: .focus, reason: "考试还有 8 天，且下午完成率更高"),
            ScheduleBlock(planItemID: finance.id, title: finance.title, start: calendar.date(on: today, hour: 19), end: calendar.date(on: today, hour: 20), kind: .focus, reason: "截止压力较低，安排在轻量时段")
        ]

        let memories = [
            MemoryFact(icon: "sun.max.fill", title: "高强度学习更适合下午", detail: "你最近 4 次都把数学任务移到了下午。", source: "行为观察 · 已确认", confidence: 0.88, status: .confirmed),
            MemoryFact(icon: "moon.fill", title: "通常 23:30 前休息", detail: "晚间 22:30 后不安排高强度任务。", source: "你在设置中提供", confidence: 1, status: .confirmed),
            MemoryFact(icon: "bubble.left.fill", title: "偏好简短说明", detail: "重要变动说明原因，普通安排保持简洁。", source: "对话中确认", confidence: 0.95, status: .confirmed)
        ]
        let rules = [
            PlanningRule(title: "保留午休", detail: "每天 12:30–14:00 不安排专注任务", isHard: true, isEnabled: true),
            PlanningRule(title: "晚上降低强度", detail: "20:30 后只安排轻量或可选任务", isHard: false, isEnabled: true),
            PlanningRule(title: "保留空白", detail: "每天至少留下 90 分钟未安排时间", isHard: false, isEnabled: true)
        ]

        return LampSnapshot(
            planItems: [aiGoal, mathGoal, investingGoal, calculus, agent, finance],
            blocks: blocks, memories: memories, rules: rules, temporaryStates: []
        )
    }
}
