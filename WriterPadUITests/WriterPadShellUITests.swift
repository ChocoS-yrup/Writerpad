import XCTest

@MainActor
final class WriterPadShellUITests: XCTestCase {
    private func makeApp(restoresLastProjectOnLaunch: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-writerpad.restore-last-project-on-launch",
            restoresLastProjectOnLaunch ? "YES" : "NO"
        ]
        return app
    }

    private func waitUntilEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "enabled == true"),
                    object: element
                )
            ],
            timeout: timeout
        ) == .completed
    }

    func testManuscriptExportOffersTXTAndPDFFormats() throws {
        let app = makeApp()
        app.launch()

        let createProject = app.buttons["새 작품"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 5))
        createProject.tap()
        let alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText("UI PDF 내보내기 \(UUID().uuidString.prefix(6))")
        alert.buttons["만들기"].tap()

        let moreButton = app.buttons["writerpad.workspace-more"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5))
        moreButton.tap()
        let exportButton = app.buttons["writerpad.manuscript-export"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 2))
        XCTAssertEqual(exportButton.label, "원고 내보내기")
        exportButton.tap()

        let format = app.segmentedControls["writerpad.manuscript-export-format"]
        XCTAssertTrue(format.waitForExistence(timeout: 3))
        XCTAssertTrue(format.buttons["TXT"].isSelected)
        format.buttons["PDF"].tap()
        XCTAssertTrue(format.buttons["PDF"].isSelected)
        XCTAssertTrue(app.staticTexts["A4 규격의 읽기용 PDF 파일로 저장합니다."].exists)
    }

    func testProjectEditModeRevealsDeletedProjectsButton() throws {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(
            element("writerpad.project-library", in: app)
                .waitForExistence(timeout: 5)
        )

        let editButton = app.buttons["writerpad.project-edit"]
        let deletedProjectsButton = app.buttons["writerpad.deleted-projects"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 2))
        XCTAssertTrue(deletedProjectsButton.waitForExistence(timeout: 2))
        XCTAssertFalse(deletedProjectsButton.isEnabled)

        editButton.tap()

        XCTAssertEqual(editButton.label, "완료")
        XCTAssertTrue(deletedProjectsButton.isEnabled)
        deletedProjectsButton.tap()
        XCTAssertTrue(app.navigationBars["삭제 목록"].waitForExistence(timeout: 3))
    }

    func testLibrarySettingsExposesServerLoginAndProjectSyncControls() throws {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(
            element("writerpad.project-library", in: app)
                .waitForExistence(timeout: 5)
        )
        let settings = app.buttons["writerpad.library-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()

        let syncSettings = app.buttons["writerpad.sync-settings"]
        XCTAssertTrue(syncSettings.waitForExistence(timeout: 3))
        syncSettings.tap()

        XCTAssertTrue(
            app.navigationBars["서버 동기화"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            element("writerpad.sync-email", in: app).exists
        )
        XCTAssertTrue(
            element("writerpad.sync-password", in: app).exists
        )
        XCTAssertTrue(
            app.buttons["writerpad.sync-sign-in"].exists
        )
        XCTAssertTrue(
            app.switches["writerpad.sync-all-projects"].exists
        )
    }

    func testProjectEditModeRenamesProjectAndKeepsLibraryVisible() throws {
        let app = makeApp()
        app.launch()
        let originalName = "UI 이름 변경 전 \(UUID().uuidString.prefix(6))"
        let renamedName = "UI 이름 변경 후 \(UUID().uuidString.prefix(6))"

        let createProject = app.buttons["새 작품"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 5))
        createProject.tap()
        var alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText(originalName)
        alert.buttons["만들기"].tap()

        let projectSwitcher = app.buttons["writerpad.project-switcher"]
        XCTAssertTrue(projectSwitcher.waitForExistence(timeout: 5))
        projectSwitcher.tap()
        XCTAssertTrue(
            element("writerpad.project-library", in: app)
                .waitForExistence(timeout: 3)
        )
        app.buttons["writerpad.project-edit"].tap()

        let renameButton = app.buttons["‘\(originalName)’ 작품명 수정"]
        XCTAssertTrue(renameButton.waitForExistence(timeout: 3))
        renameButton.tap()
        alert = app.alerts["작품 이름 변경"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let field = alert.textFields.firstMatch
        field.tap()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(renamedName)
        alert.buttons["변경"].tap()

        XCTAssertTrue(
            element("writerpad.project-library", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts[renamedName].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.staticTexts[originalName].exists)
    }

    func testBinderReorderHandleAndRowBodyFolderMoveStaySeparated() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = makeApp()
        app.launch()

        let createProject = app.buttons["새 작품"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 5))
        createProject.tap()
        let alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText("UI 바인더 드래그 \(UUID().uuidString.prefix(6))")
        alert.buttons["만들기"].tap()

        let notes = element("writerpad.binder-row-notes", in: app)
        if !notes.waitForExistence(timeout: 10) {
            let binderToggle = app.buttons["writerpad.binder-toggle"]
            if binderToggle.label == "바인더 열기" {
                binderToggle.tap()
            }
        }
        XCTAssertTrue(notes.waitForExistence(timeout: 5))

        func create(
            in container: XCUIElement,
            menuTitle: String,
            name: String
        ) {
            container.press(forDuration: 1)
            let command = app.buttons[menuTitle]
            XCTAssertTrue(command.waitForExistence(timeout: 2))
            command.tap()
            let prompt = app.alerts[menuTitle]
            if !prompt.waitForExistence(timeout: 3) {
                container.press(forDuration: 1)
                XCTAssertTrue(command.waitForExistence(timeout: 2))
                command.tap()
            }
            XCTAssertTrue(prompt.waitForExistence(timeout: 3))
            prompt.textFields.firstMatch.typeText(name)
            prompt.buttons["확인"].tap()
        }

        notes.tap()
        create(in: notes, menuTitle: "새 폴더", name: "이동 대상")
        let settingsBrowse = element("writerpad.binder-row-settings", in: app)
        XCTAssertTrue(settingsBrowse.waitForExistence(timeout: 3))
        create(in: settingsBrowse, menuTitle: "새 문서", name: "설정 영역 표식")
        let settingsMarker = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH '설정 영역 표식'"))
            .firstMatch
        let settingsHasChildState = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS '접힘' OR label CONTAINS '펼쳐짐'"
            ),
            object: settingsBrowse
        )
        wait(for: [settingsHasChildState], timeout: 3)
        if settingsBrowse.label.contains("접힘") {
            settingsBrowse.tap()
        }
        let settingsExpanded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS '펼쳐짐'"),
            object: settingsBrowse
        )
        wait(for: [settingsExpanded], timeout: 3)
        XCTAssertTrue(settingsMarker.waitForExistence(timeout: 3))

        notes.press(forDuration: 1)
        let orderingCommand = app.buttons["순서 정렬"]
        XCTAssertTrue(orderingCommand.waitForExistence(timeout: 2))
        orderingCommand.tap()
        XCTAssertTrue(
            element("writerpad.binder-ordering-banner", in: app)
                .waitForExistence(timeout: 2)
        )

        let movingFolder = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH '이동 대상'"))
            .firstMatch
        let notesLabel = app.staticTexts["writerpad.binder-row-notes"].firstMatch
        XCTAssertTrue(movingFolder.waitForExistence(timeout: 3))
        XCTAssertTrue(notesLabel.waitForExistence(timeout: 2))
        notesLabel.tap()
        XCTAssertTrue(movingFolder.waitForNonExistence(timeout: 3))
        notesLabel.tap()
        XCTAssertTrue(movingFolder.waitForExistence(timeout: 3))

        let characters = app.staticTexts["writerpad.binder-row-characters"].firstMatch
        let settings = app.staticTexts["writerpad.binder-row-settings"].firstMatch
        let binderList = element("writerpad.binder-list", in: app)
        XCTAssertTrue(characters.exists)
        XCTAssertTrue(settings.exists)
        XCTAssertTrue(binderList.exists)
        let screenOrigin = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0, dy: 0)
        )
        let settingsHandleCoordinate = screenOrigin.withOffset(
            CGVector(
                dx: binderList.frame.maxX - 18,
                dy: settings.frame.midY
            )
        )
        let beforeCharacters = screenOrigin.withOffset(
            CGVector(
                dx: binderList.frame.maxX - 18,
                dy: characters.frame.minY + 3
            )
        )
        settingsHandleCoordinate.press(
            forDuration: 0.6,
            thenDragTo: beforeCharacters,
            withVelocity: .slow,
            thenHoldForDuration: 0.5
        )

        let reordered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                settings.frame.minY < characters.frame.minY
            },
            object: nil
        )
        wait(for: [reordered], timeout: 4)

        let editOperation = app.segmentedControls[
            "writerpad.binder-ordering-banner"
        ]
        XCTAssertTrue(editOperation.waitForExistence(timeout: 2))
        editOperation.buttons["폴더 이동"].tap()
        XCTAssertTrue(editOperation.buttons["폴더 이동"].isSelected)

        notesLabel.tap()
        XCTAssertTrue(movingFolder.waitForNonExistence(timeout: 3))
        notesLabel.tap()
        XCTAssertTrue(movingFolder.waitForExistence(timeout: 3))
        movingFolder.coordinate(
            withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)
        ).press(
            forDuration: 0.8,
            thenDragTo: settingsMarker.coordinate(
                withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)
            ),
            withVelocity: .slow,
            thenHoldForDuration: 0.6
        )

        let movedFolderWasHidden = movingFolder.waitForNonExistence(timeout: 4)

        let done = app.buttons["완료"]
        XCTAssertTrue(done.waitForExistence(timeout: 2))
        done.tap()
        XCTAssertTrue(
            element("writerpad.binder-ordering-banner", in: app)
                .waitForNonExistence(timeout: 2)
        )

        if !movedFolderWasHidden {
            settings.tap()
            XCTAssertTrue(movingFolder.waitForNonExistence(timeout: 4))
        }
        settings.tap()
        XCTAssertTrue(movingFolder.waitForExistence(timeout: 4))
    }

    func testWorkspaceShellExposesBinderToolbarAndSelection() throws {
        let app = makeApp()
        app.launch()

        let createProject = app.buttons["새 작품"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 5))
        createProject.tap()

        let alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let projectName = "UI 화면 테스트 \(UUID().uuidString.prefix(6))"
        alert.textFields.firstMatch.typeText(projectName)
        alert.buttons["만들기"].tap()

        let binderToggle = app.buttons["writerpad.binder-toggle"]
        if binderToggle.waitForExistence(timeout: 3),
           binderToggle.label == "바인더 열기" {
            binderToggle.tap()
        }

        let binderList = element("writerpad.binder-list", in: app)
        XCTAssertTrue(binderList.waitForExistence(timeout: 5))
        for category in ["manuscript", "characters", "settings", "notes", "flow", "foreshadowing", "places", "trash"] {
            XCTAssertTrue(
                element("writerpad.binder-row-\(category)", in: app).exists,
                "\(category) 고정 항목이 보이지 않습니다."
            )
        }

        XCTAssertTrue(app.buttons["writerpad.project-switcher"].exists)
        XCTAssertTrue(app.buttons["writerpad.search-button"].exists)
        XCTAssertTrue(app.buttons["writerpad.split-button"].exists)
        XCTAssertTrue(element("writerpad.save-status", in: app).exists)

        app.buttons["writerpad.workspace-more"].tap()
        let settings = app.buttons["writerpad.settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 2))
        settings.tap()
        XCTAssertTrue(app.switches["writerpad.dark-mode-toggle"].waitForExistence(timeout: 2))
        for identifier in [
            "writerpad.editor-font-picker",
            "writerpad.editor-font-size",
            "writerpad.editor-line-spacing",
            "writerpad.editor-horizontal-inset",
            "writerpad.editor-vertical-inset",
            "writerpad.editor-bold",
            "writerpad.editor-typewriter-scrolling",
            "writerpad.smart-pairs-toggle"
        ] {
            XCTAssertTrue(
                reveal(identifier, in: app),
                "\(identifier) 설정 항목이 보이지 않습니다."
            )
        }
        app.buttons["완료"].tap()

        let manuscript = element("writerpad.binder-row-manuscript", in: app)
        XCTAssertTrue(manuscript.exists)
        manuscript.tap()
        XCTAssertTrue(element("writerpad.selection-summary", in: app).waitForExistence(timeout: 2))

        manuscript.press(forDuration: 1)
        let addVolume = app.buttons["새 권 추가"]
        XCTAssertTrue(addVolume.waitForExistence(timeout: 2))
        addVolume.tap()

        let firstChapter = app.staticTexts["001화"].firstMatch
        XCTAssertTrue(firstChapter.waitForExistence(timeout: 3))
        firstChapter.tap()
        XCTAssertTrue(
            element("writerpad.native-editor-text-view", in: app)
                .waitForExistence(timeout: 3)
        )
        let workspaceScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        workspaceScreenshot.name = "WriterPad dark writing workspace"
        workspaceScreenshot.lifetime = .keepAlways
        add(workspaceScreenshot)
    }

    func testStageSixBackupAndTrashControlsAreReachable() throws {
        let app = makeApp()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()

        let createProject = app.buttons["새 작품"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 5))
        createProject.tap()
        let alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText("UI 6단계 \(UUID().uuidString.prefix(6))")
        alert.buttons["만들기"].tap()

        let manuscript = element("writerpad.binder-row-manuscript", in: app)
        XCTAssertTrue(manuscript.waitForExistence(timeout: 5))
        manuscript.press(forDuration: 1)
        XCTAssertTrue(app.buttons["새 권 추가"].waitForExistence(timeout: 2))
        app.buttons["새 권 추가"].tap()

        let firstChapter = app.staticTexts["001화"].firstMatch
        XCTAssertTrue(firstChapter.waitForExistence(timeout: 5))
        firstChapter.tap()
        let editor = element("writerpad.native-editor-text-view", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("6단계 백업 화면 확인")

        app.buttons["writerpad.workspace-more"].tap()
        XCTAssertTrue(app.buttons["writerpad.backup-history"].waitForExistence(timeout: 2))
        app.buttons["writerpad.backup-history"].tap()

        let snapshot = element("writerpad.backup-snapshot", in: app).firstMatch
        XCTAssertTrue(snapshot.waitForExistence(timeout: 5))
        snapshot.tap()
        let pin = app.buttons["writerpad.backup-pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 3))
        pin.tap()
        XCTAssertTrue(app.buttons["보관 지정 해제"].waitForExistence(timeout: 3))

        app.buttons["writerpad.backup-delete"].tap()
        let deleteAlert = app.alerts["선택한 백업을 삭제할까요?"]
        XCTAssertTrue(deleteAlert.waitForExistence(timeout: 3))
        deleteAlert.buttons["취소"].tap()
        app.buttons["닫기"].tap()

        app.buttons["writerpad.workspace-more"].tap()
        XCTAssertTrue(app.buttons["writerpad.trash-management"].waitForExistence(timeout: 2))
        app.buttons["writerpad.trash-management"].tap()
        XCTAssertTrue(app.navigationBars["휴지통"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["휴지통이 비어 있습니다"].exists)
        app.buttons["닫기"].tap()
        XCUIDevice.shared.orientation = .portrait
    }

    func testPortraitBinderToggleCanOpenAndClose() throws {
        let app = makeApp()
        app.launch()

        let createProject = app.buttons["새 작품"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 5))
        createProject.tap()
        let alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText("UI 바인더 토글 \(UUID().uuidString.prefix(6))")
        alert.buttons["만들기"].tap()

        let binderToggle = app.buttons["writerpad.binder-toggle"]
        XCTAssertTrue(binderToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilEnabled(binderToggle))
        let binderList = element("writerpad.binder-list", in: app)
        if binderToggle.label == "바인더 닫기" {
            binderToggle.tap()
            XCTAssertTrue(binderList.waitForNonExistence(timeout: 3))
        }
        XCTAssertTrue(waitUntilEnabled(binderToggle))
        binderToggle.tap()
        XCTAssertTrue(binderList.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilEnabled(binderToggle))
        binderToggle.tap()
        XCTAssertTrue(binderList.waitForNonExistence(timeout: 3))
        XCTAssertTrue(element("writerpad.editor-placeholder", in: app).waitForExistence(timeout: 3))
    }

    func testProjectSwitcherReturnsToProjectLibrary() throws {
        let app = makeApp()
        app.launch()

        let createProject = app.buttons["새 작품"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 5))
        createProject.tap()
        let alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText("UI 작품 변경 \(UUID().uuidString.prefix(6))")
        alert.buttons["만들기"].tap()

        let projectSwitcher = app.buttons["writerpad.project-switcher"]
        XCTAssertTrue(projectSwitcher.waitForExistence(timeout: 5))
        projectSwitcher.tap()
        XCTAssertTrue(element("writerpad.project-library", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["새 작품"].exists)
    }

    func testReturnKeyCreatesNewProjectWithoutReopeningPreviousEditorSession() throws {
        let app = makeApp()
        app.launch()

        let firstName = "Enter 기존 작품 \(UUID().uuidString.prefix(6))"
        let secondName = "Enter 새 작품 \(UUID().uuidString.prefix(6))"
        let createProject = app.buttons["새 작품"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 5))
        createProject.tap()
        var alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText(firstName)
        alert.buttons["만들기"].tap()

        let projectSwitcher = app.buttons["writerpad.project-switcher"]
        XCTAssertTrue(projectSwitcher.waitForExistence(timeout: 5))
        projectSwitcher.tap()
        XCTAssertTrue(element("writerpad.project-library", in: app).waitForExistence(timeout: 3))

        createProject.tap()
        alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let nameField = alert.textFields.firstMatch
        nameField.typeText(secondName)
        nameField.typeText("\n")

        // XCUI's typeText newline does not dispatch UITextFieldDelegate's hardware-Return
        // callback on iOS Simulator. It must not propagate to the selected project row,
        // which was the original regression. Complete creation through the button when
        // the simulator dismisses the alert without dispatching that callback.
        if alert.exists {
            XCTAssertFalse(element("writerpad.binder-row-manuscript", in: app).exists)
            alert.buttons["만들기"].tap()
        } else {
            XCTAssertTrue(projectSwitcher.waitForExistence(timeout: 5))
        }

        XCTAssertTrue(projectSwitcher.waitForExistence(timeout: 8))
        XCTAssertFalse(app.alerts["원고를 저장하지 못했습니다"].exists)

        projectSwitcher.tap()
        XCTAssertTrue(element("writerpad.project-library", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["원고를 저장하지 못했습니다"].exists)
        XCTAssertGreaterThanOrEqual(app.cells.count, 2)
    }

    func testRelaunchAlwaysStartsAtProjectLibrary() throws {
        let app = makeApp()
        app.launch()

        let createProject = app.buttons["새 작품"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 5))
        createProject.tap()
        let alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText("UI 시작 화면 \(UUID().uuidString.prefix(6))")
        alert.buttons["만들기"].tap()
        XCTAssertTrue(app.buttons["writerpad.project-switcher"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()

        XCTAssertTrue(element("writerpad.project-library", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["새 작품"].exists)
    }

    func testNativeEditorAcceptsKoreanAndEmoji() throws {
        let app = makeApp()
        app.launch()

        let createProject = app.buttons["새 작품"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 5))
        createProject.tap()
        let alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText("UI 네이티브 편집기 \(UUID().uuidString.prefix(6))")
        alert.buttons["만들기"].tap()

        let binderToggle = app.buttons["writerpad.binder-toggle"]
        let manuscript = element("writerpad.binder-row-manuscript", in: app)
        if !manuscript.waitForExistence(timeout: 2),
           binderToggle.waitForExistence(timeout: 2),
           binderToggle.label == "바인더 열기" {
            XCTAssertTrue(waitUntilEnabled(binderToggle))
            binderToggle.tap()
        }
        XCTAssertTrue(manuscript.waitForExistence(timeout: 5))

        manuscript.press(forDuration: 1)
        let addVolume = app.buttons["새 권 추가"]
        XCTAssertTrue(addVolume.waitForExistence(timeout: 2))
        addVolume.tap()

        let firstEpisode = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH '001화'"))
            .firstMatch
        XCTAssertTrue(firstEpisode.waitForExistence(timeout: 8))
        firstEpisode.tap()

        let editor = app.textViews["writerpad.native-editor-text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("한글🙂")
        XCTAssertTrue((editor.value as? String)?.contains("한글🙂") == true)
        let characterCount = element("writerpad.character-count", in: app)
        XCTAssertTrue(characterCount.waitForExistence(timeout: 2))
        XCTAssertTrue(characterCount.label.contains("3"))
        editor.typeText("(")
        XCTAssertTrue((editor.value as? String)?.contains("한글🙂()") == true)
        editor.typeText("*")
        XCTAssertTrue(
            (editor.value as? String)?.contains("\n\n * * *\n\n") == true
        )
        editor.typeText("ㄴ")
        editor.typeText("ㄴ")
        XCTAssertTrue((editor.value as? String)?.contains("「」") == true)
        editor.typeText("ㄱ")
        editor.typeText("ㄱ")
        XCTAssertTrue((editor.value as? String)?.contains("『』") == true)
        editor.typeText(".")
        editor.typeText(".")
        editor.typeText(".")
        XCTAssertTrue((editor.value as? String)?.contains("⋯") == true)
    }

    func testLandscapeDualEditorAllowsOpeningSameDocumentTwice() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = makeApp()
        app.launch()

        let createProject = app.buttons["새 작품"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 5))
        createProject.tap()
        let alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let projectName = "UI 듀얼 편집기 \(UUID().uuidString.prefix(6))"
        alert.textFields.firstMatch.typeText(projectName)
        alert.buttons["만들기"].tap()

        let manuscript = element("writerpad.binder-row-manuscript", in: app)
        XCTAssertTrue(manuscript.waitForExistence(timeout: 5))

        let binderToggle = app.buttons["writerpad.binder-toggle"]
        XCTAssertTrue(binderToggle.waitForExistence(timeout: 3))
        binderToggle.tap()
        XCTAssertTrue(manuscript.waitForNonExistence(timeout: 3))
        binderToggle.tap()
        XCTAssertTrue(manuscript.waitForExistence(timeout: 3))

        let resizer = element("writerpad.binder-resizer", in: app)
        XCTAssertTrue(resizer.waitForExistence(timeout: 3))
        let initialWidth = try XCTUnwrap(Int(resizer.value as? String ?? ""))
        let dragStart = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.press(
            forDuration: 0.1,
            thenDragTo: dragStart.withOffset(CGVector(dx: 80, dy: 0))
        )
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(Int(resizer.value as? String ?? "")),
            initialWidth
        )

        manuscript.press(forDuration: 1)
        let addVolume = app.buttons["새 권 추가"]
        XCTAssertTrue(addVolume.waitForExistence(timeout: 2))
        addVolume.tap()

        let firstEpisode = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == 'writerpad.binder-row-user' AND label BEGINSWITH '001화'"
                )
            )
            .firstMatch
        let secondEpisode = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == 'writerpad.binder-row-user' AND label BEGINSWITH '002화'"
                )
            )
            .firstMatch
        XCTAssertTrue(firstEpisode.waitForExistence(timeout: 8))
        firstEpisode.tap()

        let splitButton = app.buttons["writerpad.split-button"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 3))
        splitButton.tap()
        let leftPane = element("writerpad.editor-pane-left", in: app)
        let rightPane = element("writerpad.editor-pane-right", in: app)
        XCTAssertTrue(leftPane.waitForExistence(timeout: 3))
        XCTAssertTrue(rightPane.waitForExistence(timeout: 3))

        XCTAssertTrue(secondEpisode.waitForExistence(timeout: 3))
        secondEpisode.tap()
        firstEpisode.tap()

        XCTAssertFalse(app.alerts["이미 열린 문서"].waitForExistence(timeout: 1))
        XCTAssertEqual(leftPane.value as? String, "활성")
        XCTAssertEqual(rightPane.value as? String, "비활성")

        app.buttons["writerpad.project-switcher"].tap()
        XCTAssertTrue(element("writerpad.project-library", in: app).waitForExistence(timeout: 3))
        let projectRow = app.staticTexts.matching(
            NSPredicate(format: "label == %@", projectName)
        ).firstMatch
        for _ in 0..<20 where !projectRow.exists {
            app.swipeUp()
        }
        XCTAssertTrue(projectRow.waitForExistence(timeout: 3))
        projectRow.tap()
        XCTAssertTrue(leftPane.waitForExistence(timeout: 3))
        XCTAssertTrue(rightPane.waitForExistence(timeout: 3))
        XCTAssertEqual(leftPane.value as? String, "활성")
        XCTAssertEqual(rightPane.value as? String, "비활성")

        splitButton.tap()
        XCTAssertTrue(rightPane.waitForNonExistence(timeout: 3))
        XCTAssertTrue(leftPane.exists)
        XCTAssertTrue(app.textViews["writerpad.native-editor-text-view"].exists)
    }

    func testEmptyRightPaneCanTakeActivationWithoutBlockingWorkspaceTouches() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = makeApp()
        app.launch()

        let createProject = app.buttons["새 작품"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 5))
        createProject.tap()
        let alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText("UI 빈 편집기 전환 \(UUID().uuidString.prefix(6))")
        alert.buttons["만들기"].tap()

        let manuscript = element("writerpad.binder-row-manuscript", in: app)
        XCTAssertTrue(manuscript.waitForExistence(timeout: 5))
        manuscript.press(forDuration: 1)
        let addVolume = app.buttons["새 권 추가"]
        XCTAssertTrue(addVolume.waitForExistence(timeout: 2))
        addVolume.tap()

        let firstEpisode = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == 'writerpad.binder-row-user' AND label BEGINSWITH '001화'"
                )
            )
            .firstMatch
        XCTAssertTrue(firstEpisode.waitForExistence(timeout: 8))
        firstEpisode.tap()

        let leftEditor = app.textViews["writerpad.native-editor-text-view"]
        XCTAssertTrue(leftEditor.waitForExistence(timeout: 5))
        leftEditor.tap()
        leftEditor.typeText("find find find")
        app.buttons["writerpad.split-button"].tap()

        let leftPane = element("writerpad.editor-pane-left", in: app)
        let rightPane = element("writerpad.editor-pane-right", in: app)
        let emptyRightPane = app.staticTexts
            .matching(identifier: "writerpad.editor-placeholder")
            .matching(NSPredicate(format: "label == '문서를 선택하세요'"))
            .firstMatch
        XCTAssertTrue(emptyRightPane.waitForExistence(timeout: 3))

        leftEditor.tap()
        XCTAssertEqual(leftPane.value as? String, "활성")
        emptyRightPane.tap()
        XCTAssertEqual(rightPane.value as? String, "활성")
        XCTAssertEqual(leftPane.value as? String, "비활성")
        leftPane.tap()
        XCTAssertEqual(leftPane.value as? String, "활성")
        rightPane.tap()
        XCTAssertEqual(rightPane.value as? String, "활성")

        leftPane.tap()
        let searchButton = app.buttons["writerpad.search-button"]
        XCTAssertTrue(searchButton.isHittable)
        searchButton.tap()
        let searchField = app.textViews["writerpad.document-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.typeText("find")
        let searchCount = app.staticTexts["writerpad.document-search-count"]
        XCTAssertEqual(searchCount.label, "1 / 3")
        let nextSearchResult = app.buttons["다음 검색 결과"]
        nextSearchResult.tap()
        XCTAssertEqual(searchCount.label, "2 / 3")
        nextSearchResult.tap()
        XCTAssertEqual(searchCount.label, "3 / 3")
        nextSearchResult.tap()
        XCTAssertEqual(searchCount.label, "1 / 3")
        app.buttons["writerpad.document-search-close"].tap()
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 3))
    }

    func testReopeningSplitKeepsThePreviouslyActivePane() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = makeApp()
        app.launch()

        app.buttons["새 작품"].tap()
        let createAlert = app.alerts["새 작품"]
        XCTAssertTrue(createAlert.waitForExistence(timeout: 3))
        createAlert.textFields.firstMatch.typeText("분할 활성 유지 \(UUID().uuidString.prefix(6))")
        createAlert.buttons["만들기"].tap()

        let manuscript = element("writerpad.binder-row-manuscript", in: app)
        XCTAssertTrue(manuscript.waitForExistence(timeout: 5))
        manuscript.press(forDuration: 1)
        let addVolume = app.buttons["새 권 추가"]
        XCTAssertTrue(addVolume.waitForExistence(timeout: 2))
        addVolume.tap()

        let firstEpisode = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == 'writerpad.binder-row-user' AND label BEGINSWITH '001화'"
                )
            )
            .firstMatch
        let secondEpisode = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == 'writerpad.binder-row-user' AND label BEGINSWITH '002화'"
                )
            )
            .firstMatch
        XCTAssertTrue(firstEpisode.waitForExistence(timeout: 8))
        firstEpisode.tap()

        let splitButton = app.buttons["writerpad.split-button"]
        splitButton.tap()
        let leftPane = element("writerpad.editor-pane-left", in: app)
        let rightPane = element("writerpad.editor-pane-right", in: app)
        let emptyRightPane = app.staticTexts
            .matching(identifier: "writerpad.editor-placeholder")
            .matching(NSPredicate(format: "label == '문서를 선택하세요'"))
            .firstMatch
        XCTAssertTrue(emptyRightPane.waitForExistence(timeout: 3))

        emptyRightPane.tap()
        secondEpisode.tap()
        XCTAssertEqual(leftPane.value as? String, "비활성")
        XCTAssertEqual(rightPane.value as? String, "활성")

        splitButton.tap()
        XCTAssertTrue(leftPane.waitForNonExistence(timeout: 3))
        splitButton.tap()
        XCTAssertTrue(leftPane.waitForExistence(timeout: 3))
        XCTAssertEqual(leftPane.value as? String, "비활성")
        XCTAssertEqual(rightPane.value as? String, "활성")

        leftPane.tap()
        XCTAssertEqual(leftPane.value as? String, "활성")
        splitButton.tap()
        XCTAssertTrue(rightPane.waitForNonExistence(timeout: 3))
        splitButton.tap()
        XCTAssertTrue(rightPane.waitForExistence(timeout: 3))
        XCTAssertEqual(leftPane.value as? String, "활성")
        XCTAssertEqual(rightPane.value as? String, "비활성")

        XCUIDevice.shared.orientation = .portrait
        let splitModeButton = app.buttons["writerpad.split-button"]
        let compactState = expectation(
            for: NSPredicate(format: "label == %@ AND enabled == 0", "좌우 분할"),
            evaluatedWith: splitModeButton
        )
        wait(for: [compactState], timeout: 3)
        XCTAssertTrue(rightPane.waitForNonExistence(timeout: 3))
        XCTAssertTrue(leftPane.exists)

        XCUIDevice.shared.orientation = .landscapeLeft
        let regularState = expectation(
            for: NSPredicate(format: "label == %@ AND enabled == 1", "분할 닫기"),
            evaluatedWith: splitModeButton
        )
        wait(for: [regularState], timeout: 3)
        XCTAssertTrue(rightPane.waitForExistence(timeout: 3))
        XCTAssertTrue(leftPane.exists)
    }

    func testSoftWrappedDocumentCanScrollAfterChapterRoundTrip() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = makeApp()
        app.launchArguments += [
            "-WriterPadScrollDiagnostics",
            "-writerpad.editor-typewriter-scrolling", "YES"
        ]
        app.launch()

        let createProject = app.buttons["새 작품"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 5))
        createProject.tap()
        let alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText("UI 자동 줄바꿈 스크롤 \(UUID().uuidString.prefix(6))")
        alert.buttons["만들기"].tap()

        let manuscript = element("writerpad.binder-row-manuscript", in: app)
        if !manuscript.waitForExistence(timeout: 2) {
            let binderToggle = app.buttons["writerpad.binder-toggle"]
            XCTAssertTrue(binderToggle.waitForExistence(timeout: 3))
            binderToggle.tap()
        }
        XCTAssertTrue(manuscript.waitForExistence(timeout: 5))
        manuscript.press(forDuration: 1)
        let addVolume = app.buttons["새 권 추가"]
        XCTAssertTrue(addVolume.waitForExistence(timeout: 2))
        addVolume.tap()

        func episode(_ title: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(
                    NSPredicate(
                        format: "identifier == 'writerpad.binder-row-user' AND label BEGINSWITH %@",
                        title
                    )
                )
                .firstMatch
        }

        let firstEpisode = episode("001화")
        let secondEpisode = episode("002화")
        XCTAssertTrue(firstEpisode.waitForExistence(timeout: 8))
        firstEpisode.tap()

        var editor = app.textViews["writerpad.native-editor-text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let source = "그래 이거지~~ㅇㄴㅁㅇㄴㅁㅇㅁㅇㅁㅇㅁㅇㅁㅇㅁㅌㄴㅋㅂㅋㅁㅂㅋㅁㅂㅋㅂㅋㅂㅋㅂㅋㅁㅂㅋㅁㅂㅋㅂㅋㅂㅋㅂㅋㅂㅋㅂㅋㅂ"
        editor.typeText(String(repeating: source, count: 13))
        let initiallyScrollable = expectation(
            for: NSPredicate(format: "label MATCHES '.*max=([1-9][0-9]{2,}|[2-9][0-9]\\.).*'"),
            evaluatedWith: editor
        )
        wait(for: [initiallyScrollable], timeout: 5)

        XCTAssertTrue(secondEpisode.waitForExistence(timeout: 3))
        secondEpisode.tap()
        let characterCount = element("writerpad.character-count", in: app)
        let secondLoaded = expectation(
            for: NSPredicate(format: "label CONTAINS '0자'"),
            evaluatedWith: characterCount
        )
        wait(for: [secondLoaded], timeout: 5)
        firstEpisode.tap()
        let firstRestored = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "\(source.count * 13)자"),
            evaluatedWith: characterCount
        )
        wait(for: [firstRestored], timeout: 5)
        editor = app.textViews["writerpad.native-editor-text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let restoredScrollable = expectation(
            for: NSPredicate(format: "label MATCHES '.*max=([1-9][0-9]{2,}|[2-9][0-9]\\.).*'"),
            evaluatedWith: editor
        )
        wait(for: [restoredScrollable], timeout: 5)

        let before = try scrollDiagnostic(from: editor.label)
        XCTAssertGreaterThan(before.maximumY, 100, editor.label)
        if before.maximumY - before.offsetY > 20 {
            editor.swipeUp(velocity: .slow)
            let after = try scrollDiagnostic(from: editor.label)
            XCTAssertGreaterThan(
                after.offsetY,
                before.offsetY + 20,
                "문서 전환 후 위 스와이프가 스크롤 위치를 바꾸지 못했습니다. before=\(before) after=\(after)"
            )
        } else {
            editor.swipeDown(velocity: .slow)
            let after = try scrollDiagnostic(from: editor.label)
            XCTAssertLessThan(
                after.offsetY,
                before.offsetY - 20,
                "문서 전환 후 아래 스와이프가 스크롤 위치를 바꾸지 못했습니다. before=\(before) after=\(after)"
            )
        }
    }

    func testEmptyProjectSearchClosesWithoutBlockingWorkspace() throws {
        let app = makeApp()
        app.launch()

        let createProject = app.buttons["새 작품"]
        XCTAssertTrue(createProject.waitForExistence(timeout: 5))
        createProject.tap()
        let alert = app.alerts["새 작품"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText("UI 빈 전체 검색 \(UUID().uuidString.prefix(6))")
        alert.buttons["만들기"].tap()

        let moreButton = app.buttons["writerpad.workspace-more"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5))
        moreButton.tap()
        let projectSearchButton = app.buttons["writerpad.project-search"]
        XCTAssertTrue(projectSearchButton.waitForExistence(timeout: 2))
        projectSearchButton.tap()

        let popup = element("writerpad.project-search-popup", in: app)
        let field = app.textViews["writerpad.project-search-field"]
        XCTAssertTrue(popup.waitForExistence(timeout: 3))
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "")

        app.buttons["writerpad.project-search-close"].tap()
        XCTAssertTrue(popup.waitForNonExistence(timeout: 3))
        XCTAssertTrue(moreButton.isHittable)
        moreButton.tap()
        XCTAssertTrue(projectSearchButton.waitForExistence(timeout: 2))
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func reveal(_ identifier: String, in app: XCUIApplication) -> Bool {
        let target = element(identifier, in: app)
        for _ in 0..<4 {
            if target.exists { return true }
            app.swipeUp()
        }
        return target.waitForExistence(timeout: 1)
    }

    private func scrollDiagnostic(from label: String) throws -> (offsetY: Double, maximumY: Double) {
        let pattern = #"offset=(-?[0-9.]+) max=(-?[0-9.]+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsLabel = label as NSString
        let range = NSRange(location: 0, length: nsLabel.length)
        guard let match = regex.firstMatch(in: label, range: range),
              let offset = Double(nsLabel.substring(with: match.range(at: 1))),
              let maximum = Double(nsLabel.substring(with: match.range(at: 2)))
        else {
            throw XCTSkip("스크롤 진단값을 읽을 수 없습니다: \(label)")
        }
        return (offset, maximum)
    }
}
