import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class WorkflowModel {
    var goal = ""
    var workerSession: DesktopSession?
    var reviewerSession: DesktopSession?
    private(set) var apps: [DesktopApp] = []
    private(set) var current: RunRecord?
    private(set) var history: [RunRecord] = []
    var notice: String?
    private(set) var hasAccess = false

    var isRunning: Bool {
        current?.status == .running || current?.status == .waiting
    }

    var manualStep: StepRecord? {
        guard current?.status == .waiting else { return nil }
        return current?.steps.first { $0.status == .waiting }
    }

    var canContinueWatching: Bool {
        manualStep != nil && pending != nil
    }

    var validationMessage: String? {
        if !storageReady { return "本机任务记录暂不可用。" }
        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写任务。" }
        guard let workerSession else { return "请选择处理软件。" }
        guard let reviewerSession else { return "请选择评审软件。" }
        if workerSession.bundleID == reviewerSession.bundleID { return "请选择两个不同的软件。" }
        return nil
    }

    var activityLabel: String? {
        guard let run = current, isRunning else { return nil }
        if run.status == .waiting { return "等待桌面交接" }
        guard let index = run.steps.firstIndex(where: { $0.status != .complete }) else { return nil }
        if run.steps[index].role == .reviewer { return "正在评审" }
        return index == 0 ? "正在处理任务" : "正在根据评审意见修订"
    }

    @ObservationIgnored private let transport: any DesktopTransporting
    @ObservationIgnored private let store: RunStore
    @ObservationIgnored private let watchDuration: Duration
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pending: DesktopPreparedMessage?
    private var storageReady = true

    convenience init() {
        self.init(transport: DesktopTransport(), store: .local)
    }

    init(
        transport: any DesktopTransporting,
        store: RunStore,
        watchDuration: Duration = .seconds(90),
        pollInterval: Duration = .seconds(1)
    ) {
        self.transport = transport
        self.store = store
        self.watchDuration = watchDuration
        self.pollInterval = pollInterval
        do {
            history = try store.load()
            if history.contains(where: { $0.status == .running || $0.status == .waiting }) {
                for index in history.indices where history[index].status == .running || history[index].status == .waiting {
                    history[index].status = .stopped
                    for stepIndex in history[index].steps.indices {
                        let status = history[index].steps[stepIndex].status
                        if status == .running || status == .waiting || status == .idle {
                            history[index].steps[stepIndex].status = .stopped
                            history[index].steps[stepIndex].note = "协作台已重启。请在原客户端核对执行状态。"
                        }
                    }
                }
                try store.save(history)
            }
        } catch {
            storageReady = false
            notice = "无法读取或恢复本机任务记录。\(error.localizedDescription)"
        }
        refreshApps()
    }

    func refreshApps() {
        hasAccess = transport.hasAccess
        apps = transport.apps()
    }

    func requestAccess() {
        transport.requestAccess()
        refreshApps()
    }

    func sessions(in app: DesktopApp) -> [DesktopSession] {
        do {
            return try transport.sessions(in: app)
        } catch {
            notice = error.localizedDescription
            return []
        }
    }

    func start() {
        guard !isRunning else { return }
        refreshApps()
        if let validationMessage {
            notice = validationMessage
            return
        }
        guard let workerSession, let reviewerSession else { return }
        guard hasAccess || (workerSession.isManual && reviewerSession.isManual) else {
            notice = "请先在系统设置中授权辅助功能，然后刷新。"
            return
        }

        var records: [StepRecord] = []
        let assignments: [(AgentRole, DesktopSession)] = [(.worker, workerSession), (.reviewer, reviewerSession)]
        for (role, session) in assignments {
            guard let app = apps.first(where: { $0.bundleID == session.bundleID && $0.pid == session.pid }) else {
                notice = "\(role.rawValue)软件已关闭或重启，请重新选择。"
                return
            }
            if !session.isManual {
                do {
                    guard try transport.sessions(in: app).contains(session) else {
                        notice = "无法核对\(role.rawValue)会话，请在原软件打开它，再重新选择。"
                        return
                    }
                } catch {
                    notice = "无法确认\(role.rawValue)会话。\(error.localizedDescription)"
                    return
                }
            }
            records.append(StepRecord(session: session, role: role))
        }

        notice = nil
        current = RunRecord(goal: goal, steps: records)
        guard checkpoint() else {
            failForStorage()
            return
        }
        startWorker(at: 0)
    }

    func stop() {
        guard isRunning, var run = current else { return }
        worker?.cancel()
        worker = nil
        pending = nil
        for index in run.steps.indices where run.steps[index].status != .complete {
            run.steps[index].status = .stopped
            run.steps[index].finishedAt = Date()
            if run.steps[index].message != nil {
                run.steps[index].note = "交接已停止。若原客户端仍在运行，请在其窗口查看或停止。"
            }
        }
        run.status = .stopped
        current = run
        _ = checkpoint()
    }

    func continueWatching() {
        guard canContinueWatching, let pending, let index = current?.steps.firstIndex(where: { $0.status == .waiting }) else { return }
        current?.status = .running
        current?.steps[index].status = .running
        current?.steps[index].note = nil
        guard checkpoint() else {
            failForStorage()
            return
        }
        startWorker(at: index, watching: pending)
    }

    func submitManualReply(_ text: String) {
        guard manualStep != nil, let index = current?.steps.firstIndex(where: { $0.status == .waiting }) else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = "请粘贴本轮完整回复。"
            return
        }
        notice = nil
        guard acceptReply(at: index, reply: text) else { return }
        startWorker(at: index + 1)
    }

    func deleteHistory(_ id: UUID) {
        guard storageReady, !(isRunning && current?.id == id) else { return }
        let updated = history.filter { $0.id != id }
        do {
            try store.save(updated)
            history = updated
            if current?.id == id { current = nil }
        } catch {
            notice = "无法删除记录。\(error.localizedDescription)"
        }
    }

    func open(_ session: DesktopSession) {
        guard let app = NSRunningApplication(processIdentifier: session.pid), app.bundleIdentifier == session.bundleID else {
            notice = "目标客户端已关闭或重启。请重新打开后选择会话。"
            return
        }
        if !app.activate() { notice = "请手动切换到\(session.appName)。" }
    }

    private func startWorker(at index: Int, watching: DesktopPreparedMessage? = nil) {
        guard let runID = current?.id else { return }
        worker = Task { [weak self] in
            await self?.run(from: index, runID: runID, watching: watching)
        }
    }

    private func run(from startIndex: Int, runID: UUID, watching: DesktopPreparedMessage?) async {
        var index = startIndex
        while active(runID), let run = current, run.steps.indices.contains(index) {
            var prepared = index == startIndex ? watching : nil
            if prepared == nil {
                let message = run.message(for: index)
                current?.steps[index].message = message
                current?.steps[index].status = .running
                current?.steps[index].startedAt = Date()
                guard checkpoint() else {
                    failForStorage()
                    return
                }
                if run.steps[index].session.isManual {
                    pause(index, note: "请在所选软件发送交接消息，再粘贴它的完整回复。")
                    return
                }
                do {
                    prepared = try transport.prepare(message: message, in: run.steps[index].session)
                } catch {
                    pause(index, note: "尚未自动发送。\(error.localizedDescription)")
                    return
                }
                guard let prepared else { return }
                do {
                    try transport.send(prepared)
                    pending = prepared
                } catch {
                    pause(index, note: "无法确认是否已发送，请先在原窗口核对消息和草稿。\(error.localizedDescription)")
                    return
                }
            }

            guard let prepared else { return }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: watchDuration)
            repeat {
                guard active(runID) else { return }
                do {
                    if let reply = try transport.reply(for: prepared) {
                        guard acceptReply(at: index, reply: reply) else { return }
                        break
                    }
                    try await Task.sleep(for: pollInterval)
                } catch is CancellationError {
                    return
                } catch {
                    pause(index, note: "无法自动读取完整回复。\(error.localizedDescription)")
                    return
                }
            } while clock.now < deadline

            guard active(runID) else { return }
            if current?.steps[index].status != .complete {
                pause(index, note: "暂未确认回复已结束。可以继续等待，或从原会话复制本轮完整回复。")
                return
            }
            index += 1
        }
        guard active(runID) else { return }
        worker = nil
        current?.status = .failed
        current?.failureReason = "流程结束时尚未取得评审批准。"
        if !checkpoint() { failForStorage() }
    }

    private func active(_ runID: UUID) -> Bool {
        !Task.isCancelled && current?.id == runID && current?.status == .running
    }

    private func pause(_ index: Int, note: String) {
        worker = nil
        current?.steps[index].status = .waiting
        current?.steps[index].note = note
        current?.status = .waiting
        if !checkpoint() { failForStorage() }
    }

    private func acceptReply(at index: Int, reply: String) -> Bool {
        guard var run = current else { return false }
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pause(index, note: "回复为空。请提供本轮完整回复。")
            return false
        }
        pending = nil
        run.steps[index].reply = reply
        run.steps[index].status = .complete
        run.steps[index].note = nil
        run.steps[index].finishedAt = Date()
        run.status = .running

        if run.steps[index].role == .reviewer {
            switch ReviewVerdict.parse(reply) {
            case .approve:
                run.finalResult = run.steps[index - 1].reply
                run.status = .complete
            case .revise where index / 2 < RunRecord.maximumRevisions:
                run.steps.append(StepRecord(session: run.steps[0].session, role: .worker))
                run.steps.append(StepRecord(session: run.steps[1].session, role: .reviewer))
            case .revise:
                run.status = .failed
                run.failureReason = "已自动返修两次，评审仍未通过。"
            case nil:
                run.steps[index].status = .failed
                run.status = .failed
                run.failureReason = "评审没有返回可确认的结论。请重新发布任务再试。"
            }
        }
        current = run
        guard checkpoint() else {
            failForStorage()
            return false
        }
        if run.status != .running { worker = nil }
        return run.status == .running
    }

    private func checkpoint() -> Bool {
        guard let current else { return true }
        var updated = history
        if let index = updated.firstIndex(where: { $0.id == current.id }) {
            updated[index] = current
        } else {
            updated.insert(current, at: 0)
        }
        history = updated
        do {
            try store.save(updated)
            return true
        } catch {
            storageReady = false
            notice = "无法保存本机任务记录。\(error.localizedDescription)"
            return false
        }
    }

    private func failForStorage() {
        worker = nil
        pending = nil
        current?.status = .failed
        current?.finalResult = nil
        current?.failureReason = "无法保存本机任务记录。"
        if let index = current?.steps.firstIndex(where: { $0.status == .running || $0.status == .waiting }) {
            current?.steps[index].status = .failed
            current?.steps[index].note = notice
        }
        if let current, let index = history.firstIndex(where: { $0.id == current.id }) { history[index] = current }
    }
}

struct RunStore {
    let file: URL

    static var local: RunStore {
        let directory = URL.applicationSupportDirectory.appending(path: "AgentInteraction", directoryHint: .isDirectory)
        return RunStore(file: directory.appending(path: "runs.json"))
    }

    func load() throws -> [RunRecord] {
        do {
            let data = try Data(contentsOf: file)
            return try JSONDecoder().decode([RunRecord].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    func save(_ records: [RunRecord]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
    }
}
