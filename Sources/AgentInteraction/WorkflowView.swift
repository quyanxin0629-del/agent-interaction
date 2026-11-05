import AppKit
import SwiftUI

// The command-line SDK includes the State wrapper but not the newer State macro plugin.
private typealias ViewState<Value> = State<Value>

@MainActor
struct WorkflowView: View {
    private enum Role: String, Identifiable {
        case worker = "处理"
        case reviewer = "评审"

        var id: Self { self }
    }

    @Bindable var model: WorkflowModel
    @ViewState private var choosingRole: Role?
    @ViewState private var selectedAppID: String?
    @ViewState private var selectedSession: DesktopSession?
    @ViewState private var availableSessions: [DesktopSession] = []
    @ViewState private var usesManualSession = false
    @ViewState private var manualSessionName = ""
    @ViewState private var manualReply = ""
    @ViewState private var copiedMessage = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("多 Agent 协作台")
                        .font(.system(size: 28, weight: .semibold))
                    Text("提交一项任务，由你选择的软件处理和评审。")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("任务").font(.headline)
                    textBox($model.goal, label: "任务", placeholder: "描述你想完成的任务和交付要求", height: 128)
                }
                .disabled(model.isRunning)

                HStack(spacing: 12) {
                    roleButton(.worker, session: model.workerSession)
                    roleButton(.reviewer, session: model.reviewerSession)
                }
                .disabled(model.isRunning)

                HStack(alignment: .firstTextBaseline) {
                    if let notice = model.notice {
                        Text(notice)
                            .foregroundStyle(.orange)
                            .font(.callout)
                    } else if !model.isRunning, let validation = model.validationMessage {
                        Text(validation)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    Spacer(minLength: 14)
                    Button("发布任务", systemImage: "paperplane.fill") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning || model.validationMessage != nil)
                }

                if model.isRunning || model.current != nil {
                    Divider()
                    execution
                }

                if !pastResults.isEmpty {
                    history
                }
            }
            .padding(28)
            .frame(maxWidth: 730)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { model.refreshApps() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshApps()
        }
        .onChange(of: model.manualStep?.id) {
            manualReply = ""
            copiedMessage = false
        }
        .sheet(item: $choosingRole) { role in
            roleSheet(role)
        }
    }

    private func roleButton(_ role: Role, session: DesktopSession?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(role.rawValue).font(.headline)
            Button {
                beginChoosing(role, session: session)
            } label: {
                HStack(spacing: 7) {
                    Text(session?.appName ?? "选择软件")
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("\(role.rawValue)软件")
            .accessibilityValue(session?.appName ?? "未选择")
            if let session {
                Text(sessionTitle(session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func beginChoosing(_ role: Role, session: DesktopSession?) {
        model.refreshApps()
        model.notice = nil
        selectedAppID = session?.bundleID
        selectedSession = nil
        availableSessions = []
        usesManualSession = session?.isManual == true
        manualSessionName = usesManualSession ? session?.conversationTitle ?? "" : ""
        if let app = selectedApp {
            if !usesManualSession {
                loadSessions(for: app, preferred: session)
            }
        } else if let session {
            selectedAppID = nil
            model.notice = "请打开\(session.appName)，再选择目标会话。"
        }
        choosingRole = role
    }

    private var selectedApp: DesktopApp? {
        model.apps.first { $0.bundleID == selectedAppID }
    }

    private func roleSheet(_ role: Role) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择\(role.rawValue)软件")
                .font(.title2.weight(.semibold))
            HStack {
                Picker("软件", selection: $selectedAppID) {
                    Text("请选择").tag(String?.none)
                    ForEach(model.apps) { app in
                        Text(app.name).tag(Optional(app.bundleID))
                    }
                }
                Button("刷新", systemImage: "arrow.clockwise") {
                    model.refreshApps()
                    if let app = selectedApp, !usesManualSession {
                        loadSessions(for: app, preferred: selectedSession)
                    }
                }
                .labelStyle(.iconOnly)
                .help("刷新已打开的软件和会话")
            }
            .onChange(of: selectedAppID) {
                selectedSession = nil
                availableSessions = []
                usesManualSession = false
                manualSessionName = ""
                model.notice = nil
                if let app = selectedApp { loadSessions(for: app) }
            }

            if model.apps.isEmpty {
                Text("先打开你要使用的桌面软件，再刷新列表。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let app = selectedApp {
                sessionOptions(app)
            }

            HStack {
                Spacer()
                Button("取消") { choosingRole = nil }
                    .keyboardShortcut(.cancelAction)
                Button("选定软件") {
                    guard let session = chosenSession else { return }
                    switch role {
                    case .worker: model.workerSession = session
                    case .reviewer: model.reviewerSession = session
                    }
                    model.notice = nil
                    choosingRole = nil
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosenSession == nil)
            }
        }
        .padding(24)
        .frame(width: 450)
    }

    private func sessionOptions(_ app: DesktopApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if usesManualSession {
                TextField("目标会话名称", text: $manualSessionName)
                Text("执行时在 \(app.name) 里发送消息，再把回复贴回协作台。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.hasAccess {
                    Button("尝试自动识别会话") {
                        usesManualSession = false
                        loadSessions(for: app)
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                if availableSessions.count > 1 {
                    Picker("会话", selection: $selectedSession) {
                        Text("请选择").tag(DesktopSession?.none)
                        ForEach(availableSessions) { session in
                            Text(sessionTitle(session)).tag(Optional(session))
                        }
                    }
                } else if let session = selectedSession {
                    Label(sessionTitle(session), systemImage: "bubble.left")
                        .font(.callout)
                } else {
                    Text(model.hasAccess
                         ? "请在原软件打开目标会话，再点击刷新。"
                         : "自动识别会话需要 macOS 辅助功能授权。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if !model.hasAccess {
                        Button("打开授权设置") { model.requestAccess() }
                            .buttonStyle(.borderless)
                    }
                    Button("手动绑定会话") { usesManualSession = true }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func loadSessions(for app: DesktopApp, preferred: DesktopSession? = nil) {
        let candidates = model.hasAccess ? model.sessions(in: app) : []
        let groups = Dictionary(grouping: candidates, by: sessionTitle)
        availableSessions = candidates.filter { groups[sessionTitle($0)]?.count == 1 }
        selectedSession = availableSessions.first { $0.id == preferred?.id }
        if availableSessions.count == 1 { selectedSession = availableSessions.first }
    }

    private var chosenSession: DesktopSession? {
        guard let app = selectedApp else { return nil }
        if usesManualSession {
            let title = manualSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return DesktopSession(
                appName: app.name,
                bundleID: app.bundleID,
                pid: app.pid,
                windowTitle: "",
                conversationTitle: title,
                isManual: true
            )
        }
        guard selectedSession?.pid == app.pid else { return nil }
        return selectedSession
    }

    private var execution: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isRunning {
                HStack {
                    if model.manualStep == nil {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.activityLabel ?? "正在处理任务")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("停止", role: .destructive) { model.stop() }
                }
                if let step = model.manualStep { manualAssist(step) }
            } else if let run = model.current {
                if run.status == .complete, let result = run.finalResult {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("最终结果", systemImage: "checkmark.circle")
                                .font(.headline)
                            Spacer()
                            Button("复制", systemImage: "doc.on.doc") { _ = copy(result) }
                        }
                        resultText(result)
                    }
                } else if let reason = run.failureReason {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                } else if run.status == .stopped {
                    Text("协作已停止。仍在执行的任务可到原软件查看。")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func manualAssist(_ step: StepRecord) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("在 \(step.session.appName) 完成交接")
                .font(.headline)
            Text(step.session.isManual
                 ? "打开「\(step.session.conversationTitle)」，发送复制的消息，再粘贴完整回复。"
                 : "先在原会话核对发送状态。需要发送时可复制待发消息，收到完整回复后再粘贴。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let note = step.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if let message = step.message {
                    Button(copiedMessage ? "已复制" : "复制待发消息", systemImage: "doc.on.doc") {
                        copiedMessage = copy(message)
                    }
                }
                Button("打开原软件", systemImage: "arrow.up.right.square") { model.open(step.session) }
            }
            textBox($manualReply, label: "完整回复", placeholder: "粘贴本轮完整回复", height: 72)
            HStack {
                if model.canContinueWatching {
                    Button("重新检查回复") { model.continueWatching() }
                }
                Spacer()
                Button("提交回复并继续") { model.submitManualReply(manualReply) }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(13)
        .background(.quaternary.opacity(0.48), in: RoundedRectangle(cornerRadius: 9))
    }

    private var pastResults: [RunRecord] {
        model.history.filter { $0.id != model.current?.id && $0.status == .complete && $0.finalResult != nil }
    }

    private var history: some View {
        DisclosureGroup("历史结果") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(pastResults) { run in
                    if let result = run.finalResult {
                        DisclosureGroup {
                            resultText(result)
                                .padding(.vertical, 5)
                        } label: {
                            Text(run.goal)
                                .lineLimit(1)
                                .help(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        .contextMenu {
                            Button("删除记录", role: .destructive) { model.deleteHistory(run.id) }
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func resultText(_ result: String) -> some View {
        Text(result)
            .font(.body)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionTitle(_ session: DesktopSession) -> String {
        if session.isManual { return "\(session.conversationTitle) · 手动交接" }
        if session.conversationTitle.isEmpty { return session.windowTitle }
        if session.windowTitle.isEmpty || session.windowTitle == session.conversationTitle {
            return session.conversationTitle
        }
        return "\(session.conversationTitle) · \(session.windowTitle)"
    }

    private func textBox(
        _ text: Binding<String>,
        label: String,
        placeholder: String,
        height: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(5)
                .accessibilityLabel(label)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.secondary)
                    .padding(.top, 9)
                    .padding(.leading, 10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: height)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}
