import Foundation
import Testing
@testable import AgentInteraction

@MainActor
struct WorkflowModelTests {
    @Test func approvalPublishesOnlyTheReviewedDraft() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let transport = StubTransport()
        transport.automaticReplies = ["待评审方案", nil]
        let model = sandbox.model(transport)

        model.start()
        try await waitUntil { transport.sent.count == 2 }

        #expect(transport.sent.map(\.session) == [transport.codex, transport.workBuddy])
        #expect(transport.sent.first?.text.contains(model.goal) == true)
        #expect(transport.sent.last?.text.contains("待评审方案") == true)
        #expect(model.current?.status == .running)
        #expect(model.current?.finalResult == nil)

        transport.automaticReplies[1] = #"{"decision":"approve"}"#
        try await waitUntil { model.current?.status == .complete }

        #expect(model.current?.finalResult == "待评审方案")
        let reloaded = sandbox.model(transport)
        #expect(reloaded.history.first?.finalResult == "待评审方案")
    }

    @Test func requestedRevisionReturnsToTheWorkerAndIsReviewedAgain() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let transport = StubTransport()
        transport.automaticReplies = [
            "原方案",
            #"{"decision":"revise","feedback":"补充回滚步骤"}"#,
            "补充后的方案",
            nil
        ]
        let model = sandbox.model(transport)
        model.workerSession = transport.workBuddy
        model.reviewerSession = transport.codex

        model.start()
        try await waitUntil { transport.sent.count == 4 }

        #expect(transport.sent.map(\.session) == [transport.workBuddy, transport.codex, transport.workBuddy, transport.codex])
        #expect(transport.sent.dropFirst(2).first?.text.contains("补充回滚步骤") == true)
        #expect(transport.sent.last?.text.contains("补充后的方案") == true)
        #expect(model.current?.finalResult == nil)

        transport.automaticReplies[3] = #"{"decision":"approve"}"#
        try await waitUntil { model.current?.status == .complete }
        #expect(model.current?.finalResult == "补充后的方案")
    }

    @Test func exhaustedRevisionsLeaveTheTaskWithoutAResult() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let transport = StubTransport()
        let verdict = #"{"decision":"revise","feedback":"需要检查边界条件"}"#
        transport.automaticReplies = ["初稿", verdict, "修订稿一", verdict, "修订稿二", verdict]
        let model = sandbox.model(transport)

        model.start()
        try await waitUntil { model.current?.status == .failed }

        #expect(transport.sent.count == 6)
        #expect(model.current?.finalResult == nil)
    }

    @Test func aPastedReviewerReplyCannotBypassTheApprovalGate() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let transport = StubTransport()
        transport.automaticReplies = ["未获批准的方案"]
        let model = sandbox.model(transport)
        var reviewer = transport.workBuddy
        reviewer.isManual = true
        model.reviewerSession = reviewer

        model.start()
        try await waitUntil { model.manualStep?.session == reviewer }
        #expect(model.current?.finalResult == nil)

        model.submitManualReply(#"评审通过 {"decision":"approve"}"#)
        try await waitUntil { model.current?.status == .failed }
        #expect(model.current?.finalResult == nil)
        #expect(transport.sent.count == 1)
    }

    @Test func manualHandoffsStillRequireReviewerApproval() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let transport = StubTransport()
        transport.hasAccess = false
        let model = sandbox.model(transport)
        var worker = transport.codex
        worker.isManual = true
        var reviewer = transport.workBuddy
        reviewer.isManual = true
        model.workerSession = worker
        model.reviewerSession = reviewer

        model.start()
        try await waitUntil { model.manualStep?.session == worker }
        model.submitManualReply("手动交接的方案")
        try await waitUntil { model.manualStep?.session == reviewer }

        #expect(model.manualStep?.message?.contains("手动交接的方案") == true)
        #expect(model.current?.finalResult == nil)
        model.submitManualReply(#"{"decision":"approve"}"#)
        try await waitUntil { model.current?.status == .complete }

        #expect(transport.sent.isEmpty)
        #expect(model.current?.finalResult == "手动交接的方案")
    }

    @Test func unresolvedSendWaitsAndNeverRetriesAutomatically() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let transport = StubTransport()
        transport.failNextSend = true
        let model = sandbox.model(transport)

        model.start()
        try await waitUntil { model.manualStep != nil }
        #expect(transport.sent.count == 1)
        #expect(!model.canContinueWatching)

        transport.automaticReplies = [nil, #"{"decision":"approve"}"#]
        model.submitManualReply("从原会话读取的方案")
        try await waitUntil { model.current?.status == .complete }

        #expect(transport.sent.count == 2)
        #expect(transport.sent.last?.text.contains("从原会话读取的方案") == true)
        #expect(model.current?.finalResult == "从原会话读取的方案")
    }

    @Test func stoppedTaskNeverSendsTheDraftForReview() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let transport = StubTransport()
        let model = sandbox.model(transport)

        model.start()
        try await waitUntil { transport.sent.count == 1 }
        model.stop()

        transport.automaticReplies = ["停止后收到的方案"]
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.current?.status == .stopped)
        #expect(model.current?.finalResult == nil)
        #expect(transport.sent.count == 1)
    }

    @Test func oneApplicationCannotFillBothRoles() {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let transport = StubTransport()
        let model = sandbox.model(transport)
        var secondSession = transport.codex
        secondSession.id = UUID()
        secondSession.conversationTitle = "另一个会话"
        model.reviewerSession = secondSession

        #expect(model.validationMessage != nil)
        model.start()
        #expect(transport.sent.isEmpty)
        #expect(model.current == nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition() {
            guard clock.now < deadline else { throw StubError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct Sandbox {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    @MainActor func model(_ transport: StubTransport) -> WorkflowModel {
        let model = WorkflowModel(
            transport: transport,
            store: RunStore(file: directory.appending(path: "runs.json")),
            watchDuration: .seconds(5),
            pollInterval: .milliseconds(5)
        )
        model.goal = "编写变更实施方案"
        model.workerSession = transport.codex
        model.reviewerSession = transport.workBuddy
        return model
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum StubError: Error {
    case uncertainSend
    case timeout
}

@MainActor
private final class StubTransport: DesktopTransporting {
    var hasAccess = true
    let codex = DesktopSession(appName: "Codex", bundleID: "test.codex", pid: 101, windowTitle: "Codex", conversationTitle: "方案")
    let workBuddy = DesktopSession(appName: "WorkBuddy", bundleID: "test.workbuddy", pid: 102, windowTitle: "WorkBuddy", conversationTitle: "计划")
    var sent: [DesktopPreparedMessage] = []
    var automaticReplies: [String?] = []
    var failNextSend = false

    func requestAccess() {}

    func apps() -> [DesktopApp] {
        [codex, workBuddy].map { DesktopApp(name: $0.appName, bundleID: $0.bundleID, pid: $0.pid) }
    }

    func sessions(in app: DesktopApp) throws -> [DesktopSession] {
        [codex, workBuddy].filter { $0.bundleID == app.bundleID }
    }

    func prepare(message: String, in session: DesktopSession) throws -> DesktopPreparedMessage {
        DesktopPreparedMessage(session: session, text: message, baseline: [])
    }

    func send(_ message: DesktopPreparedMessage) throws {
        sent.append(message)
        if failNextSend {
            failNextSend = false
            throw StubError.uncertainSend
        }
    }

    func reply(for message: DesktopPreparedMessage) throws -> String? {
        guard let index = sent.firstIndex(where: { $0.id == message.id }), automaticReplies.indices.contains(index) else {
            return nil
        }
        return automaticReplies[index]
    }
}
