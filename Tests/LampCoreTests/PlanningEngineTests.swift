import Foundation
import Testing
@testable import LampCore

@Suite("Planning Engine deterministic fixtures")
struct PlanningEngineTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private var day: Date { Date(timeIntervalSince1970: 1_767_225_600) }

    private func context(days: Int = 1, fatigue: Double = 1, protected: [DateInterval] = []) -> PlanningContext {
        PlanningContext(
            horizonStart: calendar.date(on: day, hour: 8),
            horizonEnd: calendar.date(byAdding: .day, value: days, to: calendar.date(on: day, hour: 21))!,
            fatigueMultiplier: fatigue,
            protectedRanges: protected
        )
    }

    @Test("fixed classes and two flexible goals never overlap")
    func fixedAndFlexible() {
        let fixed = [ScheduleBlock(title: "Class", start: calendar.date(on: day, hour: 10), end: calendar.date(on: day, hour: 12), kind: .fixed)]
        let tasks = [PlanItem(kind: .task, title: "Math", estimatedMinutes: 90), PlanItem(kind: .task, title: "AI", estimatedMinutes: 90)]
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: tasks, fixed: fixed, context: context())
        #expect(PlanningEngine(calendar: calendar).isFeasible(blocks))
        #expect(blocks.filter { $0.kind == .focus }.count == 2)
    }

    @Test("deadline pressure outranks a low-importance distant task")
    func deadlinePressure() {
        let urgent = PlanItem(kind: .task, title: "Exam", importance: 3, deadline: day.addingTimeInterval(86_400), estimatedMinutes: 60)
        let distant = PlanItem(kind: .task, title: "Reading", importance: 2, deadline: day.addingTimeInterval(30 * 86_400), estimatedMinutes: 60)
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: [distant, urgent], fixed: [], context: context())
        #expect(blocks.first?.title == "Exam")
    }

    @Test("partial completion only schedules remaining duration")
    func partialCompletion() {
        let task = PlanItem(kind: .task, title: "Tool Calling", estimatedMinutes: 120, remainingMinutes: 60, progress: 0.5)
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: [task], fixed: [], context: context())
        #expect(blocks.reduce(0) { $0 + $1.durationMinutes } == 60)
    }

    @Test("new fixed event invalidates an old slot and causes a move")
    func newFixedEvent() {
        let task = PlanItem(kind: .task, title: "Study", estimatedMinutes: 60, preferredPeriod: .morning)
        let old = ScheduleBlock(planItemID: task.id, title: task.title, start: calendar.date(on: day, hour: 9), end: calendar.date(on: day, hour: 10), kind: .focus)
        let meeting = ScheduleBlock(title: "Meeting", start: calendar.date(on: day, hour: 9), end: calendar.date(on: day, hour: 11), kind: .fixed)
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: [task], fixed: [meeting], previous: [old], context: context())
        #expect(blocks.first(where: { $0.planItemID == task.id })?.start != old.start)
        #expect(PlanningEngine(calendar: calendar).isFeasible(blocks))
    }

    @Test("fatigue reduces scheduled workload")
    func fatigue() {
        let tasks = (0..<6).map { PlanItem(kind: .task, title: "Task \($0)", estimatedMinutes: 90) }
        let normal = PlanningEngine(calendar: calendar).makeSchedule(items: tasks, fixed: [], context: context())
        let tired = PlanningEngine(calendar: calendar).makeSchedule(items: tasks, fixed: [], context: context(fatigue: 0.5))
        #expect(tired.reduce(0) { $0 + $1.durationMinutes } < normal.reduce(0) { $0 + $1.durationMinutes })
    }

    @Test("protected time cannot be violated")
    func protectedTime() {
        let protected = DateInterval(start: calendar.date(on: day, hour: 12), end: calendar.date(on: day, hour: 15))
        let task = PlanItem(kind: .task, title: "Deep work", estimatedMinutes: 180)
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: [task], fixed: [], context: context(protected: [protected]))
        #expect(PlanningEngine(calendar: calendar).isFeasible(blocks, protected: [protected]))
    }

    @Test("early completion leaves free capacity")
    func earlyCompletion() {
        let finished = PlanItem(kind: .task, title: "Done", estimatedMinutes: 120, remainingMinutes: 0, progress: 1)
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: [finished], fixed: [], context: context())
        #expect(blocks.isEmpty)
    }

    @Test("preferred afternoon avoids late evening")
    func rhythmPreference() {
        let task = PlanItem(kind: .task, title: "Calculus", estimatedMinutes: 60, preferredPeriod: .afternoon)
        let block = PlanningEngine(calendar: calendar).makeSchedule(items: [task], fixed: [], context: context()).first
        let hour = block.map { calendar.component(.hour, from: $0.start) }
        #expect(hour != nil && (12..<18).contains(hour!))
    }

    @Test("dependency prevents child placement")
    func dependency() {
        let prerequisite = PlanItem(kind: .task, title: "Basics", estimatedMinutes: 60)
        let child = PlanItem(kind: .task, title: "Advanced", estimatedMinutes: 60, dependencyIDs: [prerequisite.id])
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: [prerequisite, child], fixed: [], context: context())
        #expect(blocks.contains { $0.planItemID == prerequisite.id })
        #expect(!blocks.contains { $0.planItemID == child.id })
    }

    @Test("stable prior placement wins an equal-priority tie")
    func scheduleStability() {
        let task = PlanItem(kind: .task, title: "Stable", importance: 3, estimatedMinutes: 60, preferredPeriod: .afternoon)
        let old = ScheduleBlock(planItemID: task.id, title: task.title, start: calendar.date(on: day, hour: 15), end: calendar.date(on: day, hour: 16), kind: .focus)
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: [task], fixed: [], previous: [old], context: context())
        #expect(blocks.first?.start == old.start)
    }
}

