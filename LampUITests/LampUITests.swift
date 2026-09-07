import XCTest

final class LampUITests: XCTestCase {
    func testNightlySleepAppearsInToday() {
        launch(extraArguments: ["-mock-sleep-directive", "-freeze-rest-animation"])
        app.descendants(matching: .any)["global.tellLamp"].tap()
        let input = app.descendants(matching: .any)["tellLamp.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap()
        input.typeText("每天晚上零点到早上八点睡觉")
        app.buttons["tellLamp.send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["tellLamp.response"].waitForExistence(timeout: 5))
        app.buttons["tellLamp.done"].tap()
        for _ in 0..<5 where !app.staticTexts["睡眠"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["睡眠"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "次日")).firstMatch.exists)

        let todaySleepCard = app.buttons["today.sleepCard"]
        for _ in 0..<4 where !todaySleepCard.isHittable { app.swipeUp() }
        XCTAssertTrue(todaySleepCard.waitForExistence(timeout: 2))
        todaySleepCard.tap()
        XCTAssertTrue(app.descendants(matching: .any)["task.sleepHero"].waitForExistence(timeout: 2))
        app.buttons["关闭"].tap()

        app.tabBars.buttons["日程"].tap()
        let weekSleepCard = app.buttons["week.sleepCard"]
        for _ in 0..<5 where !weekSleepCard.isHittable { app.swipeUp() }
        XCTAssertTrue(weekSleepCard.waitForExistence(timeout: 2))
    }
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testOnboardingCompletesAndPersistsInputs() {
        launch(showOnboarding: true)
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.continue"].waitForExistence(timeout: 3))
        app.descendants(matching: .any)["onboarding.continue"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.context"].waitForExistence(timeout: 2))
        app.descendants(matching: .any)["onboarding.continue"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.finish"].waitForExistence(timeout: 2))
        app.descendants(matching: .any)["onboarding.finish"].tap()
        XCTAssertTrue(app.tabBars.buttons["今天"].waitForExistence(timeout: 3))
    }

    func testEveryPrimaryTabAndTellLampRoute() {
        launch()
        let tellLamp = app.descendants(matching: .any)["global.tellLamp"]
        XCTAssertTrue(tellLamp.waitForExistence(timeout: 3))
        XCTAssertEqual(tellLamp.label, "和 Lamp 对话")
        XCTAssertTrue(app.tabBars.firstMatch.frame.contains(tellLamp.frame))

        let destinations = [
            (tab: "今天", marker: "today.now.details"),
            (tab: "日程", marker: "日程"),
            (tab: "路线", marker: "路线"),
            (tab: "我的", marker: "Lamp 了解的你")
        ]

        for destination in destinations {
            app.tabBars.buttons[destination.tab].tap()
            XCTAssertTrue(app.descendants(matching: .any)[destination.marker].waitForExistence(timeout: 2))
            XCTAssertTrue(tellLamp.exists)

            tellLamp.tap()
            XCTAssertTrue(app.descendants(matching: .any)["tellLamp.input"].waitForExistence(timeout: 2))
            app.buttons["tellLamp.done"].tap()
            XCTAssertTrue(app.descendants(matching: .any)[destination.marker].waitForExistence(timeout: 2))
        }
    }

    func testTodayDetailPartialMissedAndUndoActions() {
        launch()
        app.descendants(matching: .any)["today.now.details"].tap()
        XCTAssertTrue(app.buttons["taskEditor.save"].waitForExistence(timeout: 2))
        app.buttons["taskEditor.save"].tap()

        app.descendants(matching: .any)["today.now.partial"].tap()
        XCTAssertTrue(app.buttons["partial.submit"].waitForExistence(timeout: 2))
        app.buttons["partial.submit"].tap()
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 4))
        app.buttons["撤销"].tap()

        app.descendants(matching: .any)["today.now.missed"].tap()
        XCTAssertTrue(app.buttons["missed.submit"].waitForExistence(timeout: 2))
        app.buttons["missed.submit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["replan.keep"].waitForExistence(timeout: 3))
        app.descendants(matching: .any)["replan.keep"].tap()

        app.descendants(matching: .any)["today.now.complete"].tap()
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 4))
    }

    func testTellLampSuggestionAndSendProducesResult() {
        launch()
        app.descendants(matching: .any)["global.tellLamp"].tap()
        let suggestion = app.descendants(matching: .any)["tellLamp.suggestion.2"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 2))
        suggestion.tap()
        app.descendants(matching: .any)["tellLamp.send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["tellLamp.response"].waitForExistence(timeout: 3))
    }

    func testMockVisionCandidateCanBeReviewedAndImported() {
        launch(extraArguments: ["-mock-image-analysis"])
        app.descendants(matching: .any)["global.tellLamp"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["tellLamp.cancelImage"].waitForExistence(timeout: 3))
        let input = app.descendants(matching: .any)["tellLamp.input"]
        input.tap()
        input.typeText("图片中的时间改为周三下午四点")
        app.descendants(matching: .any)["tellLamp.send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["tellLamp.imageReview"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["tellLamp.imageGuidanceUsed"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'imageCandidate.guidanceConflict.'")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["tellLamp.importImage"].isEnabled)
        app.descendants(matching: .any)["tellLamp.importImage"].tap()
        XCTAssertTrue(app.tabBars.buttons["今天"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["产品评审"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 3))
    }

    func testImageGuidanceCanReplaceExistingCandidates() {
        launch(extraArguments: ["-mock-image-analysis"])
        app.descendants(matching: .any)["global.tellLamp"].tap()
        let input = app.descendants(matching: .any)["tellLamp.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap()
        input.typeText("先按图片识别")
        app.descendants(matching: .any)["tellLamp.send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["tellLamp.imageReview"].waitForExistence(timeout: 3))

        for _ in 0..<3 where !input.isHittable { app.swipeUp() }
        input.tap()
        input.typeText("改成周三下午四点")
        let send = app.descendants(matching: .any)["tellLamp.send"]
        if !send.isHittable { app.swipeUp() }
        send.tap()
        let confirm = app.buttons["tellLamp.confirmReanalyze"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["改成周三下午四点"].waitForExistence(timeout: 3))
    }

    func testFixedScheduleCanBeDeletedLocallyAndUndone() {
        launch()
        let fixed = app.staticTexts["课程：金融学"]
        XCTAssertTrue(fixed.waitForExistence(timeout: 3))
        fixed.tap()
        let delete = app.buttons["taskEditor.delete"]
        if !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        delete.tap()
        let confirmDelete = app.buttons["taskEditor.confirmDelete"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 2))
        confirmDelete.tap()
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["课程：金融学"].exists)
        app.buttons["撤销"].tap()
        XCTAssertTrue(app.staticTexts["课程：金融学"].waitForExistence(timeout: 3))
    }

    func testRecurringScheduleOffersSingleAndSeriesDeletion() {
        launch(extraArguments: ["-mock-recurring-schedule"])
        let recurring = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "每周设计复盘")).firstMatch
        for _ in 0..<4 where !recurring.isHittable { app.swipeUp() }
        XCTAssertTrue(recurring.waitForExistence(timeout: 3))
        recurring.tap()
        let delete = app.buttons["taskEditor.delete"]
        if !delete.isHittable { app.swipeUp() }
        delete.tap()
        XCTAssertTrue(app.buttons["仅删除本次"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["删除整个重复日程"].exists)
        app.buttons["taskEditor.deleteSingle"].firstMatch.tap()
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 3))
    }

    func testRoadmapGoalCanBeDeletedWithoutDeletingChildrenAndUndone() {
        launch()
        app.tabBars.buttons["路线"].tap()
        let goal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'roadmap.goal.'")).firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 2))
        goal.tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'roadmap.edit.'")).firstMatch
        edit.tap()
        let delete = app.buttons["goalEditor.delete"]
        if !delete.isHittable { app.swipeUp() }
        delete.tap()
        let confirmDelete = app.buttons["goalEditor.confirmDelete"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 2))
        confirmDelete.tap()
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 3))
        app.buttons["撤销"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'roadmap.goal.'")).firstMatch.waitForExistence(timeout: 3))
    }

    func testMemoryEditingAndPrivacyControlsHaveOutcomes() {
        launch()
        app.tabBars.buttons["我的"].tap()
        let menu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'memory.menu.'")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        menu.tap()
        app.buttons["编辑"].tap()
        XCTAssertTrue(app.buttons["memoryEditor.save"].waitForExistence(timeout: 2))
        app.buttons["memoryEditor.save"].tap()

        app.descendants(matching: .any)["memory.privacy"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["privacy.export"].waitForExistence(timeout: 2))
        app.descendants(matching: .any)["privacy.export"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["privacy.shareExport"].waitForExistence(timeout: 2))
        app.descendants(matching: .any)["privacy.clearCache"].tap()
        XCTAssertTrue(app.buttons["清除缓存"].waitForExistence(timeout: 2))
        app.buttons["清除缓存"].tap()
        app.descendants(matching: .any)["privacy.deleteLocal"].tap()
        XCTAssertTrue(app.alerts.buttons["取消"].waitForExistence(timeout: 2))
        app.alerts.buttons["取消"].tap()
    }

    func testRoadmapExpandsAndEditsGoal() {
        launch()
        app.tabBars.buttons["路线"].tap()
        let goal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'roadmap.goal.'")).firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 2))
        goal.tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'roadmap.edit.'")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 2))
        edit.tap()
        XCTAssertTrue(app.buttons["goalEditor.save"].waitForExistence(timeout: 2))
        app.buttons["goalEditor.save"].tap()
    }

    func testWeekSelectionRuleToggleAndMemoryDeleteUndo() {
        launch()
        app.tabBars.buttons["日程"].tap()
        let day = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'week.day.'")).element(boundBy: 1)
        XCTAssertTrue(day.waitForExistence(timeout: 2))
        day.tap()

        app.tabBars.buttons["我的"].tap()
        let rule = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'memory.rule.'")).firstMatch
        XCTAssertTrue(rule.waitForExistence(timeout: 2))
        let oldValue = rule.value as? String
        rule.tap()
        XCTAssertNotEqual(rule.value as? String, oldValue)

        let menu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'memory.menu.'")).firstMatch
        menu.tap()
        app.buttons["删除"].tap()
        XCTAssertTrue(app.buttons["删除记忆"].waitForExistence(timeout: 2))
        app.buttons["删除记忆"].tap()
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 3))
        app.buttons["撤销"].tap()
    }

    func testReplanApplyAndLocalDataDeletion() {
        launch()
        app.descendants(matching: .any)["today.now.missed"].tap()
        app.buttons["missed.submit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["replan.apply"].waitForExistence(timeout: 3))
        app.descendants(matching: .any)["replan.apply"].tap()

        app.tabBars.buttons["我的"].tap()
        app.descendants(matching: .any)["memory.privacy"].tap()
        app.descendants(matching: .any)["privacy.deleteLocal"].tap()
        XCTAssertTrue(app.alerts.buttons["永久删除"].waitForExistence(timeout: 2))
        app.alerts.buttons["永久删除"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.continue"].waitForExistence(timeout: 3))
    }

    func testScheduleNavigatesWeekMonthAndYear() {
        launch()
        app.tabBars.buttons["日程"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["schedule.add"].waitForExistence(timeout: 3))

        app.segmentedControls.buttons["月"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["schedule.month.day.1"].waitForExistence(timeout: 3))
        app.descendants(matching: .any)["schedule.next"].tap()
        app.descendants(matching: .any)["schedule.current"].tap()

        app.segmentedControls.buttons["年"].tap()
        let firstMonth = app.descendants(matching: .any)["schedule.year.month.1"]
        XCTAssertTrue(firstMonth.waitForExistence(timeout: 3))
        firstMonth.tap()
        XCTAssertTrue(app.descendants(matching: .any)["schedule.month.day.1"].waitForExistence(timeout: 3))
    }

    func testWeeklyPlanUsesPreviewBeforeWritingTimeline() {
        launch()
        app.tabBars.buttons["日程"].tap()
        app.descendants(matching: .any)["schedule.add"].tap()
        let title = app.textFields["planEditor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 2))
        title.tap()
        title.typeText("本周交互回归")
        app.buttons["planEditor.save"].tap()

        let apply = app.buttons["weeklyPreview.apply"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["本周交互回归"].exists)
        apply.tap()
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 4))
    }

    func testAnnualGoalCreatedInScheduleAppearsInRoadmap() {
        launch()
        app.tabBars.buttons["日程"].tap()
        app.segmentedControls.buttons["年"].tap()
        app.descendants(matching: .any)["schedule.add"].tap()
        let title = app.textFields["planEditor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 2))
        title.tap()
        title.typeText("年度产品愿景")
        app.buttons["planEditor.save"].tap()

        app.tabBars.buttons["路线"].tap()
        XCTAssertTrue(app.staticTexts["年度产品愿景"].waitForExistence(timeout: 3))
    }

    private func launch(showOnboarding: Bool = false, extraArguments: [String] = []) {
        app.launchArguments = ["-ui-testing"]
        if showOnboarding { app.launchArguments.append("-show-onboarding") }
        app.launchArguments.append(contentsOf: extraArguments)
        app.launch()
    }
}
