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

    @Test("weekly recurrence expands with a stable occurrence ID")
    func weeklyRecurrenceExpansion() {
        let weekday = calendar.component(.weekday, from: day)
        let rule = RecurringScheduleRule(
            title: "每周研讨课",
            detail: "教室 A",
            startsOn: day,
            weekdays: [weekday],
            startMinute: 9 * 60 + 30,
            durationMinutes: 90,
            timezone: "UTC"
        )
        let first = RecurringScheduleEngine.occurrence(for: rule, on: day, calendar: calendar)
        let repeated = RecurringScheduleEngine.occurrence(for: rule, on: day, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!

        #expect(first?.id == repeated?.id)
        #expect(first?.start == calendar.date(on: day, hour: 9, minute: 30))
        #expect(first?.durationMinutes == 90)
        #expect(RecurringScheduleEngine.occurrence(for: rule, on: tomorrow, calendar: calendar) == nil)
    }

    @Test("an occurrence override changes only one weekly instance")
    func weeklyOccurrenceOverride() {
        let weekday = calendar.component(.weekday, from: day)
        let rule = RecurringScheduleRule(
            title: "原课程",
            detail: "",
            startsOn: day,
            weekdays: [weekday],
            startMinute: 10 * 60,
            durationMinutes: 60,
            timezone: "UTC"
        )
        let movedStart = calendar.date(on: day, hour: 14)
        let movedEnd = calendar.date(on: day, hour: 15)
        let override = ScheduleOccurrenceOverride(
            recurringRuleID: rule.id,
            occurrenceDate: day,
            state: .partial,
            title: "本周改期",
            start: movedStart,
            end: movedEnd
        )
        let occurrence = RecurringScheduleEngine.occurrence(for: rule, on: day, override: override, calendar: calendar)
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: day)!
        let nextOccurrence = RecurringScheduleEngine.occurrence(for: rule, on: nextWeek, calendar: calendar)

        #expect(occurrence?.title == "本周改期")
        #expect(occurrence?.state == .partial)
        #expect(occurrence?.start == movedStart)
        #expect(nextOccurrence?.title == "原课程")
        #expect(nextOccurrence?.state == .planned)
    }

    @Test("cancelled recurrence override hides only that instance")
    func cancelledOccurrence() {
        let weekday = calendar.component(.weekday, from: day)
        let rule = RecurringScheduleRule(
            title: "训练",
            detail: "",
            startsOn: day,
            weekdays: [weekday],
            startMinute: 18 * 60,
            durationMinutes: 60,
            timezone: "UTC"
        )
        let override = ScheduleOccurrenceOverride(
            recurringRuleID: rule.id,
            occurrenceDate: day,
            state: .missed,
            isCancelled: true
        )
        #expect(RecurringScheduleEngine.occurrence(for: rule, on: day, override: override, calendar: calendar) == nil)
        #expect(RecurringScheduleEngine.occurrence(
            for: rule,
            on: calendar.date(byAdding: .day, value: 7, to: day)!,
            calendar: calendar
        ) != nil)
    }

    @Test("candidate validator detects duplicates and fixed conflicts")
    func candidateConflictAndDuplicateDetection() {
        let fixed = ScheduleBlock(
            title: "项目会",
            start: calendar.date(on: day, hour: 10),
            end: calendar.date(on: day, hour: 11),
            kind: .fixed
        )
        let duplicate = ImageScheduleCandidate(
            title: fixed.title,
            startAt: fixed.start,
            endAt: fixed.end,
            timezone: "UTC",
            confidence: 0.95
        )
        let overlap = ImageScheduleCandidate(
            title: "客户电话",
            startAt: calendar.date(on: day, hour: 10, minute: 30),
            endAt: calendar.date(on: day, hour: 11, minute: 30),
            timezone: "UTC",
            confidence: 0.9
        )
        #expect(ScheduleCandidateValidator.issue(for: duplicate, blocks: [fixed], recurringSchedules: [], calendar: calendar)?.contains("相同") == true)
        #expect(ScheduleCandidateValidator.issue(for: overlap, blocks: [fixed], recurringSchedules: [], calendar: calendar)?.contains("冲突") == true)
    }

    @Test("legacy snapshots decode with empty recurrence arrays")
    func legacySnapshotCompatibility() throws {
        let original = DemoData.snapshot(now: day, calendar: calendar)
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "recurringSchedules")
        object.removeValue(forKey: "occurrenceOverrides")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(LampSnapshot.self, from: legacyData)

        #expect(decoded.blocks.count == original.blocks.count)
        #expect(decoded.recurringSchedules.isEmpty)
        #expect(decoded.occurrenceOverrides.isEmpty)
    }

    @Test("vision response decodes ISO dates and weekly rules")
    func visionResponseDecoding() throws {
        let json = #"{"analysisID":"8A62C0F3-5D30-46A6-9B9C-C7CA21F70A92","summary":"识别到课程","candidates":[{"id":"0B7D8D22-3FC7-438E-8C22-D4A58FF639B0","title":"设计课","detail":"教室 2","startAt":"2026-09-07T09:00:00Z","endAt":"2026-09-07T10:30:00Z","timezone":"UTC","confidence":0.91,"sourceEvidence":"周一 9:00","needsReview":false,"recurrence":{"kind":"weekly","weekdays":[2],"startsOn":"2026-09-07T00:00:00Z","endsOn":null}}],"warnings":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(ImageScheduleAnalysisResponse.self, from: Data(json.utf8))

        #expect(response.candidates.first?.recurrence.kind == .weekly)
        #expect(response.candidates.first?.recurrence.weekdays == [2])
        #expect(response.candidates.first?.startAt != nil)
    }

    @Test("planning periods round-trip and old items decode without them")
    func planningPeriodCompatibility() throws {
        let original = DemoData.snapshot(now: day, calendar: calendar)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LampSnapshot.self, from: encoded)
        #expect(decoded.planItems.contains { $0.planningPeriod?.timeframe == .year })

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var items = try #require(object["planItems"] as? [[String: Any]])
        for index in items.indices { items[index].removeValue(forKey: "planningPeriod") }
        object["planItems"] = items
        let legacy = try JSONDecoder().decode(
            LampSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.planItems.allSatisfy { $0.planningPeriod == nil })
    }

    @Test("scheduling never starts before a mid-day horizon")
    func respectsExactHorizonStart() {
        let task = PlanItem(kind: .task, title: "Late request", estimatedMinutes: 60)
        let start = calendar.date(on: day, hour: 15, minute: 20)
        let end = calendar.date(on: day, hour: 21)
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(
            items: [task],
            fixed: [],
            context: PlanningContext(horizonStart: start, horizonEnd: end)
        )
        #expect(blocks.first?.start ?? .distantPast >= start)
    }
}
