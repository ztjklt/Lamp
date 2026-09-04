import AppIntents

struct OpenTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "打开 Lamp 今天"
    static var description = IntentDescription("查看现在该做什么和今天的安排。")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        LampSharedActionQueue.enqueue(LampSharedAction(kind: .openToday))
        return .result(dialog: "正在打开 Lamp 的今天。")
    }
}

struct TellLampIntent: AppIntent {
    static var title: LocalizedStringResource = "告诉 Lamp"
    static var description = IntentDescription("快速告诉 Lamp 一个新目标或计划变化。")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        LampSharedActionQueue.enqueue(LampSharedAction(kind: .tellLamp))
        return .result(dialog: "Lamp 已准备好听你说。")
    }
}

struct LampShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenTodayIntent(), phrases: ["用 \(.applicationName) 看看现在做什么", "打开 \(.applicationName) 今天"], shortTitle: "现在做什么", systemImageName: "sparkles")
        AppShortcut(intent: TellLampIntent(), phrases: ["告诉 \(.applicationName)", "用 \(.applicationName) 安排一下"], shortTitle: "告诉 Lamp", systemImageName: "waveform")
    }
}
