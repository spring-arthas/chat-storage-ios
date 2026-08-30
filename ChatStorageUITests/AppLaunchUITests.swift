import XCTest

@MainActor
final class AppLaunchUITests: XCTestCase {
    // [修改] 本地会话恢复再慢也不能阻塞登录页首屏，用户必须能立即手动登录。
    func testSlowSessionRestoreShowsLoginControlsImmediately() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "slow-restoring",
            "-uiRestoreDelayMilliseconds", "5000"
        ]
        app.launch()

        XCTAssertTrue(app.textFields["账号"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.secureTextFields["密码"].exists)
        XCTAssertTrue(app.buttons["登录"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["session.restore-indicator"].exists
        )
    }

    func testUnauthenticatedLaunchShowsLoginControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "unauthenticated"]
        app.launch()

        XCTAssertTrue(app.staticTexts["你的消息与文件，只属于你"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["账号"].exists)
        XCTAssertTrue(app.secureTextFields["密码"].exists)
        XCTAssertTrue(app.staticTexts["服务器状态"].exists)
        XCTAssertTrue(app.buttons["登录"].exists)
        XCTAssertTrue(app.buttons["使用 Face ID"].exists)
    }

    func testAuthenticatedLaunchCanSelectEveryTab() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        // [修改] 动态是独立主 Tab，固定放在消息和网盘之间。
        for title in ["消息", "动态", "网盘", "我的"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 3))
            tab.tap()
            XCTAssertTrue(tab.isSelected)
        }
    }

    // [修改] 动态页必须暴露双时间线、发布入口和完整互动按钮，防止只接入空 Tab。
    func testDynamicsExposesTimelineComposerAndInteractions() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        app.tabBars.buttons["动态"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["dynamic.scope.following"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["dynamic.scope.mine"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["dynamic.compose"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["dynamic.post.1001"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["dynamic.reply.1001"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["dynamic.repost.1001"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["dynamic.like.1001"].exists)

        app.descendants(matching: .any)["dynamic.compose"].tap()
        XCTAssertTrue(app.navigationBars["发布动态"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["dynamic.composer.text"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["dynamic.composer.media"].exists)
        XCTAssertTrue(app.buttons["发布"].exists)
    }

    func testProfileSettingsOpenServerAndExposeLogout() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        app.tabBars.buttons["我的"].tap()
        let serverButton = app.buttons["profile.server"]
        XCTAssertTrue(serverButton.waitForExistence(timeout: 3))
        serverButton.tap()
        XCTAssertTrue(app.navigationBars["服务器设置"].waitForExistence(timeout: 3))
        app.buttons["取消"].tap()

        XCTAssertTrue(app.buttons["退出登录"].exists)
    }

    // [修改] “我的”页补齐 Android 已有的传输入口，并压缩个人信息卡上方的默认留白。
    func testProfileExposesTransferMenusAndKeepsUserCardNearNavigationBar() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        app.tabBars.buttons["我的"].tap()
        let header = app.descendants(matching: .any)["profile.header"].firstMatch
        let navigationBar = app.navigationBars["我的"]
        XCTAssertTrue(header.waitForExistence(timeout: 3))
        XCTAssertTrue(navigationBar.exists)
        XCTAssertLessThan(header.frame.minY - navigationBar.frame.maxY, 24)

        let transferSettings = app.descendants(matching: .any)["profile.transfer-settings"].firstMatch
        let transferCenter = app.descendants(matching: .any)["profile.transfer-center"].firstMatch
        XCTAssertTrue(transferSettings.exists)
        XCTAssertTrue(transferCenter.exists)

        transferSettings.tap()
        XCTAssertTrue(app.navigationBars["文件传输"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["profile.transfer.wifi-only"].exists)
        app.navigationBars.buttons.firstMatch.tap()

        transferCenter.tap()
        XCTAssertTrue(app.navigationBars["传输中心"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()

        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["profile.clear-completed-transfers"].waitForExistence(timeout: 2))
    }

    // [修改] 网盘完整功能必须从 iPhone 主页面直接进入，防止功能只停留在状态层。
    func testDriveExposesCompleteToolbarControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        app.tabBars.buttons["网盘"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["drive.tree"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["drive.display-mode"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["drive.selection"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["drive.transfer-center"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["drive.add"].exists)
    }

    // [修改] 验证网盘入口不是静态图标，目录树、显示模式、选择模式和传输中心都能打开。
    func testDriveControlsOpenTheirInteractions() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()
        app.tabBars.buttons["网盘"].tap()

        // [修改] SwiftUI 工具栏会生成一个包裹节点和一个实际按钮；点击实际首个可交互节点即可避免层级重复。
        let tree = app.descendants(matching: .any)["drive.tree"].firstMatch
        XCTAssertTrue(tree.waitForExistence(timeout: 3))
        tree.tap()
        XCTAssertTrue(app.descendants(matching: .any)["drive.tree.sheet"].waitForExistence(timeout: 3))
        app.buttons["取消"].tap()

        let displayMode = app.descendants(matching: .any)["drive.display-mode"].firstMatch
        displayMode.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["drive.grid"].exists
                || app.descendants(matching: .any)["drive.list"].exists
        )

        let selection = app.descendants(matching: .any)["drive.selection"].firstMatch
        selection.tap()
        XCTAssertTrue(app.descendants(matching: .any)["drive.select-all"].waitForExistence(timeout: 2))
        selection.tap()

        app.descendants(matching: .any)["drive.transfer-center"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["传输中心"].waitForExistence(timeout: 3))
    }

    // [修改] 网盘滚动区不能带走搜索、当前目录和传输中心；下拉刷新动画必须出现在目录旁。
    func testDriveKeepsHeaderFixedAndShowsRefreshBesideBreadcrumb() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "authenticated", "-driveRefreshUITest", "-driveShowRefreshIndicator"
        ]
        app.launch()
        app.tabBars.buttons["网盘"].tap()

        let breadcrumb = app.descendants(matching: .any)["drive.breadcrumb"]
        let transferCenter = app.descendants(matching: .any)["drive.transfer-center"]
        let list = app.descendants(matching: .any)["drive.list"]
        let grid = app.descendants(matching: .any)["drive.grid"]
        XCTAssertTrue(breadcrumb.waitForExistence(timeout: 3))
        XCTAssertTrue(transferCenter.waitForExistence(timeout: 3))
        // [修改] 显示模式由 AppStorage 持久化，全量测试中列表或网格都必须验证固定顶部与下拉刷新。
        let scrollContent = list.waitForExistence(timeout: 1) ? list : grid
        XCTAssertTrue(scrollContent.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["drive.refresh-indicator"].exists)

        scrollContent.swipeUp()
        XCTAssertTrue(breadcrumb.isHittable)
        XCTAssertTrue(transferCenter.isHittable)

        // [修改] 从滚动区顶部向下拖出足够回弹距离，稳定越过 72pt 刷新阈值。
        let pullStart = scrollContent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        let pullEnd = scrollContent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
        pullStart.press(forDuration: 0.15, thenDragTo: pullEnd)
        let triggerCount = app.descendants(matching: .any)["drive.refresh-trigger-count"]
        XCTAssertTrue(triggerCount.waitForExistence(timeout: 2))
        let triggeredOnce = NSPredicate(format: "label == %@", "triggers=1")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: triggeredOnce, object: triggerCount)],
                timeout: 2
            ),
            .completed
        )
    }

    // [修改] 网盘视频应直接进入沉浸式全屏播放，退出后回到文件列表，不再先弹出普通预览页。
    func testDriveVideoOpensDirectlyInFullscreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()
        app.tabBars.buttons["网盘"].tap()

        let video = app.descendants(matching: .any)["drive.entry.4"]
        XCTAssertTrue(video.waitForExistence(timeout: 3))
        video.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["drive.video.fullscreen-view"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.descendants(matching: .any)["drive.preview"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["drive.video.play-pause"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["drive.video.stop"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["drive.video.progress"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["drive.video.close-to-list"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["drive.video.orientation"].exists)

        app.descendants(matching: .any)["drive.video.close-to-list"].tap()
        XCTAssertTrue(video.waitForExistence(timeout: 3))
    }

    func testChatOpensFriendDetailsAndPinMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        let conversation = app.buttons["conversation.2"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 3))
        conversation.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.conversation.screen"].waitForExistence(timeout: 3))

        app.buttons["chat.friend.avatar"].tap()
        XCTAssertTrue(app.staticTexts["好友资料"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["@xiaolin"].exists)
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["chat.more"].tap()
        XCTAssertTrue(app.buttons["置顶聊天"].waitForExistence(timeout: 2))
        app.buttons["置顶聊天"].tap()
        app.buttons["chat.more"].tap()
        XCTAssertTrue(app.buttons["取消置顶"].waitForExistence(timeout: 2))
    }

    func testFriendListUsesPullRefreshWithoutRefreshButton() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        XCTAssertFalse(app.buttons["刷新"].exists)
        let list = app.collectionViews["friends.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        list.swipeDown()
        XCTAssertTrue(list.exists)
    }

    func testFriendRowExposesUnreadMessageCount() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        let unread = app.descendants(matching: .any)["conversation.2.unread"]

        XCTAssertTrue(unread.waitForExistence(timeout: 3))
        XCTAssertEqual(unread.label, "2")
    }

    // [修改] 消息页顶部搜索和好友操作必须保持可见且语义分离。
    func testMessagesTopKeepsSearchVisibleAndSeparatesFriendActions() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        let search = app.descendants(matching: .any)["friends.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))

        let requests = app.descendants(matching: .any)["friends.requests"].firstMatch
        let addFriend = app.descendants(matching: .any)["friends.add"].firstMatch
        // [修改] SwiftUI 顶部操作异步渲染，等待入口和待处理数量稳定后再交互。
        XCTAssertTrue(requests.waitForExistence(timeout: 3))
        XCTAssertTrue(addFriend.waitForExistence(timeout: 3))
        let pendingValuePredicate = NSPredicate(format: "value == %@", "3个待处理")
        let pendingValueExpectation = XCTNSPredicateExpectation(predicate: pendingValuePredicate, object: requests)
        XCTAssertEqual(XCTWaiter.wait(for: [pendingValueExpectation], timeout: 3), .completed)

        app.collectionViews["friends.list"].swipeUp()
        // [修改] 滚动和布局更新异步完成，等待搜索框恢复可点击。
        let searchHittablePredicate = NSPredicate(format: "hittable == true")
        let searchHittableExpectation = XCTNSPredicateExpectation(predicate: searchHittablePredicate, object: search)
        XCTAssertEqual(XCTWaiter.wait(for: [searchHittableExpectation], timeout: 3), .completed)

        requests.tap()
        XCTAssertTrue(app.navigationBars["待接受好友申请"].waitForExistence(timeout: 3))
        app.buttons["完成"].tap()

        addFriend.tap()
        XCTAssertTrue(app.navigationBars["添加好友"].waitForExistence(timeout: 3))
    }

    // [修改] 稍后处理必须是消息页独立入口，不与好友申请或添加好友混在一起。
    func testMessagesTopOpensFavorites() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        let favorites = app.descendants(matching: .any)["messages.favorites"].firstMatch
        XCTAssertTrue(favorites.waitForExistence(timeout: 3))
        favorites.tap()

        XCTAssertTrue(app.navigationBars["稍后处理"].waitForExistence(timeout: 3))
    }

    // [修改] 聊天页隐藏根标签栏，键盘弹出后最新发送消息仍要完整可见。
    func testChatHidesRootTabsAndKeepsLatestSentMessageVisibleWithKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        let conversation = app.buttons["conversation.2"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 3))
        conversation.tap()

        XCTAssertTrue(app.descendants(matching: .any)["chat.conversation.screen"].waitForExistence(timeout: 3))
        // [修改] 导航转场结束后再确认根标签栏已移除，避免读取过渡态。
        let tabBarHiddenPredicate = NSPredicate(format: "exists == false")
        let tabBarHiddenExpectation = XCTNSPredicateExpectation(
            predicate: tabBarHiddenPredicate,
            object: app.tabBars.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [tabBarHiddenExpectation], timeout: 3), .completed)

        let input = app.descendants(matching: .any)["chat.composer.input"]
        let send = app.descendants(matching: .any)["chat.composer.send"]
        XCTAssertTrue(input.waitForExistence(timeout: 2))
        XCTAssertTrue(send.exists)

        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))

        for index in 1...8 {
            let text = "滚动验证消息 \(index)"
            input.tap()
            input.typeText(text)
            waitForComposerToBecomeSendable(send)
            send.tap()
            XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 2))
            waitForComposerToClear(input, sentText: text)
        }

        let finalText = "最后一条必须显示在键盘上方"
        input.tap()
        input.typeText(finalText)
        waitForComposerToBecomeSendable(send)
        send.tap()

        let latest = app.staticTexts[finalText]
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        let hittablePredicate = NSPredicate(format: "hittable == true")
        let hittableExpectation = XCTNSPredicateExpectation(predicate: hittablePredicate, object: latest)
        XCTAssertEqual(XCTWaiter.wait(for: [hittableExpectation], timeout: 3), .completed)
    }

    // [修改] 键盘回车必须发送；附件入口必须明确拆成照片、视频和文件，天然避免图片视频混选。
    func testChatReturnSendsAndAttachmentMenuSeparatesPhotoVideoAndFiles() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        let conversation = app.buttons["conversation.2"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 3))
        conversation.tap()

        let input = app.descendants(matching: .any)["chat.composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap()
        input.typeText("回车发送验证\n")
        XCTAssertTrue(app.staticTexts["回车发送验证"].waitForExistence(timeout: 3))

        let attachment = app.descendants(matching: .any)["chat.attachment.add"]
        XCTAssertTrue(attachment.waitForExistence(timeout: 2))
        attachment.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.attachment.photos"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["chat.attachment.videos"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["chat.attachment.files"].exists)
    }

    // [修改] 聊天视频必须与网盘视频一样提供播放、停止、进度和全屏控制。
    func testChatVideoPreviewExposesPlaybackAndFullscreenControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        let conversation = app.buttons["conversation.2"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 3))
        conversation.tap()

        let video = app.descendants(matching: .any)["chat.attachment.88"]
        XCTAssertTrue(video.waitForExistence(timeout: 3))
        video.tap()

        XCTAssertTrue(app.descendants(matching: .any)["chat.video.play-pause"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["chat.video.stop"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["chat.video.progress"].exists)

        app.descendants(matching: .any)["chat.video.fullscreen"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["chat.video.fullscreen-view"].waitForExistence(timeout: 3)
        )
        app.descendants(matching: .any)["chat.video.exit-fullscreen"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.video.play-pause"].waitForExistence(timeout: 3))
    }

    // [修改] 长按普通消息必须能看到转发、稍后处理和表情回应，并能分别打开对应交互。
    func testChatMessageContextMenuExposesForwardFavoriteAndReaction() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        let conversation = app.buttons["conversation.2"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 3))
        conversation.tap()

        let message = app.descendants(matching: .any)["chat.message.server-1"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["转发自 小周"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["chat.message.server-1.reaction.👍"].exists)
        message.press(forDuration: 1)
        XCTAssertTrue(app.buttons["转发"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["移出稍后处理"].exists)
        XCTAssertTrue(app.buttons["表情回应"].exists)

        app.buttons["转发"].tap()
        XCTAssertTrue(app.navigationBars["转发给好友"].waitForExistence(timeout: 3))
        app.buttons["取消"].tap()

        message.press(forDuration: 1)
        app.buttons["表情回应"].tap()
        XCTAssertTrue(app.navigationBars["表情回应"].waitForExistence(timeout: 3))
    }

    // [修改] 文本表情面板必须提供完整分类和最近使用入口，不再只有 12 个快捷 Unicode 表情。
    func testChatEmojiPanelExposesMacAlignedCategories() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        app.buttons["conversation.2"].tap()
        let emojiButton = app.buttons["表情"]
        XCTAssertTrue(emojiButton.waitForExistence(timeout: 3))
        emojiButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["chat.emoji.panel"].waitForExistence(timeout: 3))
        for category in ["笑脸", "手势", "人物", "动物", "食物", "活动", "旅行", "符号", "物品"] {
            XCTAssertTrue(app.descendants(matching: .any)["chat.emoji.category.\(category)"].exists)
        }
    }

    func testChatSupportsNativeLeftEdgeBackGesture() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "authenticated"]
        app.launch()

        let conversation = app.buttons["conversation.2"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 3))
        conversation.tap()
        XCTAssertTrue(app.buttons["chat.friend.avatar"].waitForExistence(timeout: 3))

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertTrue(conversation.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["chat.friend.avatar"].exists)
    }

    // [修改] 等待异步发送后输入框真正清空，避免下一轮文本叠加。
    private func waitForComposerToClear(
        _ input: XCUIElement,
        sentText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            let value = element.value as? String
            return value == "消息" || value == ""
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: input)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 2),
            .completed,
            "发送 \(sentText) 后输入框未清空",
            file: file,
            line: line
        )
    }

    // [修改] 草稿同步到界面后发送按钮才会启用，等待可发送状态再点击。
    private func waitForComposerToBecomeSendable(
        _ send: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "enabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: send)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 2),
            .completed,
            "输入草稿后发送按钮未启用",
            file: file,
            line: line
        )
    }
}
