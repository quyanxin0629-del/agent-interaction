import AppKit
import ApplicationServices
import Foundation

@MainActor
final class DesktopTransport: DesktopTransporting {
    private struct Binding {
        var window: AXUIElement
        var windowTitle: String
        var conversationKey: String
    }

    private struct Node {
        var element: AXUIElement
        var role: String
        var title: String
        var description: String
        var identifier: String
        var children: [Node]

        var labels: [String] {
            [title, description, identifier].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        }

        func flattened() -> [Node] {
            [self] + children.flatMap { $0.flattened() }
        }
    }

    private enum Author: String {
        case user, assistant
    }

    private struct Turn {
        var author: Author
        var text: String
        var complete: Bool

        var signature: String { author.rawValue + ":" + text }
    }

    private enum TransportError: LocalizedError {
        case permission, locked, appClosed, windowChanged, conversationChanged
        case unreadableConversation, dialog, busy, composerUnavailable
        case existingDraft, changedHistory, writeFailed, sendUnavailable, sendUncertain

        var errorDescription: String? {
            switch self {
            case .permission: "请在 macOS 系统设置中为协作台授予辅助功能权限。"
            case .locked: "当前桌面会话不可用，请解锁 Mac 后继续。"
            case .appClosed: "目标软件已关闭或重启，请重新选择会话。"
            case .windowChanged: "原窗口不可用或窗口标题已变更，请核对目标会话。"
            case .conversationChanged: "当前会话与选定会话不同，请切回原会话。"
            case .unreadableConversation: "当前客户端没有提供可核对的会话标识，请在原窗口手动确认。"
            case .dialog: "目标窗口中有待处理的弹窗，请在原客户端处理。"
            case .busy: "目标会话仍在生成，请等待当前回复结束。"
            case .composerUnavailable: "未找到唯一且可读写的对话输入框，请在原客户端确认。"
            case .existingDraft: "目标输入框中已有内容，请在原客户端处理草稿。"
            case .changedHistory: "确认后目标会话发生变化，请在原客户端检查。"
            case .writeFailed: "未能核对写入的草稿，请先检查原客户端输入框。"
            case .sendUnavailable: "未能核对发送按钮，请检查原客户端。已写入的草稿可能仍在输入框内。"
            case .sendUncertain: "无法确认发送操作是否生效，请在原客户端核对后继续。"
            }
        }
    }

    private var bindings: [UUID: Binding] = [:]

    var hasAccess: Bool { AXIsProcessTrusted() }

    func requestAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func apps() -> [DesktopApp] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let applications: [DesktopApp] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != currentPID,
                  let bundleID = app.bundleIdentifier,
                  let name = app.localizedName,
                  isAgent(bundleID: bundleID, name: name) else { return nil }
            let label = bundleID == "com.openai.codex" || bundleID == "com.openai.chat"
                ? "Codex（ChatGPT）" : name
            return DesktopApp(name: label, bundleID: bundleID, pid: app.processIdentifier)
        }
        return Dictionary(grouping: applications, by: \.bundleID).values
            .compactMap { $0.count == 1 ? $0.first : nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func sessions(in app: DesktopApp) throws -> [DesktopSession] {
        let application = try applicationElement(pid: app.pid, bundleID: app.bundleID)
        let openWindows = windows(in: application)
        return openWindows.compactMap { window in
            guard let title = text(window, "AXTitle"), !title.isEmpty,
                  let tree = inspect(window),
                  let identity = conversation(in: tree) else { return nil }
            let existingID = bindings.first {
                CFEqual($0.value.window, window)
                    && $0.value.windowTitle == title
                    && $0.value.conversationKey == identity.key
            }?.key
            let session = DesktopSession(
                id: existingID ?? UUID(),
                appName: app.name,
                bundleID: app.bundleID,
                pid: app.pid,
                windowTitle: title,
                conversationTitle: identity.title
            )
            bindings[session.id] = Binding(window: window, windowTitle: title, conversationKey: identity.key)
            return session
        }
    }

    func prepare(message: String, in session: DesktopSession) throws -> DesktopPreparedMessage {
        let tree = try verifiedTree(for: session)
        try ensureReady(tree)
        let composer = try composer(in: tree)
        guard let currentValue = text(composer.element, "AXValue") else { throw TransportError.composerUnavailable }
        guard currentValue.isEmpty else { throw TransportError.existingDraft }
        guard sendButton(for: composer, in: tree) != nil else { throw TransportError.sendUnavailable }
        return DesktopPreparedMessage(session: session, text: message, baseline: turns(in: tree).map(\.signature))
    }

    func send(_ message: DesktopPreparedMessage) throws {
        let tree = try verifiedTree(for: message.session)
        try ensureReady(tree)
        guard turns(in: tree).map(\.signature) == message.baseline else { throw TransportError.changedHistory }
        let composer = try composer(in: tree)
        guard let currentValue = text(composer.element, "AXValue") else { throw TransportError.composerUnavailable }
        guard currentValue.isEmpty else { throw TransportError.existingDraft }
        // Verify that a single semantically identified Send action is paired with this composer before drafting.
        guard sendButton(for: composer, in: tree) != nil else { throw TransportError.sendUnavailable }
        let result = AXUIElementSetAttributeValue(composer.element, "AXValue" as CFString, message.text as CFString)
        guard result == .success else { throw TransportError.writeFailed }

        let currentTree = try verifiedTree(for: message.session)
        try ensureReady(currentTree)
        guard turns(in: currentTree).map(\.signature) == message.baseline else { throw TransportError.changedHistory }
        let currentComposer = try self.composer(in: currentTree)
        guard CFEqual(currentComposer.element, composer.element),
              text(currentComposer.element, "AXValue") == message.text else { throw TransportError.writeFailed }
        guard let button = sendButton(for: currentComposer, in: currentTree),
              attribute(button.element, "AXEnabled") as? Bool == true else { throw TransportError.sendUnavailable }
        guard AXUIElementPerformAction(button.element, "AXPress" as CFString) == .success else {
            throw TransportError.sendUncertain
        }
    }

    func reply(for message: DesktopPreparedMessage) throws -> String? {
        let tree = try verifiedTree(for: message.session)
        try ensureNoDialog(tree)
        guard !isGenerating(tree) else { return nil }

        let currentTurns = turns(in: tree)
        let baseline = currentTurns.prefix(message.baseline.count).map(\.signature)
        guard baseline == message.baseline else { throw TransportError.changedHistory }
        let newTurns = currentTurns.dropFirst(message.baseline.count)
        guard let sent = newTurns.first else { return nil }
        guard sent.author == .user,
              normalized(sent.text) == normalized(message.text) else { throw TransportError.changedHistory }
        let replies = newTurns.dropFirst()
        guard !replies.contains(where: { $0.author == .user }) else { throw TransportError.changedHistory }
        guard replies.count == 1,
              let reply = replies.first,
              reply.author == .assistant,
              reply.complete,
              !reply.text.isEmpty else { return nil }
        return reply.text
    }

    private func isAgent(bundleID: String, name: String) -> Bool {
        let identity = bundleID.lowercased()
        let appName = name.lowercased()
        return identity.hasPrefix("com.openai.codex")
            || identity == "com.openai.chat"
            || identity == "com.google.geminimacos"
            || identity == "com.anthropic.claudefordesktop"
            || appName == "antigravity"
            || appName == "workbuddy"
            || appName == "腾讯 workbuddy"
    }

    private func applicationElement(pid: Int32, bundleID: String) throws -> AXUIElement {
        guard hasAccess else { throw TransportError.permission }
        let matching = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
        guard let running = NSRunningApplication(processIdentifier: pid),
              !running.isTerminated,
              matching.count == 1, matching.first?.processIdentifier == pid,
              running.bundleIdentifier == bundleID,
              isAgent(bundleID: bundleID, name: running.localizedName ?? "") else { throw TransportError.appClosed }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.4)
        return application
    }

    private func windows(in application: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        let candidates = elements(application, "AXWindows")
            + ["AXFocusedWindow", "AXMainWindow"].compactMap { element(attribute(application, $0)) }
            + elements(application, "AXChildren").filter { text($0, "AXRole") == "AXWindow" }
        for candidate in candidates where !result.contains(where: { CFEqual($0, candidate) }) {
            result.append(candidate)
        }
        return result
    }

    private func verifiedTree(for session: DesktopSession) throws -> Node {
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            guard frontmost.bundleIdentifier != "com.apple.loginwindow" else { throw TransportError.locked }
        } else {
            throw TransportError.locked
        }
        let application = try applicationElement(pid: session.pid, bundleID: session.bundleID)
        guard let binding = bindings[session.id],
              windows(in: application).contains(where: { CFEqual($0, binding.window) }),
              text(binding.window, "AXTitle") == binding.windowTitle,
              binding.windowTitle == session.windowTitle else { throw TransportError.windowChanged }
        guard let tree = inspect(binding.window) else { throw TransportError.unreadableConversation }
        guard let current = conversation(in: tree),
              current.key == binding.conversationKey,
              current.title == session.conversationTitle else { throw TransportError.conversationChanged }
        return tree
    }

    private func conversation(in tree: Node) -> (key: String, title: String)? {
        func documents(in node: Node) -> [Node] {
            if node.role == "AXWebArea" { return [node] }
            return node.children.flatMap(documents(in:))
        }
        let documentNodes = documents(in: tree)
        guard documentNodes.count == 1,
              let document = documentNodes.first,
              let url = attribute(document.element, "AXURL") as? URL else { return nil }
        let locations = [
            url.pathComponents,
            url.fragment?.split(separator: "/").map(String.init) ?? []
        ]
        let markers: Set<String> = ["chat", "chats", "c", "conversation", "conversations", "thread", "threads", "app"]
        let keys = Set(locations.compactMap { parts -> String? in
            guard let marker = parts.dropLast().last, markers.contains(marker),
                  let identifier = parts.last?.split(separator: "?").first,
                  (8...128).contains(identifier.count),
                  identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  let scheme = url.scheme else { return nil }
            return scheme + "://" + (url.host ?? "") + "/" + marker + "/" + identifier
        })
        guard keys.count == 1, let key = keys.first else { return nil }

        let titleIdentifiers: Set<String> = ["conversation-title", "thread-title", "chat-title", "active-conversation-title"]
        let titleNodes = document.flattened().filter { titleIdentifiers.contains($0.identifier.lowercased()) }
        guard titleNodes.count <= 1 else { return nil }
        let titleNode = titleNodes.first ?? document
        let title = [titleNode.title, titleNode.description, text(titleNode.element, "AXValue") ?? "", tree.title]
            .first { !$0.isEmpty } ?? ""
        guard !title.isEmpty else { return nil }
        return (key, title)
    }

    private func ensureReady(_ tree: Node) throws {
        try ensureNoDialog(tree)
        if isGenerating(tree) { throw TransportError.busy }
    }

    private func ensureNoDialog(_ tree: Node) throws {
        let modal = tree.flattened().contains {
            $0.role == "AXSheet" || $0.role == "AXDialog" || $0.role == "AXAlert"
                || ($0.role == "AXWindow" && text($0.element, "AXSubrole") == "AXDialog")
        }
        if modal { throw TransportError.dialog }
    }

    private func isGenerating(_ tree: Node) -> Bool {
        let stopLabels: Set<String> = ["stop generating", "stop response", "stop streaming", "停止生成", "停止回复", "停止生成回复"]
        return tree.flattened().contains { $0.role == "AXButton" && $0.labels.contains(where: stopLabels.contains) }
    }

    private func composer(in tree: Node) throws -> Node {
        let labels: Set<String> = [
            "message", "message input", "chat input", "chat composer", "prompt", "prompt input",
            "输入消息", "输入提示词", "消息输入框", "发消息", "composer-input", "prompt-textarea"
        ]
        let candidates = tree.flattened().filter { node in
            guard ["AXTextArea", "AXTextField"].contains(node.role) else { return false }
            let placeholder = text(node.element, "AXPlaceholderValue")?.lowercased() ?? ""
            guard node.labels.contains(where: labels.contains) || labels.contains(placeholder) else { return false }
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(node.element, "AXValue" as CFString, &settable) == .success
                && settable.boolValue
        }
        guard candidates.count == 1, let candidate = candidates.first else { throw TransportError.composerUnavailable }
        return candidate
    }

    private func sendButton(for composer: Node, in tree: Node) -> Node? {
        let labels: Set<String> = ["send", "send message", "send prompt", "发送", "发送消息", "composer-send-button"]
        func ancestors(in node: Node) -> [Node]? {
            if CFEqual(node.element, composer.element) { return [] }
            for child in node.children {
                if let path = ancestors(in: child) { return path + [node] }
            }
            return nil
        }
        for group in (ancestors(in: tree) ?? []).prefix(4) where ["AXGroup", "AXForm"].contains(group.role) {
            let nodes = group.flattened()
            let buttons = nodes.filter { $0.role == "AXButton" && $0.labels.contains(where: labels.contains) }
            if buttons.isEmpty { continue }
            guard buttons.count == 1, let button = buttons.first else { return nil }
            let otherEditors = nodes.contains {
                ["AXTextArea", "AXTextField"].contains($0.role)
                    && !CFEqual($0.element, composer.element)
                    && (attribute($0.element, "AXEditable") as? Bool) == true
            }
            return otherEditors ? nil : button
        }
        return nil
    }

    private func turns(in tree: Node) -> [Turn] {
        let userMarkers: Set<String> = ["user-message", "message-user", "user message", "your message", "用户消息"]
        let assistantMarkers: Set<String> = [
            "assistant-message", "message-assistant", "assistant message", "assistant response",
            "助手消息", "助手回复", "assistant-message-complete"
        ]
        let completionMarkers: Set<String> = ["assistant-message-complete", "response-complete", "reply complete", "回复已完成"]

        func collect(_ node: Node) -> [Turn] {
            let isContainer = ["AXGroup", "AXArticle", "AXSection", "AXListItem"].contains(node.role)
            let role: Author?
            if isContainer && node.labels.contains(where: userMarkers.contains) {
                role = .user
            } else if isContainer && node.labels.contains(where: assistantMarkers.contains) {
                role = .assistant
            } else {
                role = nil
            }
            guard let role else { return node.children.flatMap(collect) }
            let content = node.flattened().filter { $0.identifier == "message-content" }
            guard content.count == 1, let contentNode = content.first,
                  let value = text(contentNode.element, "AXValue"), !value.isEmpty else { return [] }
            let complete = node.labels.contains(where: completionMarkers.contains)
                || node.children.contains { $0.labels.contains(where: completionMarkers.contains) }
            return [Turn(author: role, text: value, complete: complete)]
        }
        return collect(tree)
    }

    private func inspect(_ element: AXUIElement) -> Node? {
        var remaining = 1_200
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        func visit(_ current: AXUIElement, depth: Int) -> Node? {
            guard remaining > 0, depth <= 30, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            remaining -= 1
            let role = text(current, "AXRole") ?? ""
            let children = elements(current, "AXChildren")
            var inspected: [Node] = []
            for child in children {
                guard let node = visit(child, depth: depth + 1) else { return nil }
                inspected.append(node)
            }
            return Node(
                element: current,
                role: role,
                title: text(current, "AXTitle") ?? "",
                description: text(current, "AXDescription") ?? "",
                identifier: text(current, "AXIdentifier") ?? "",
                children: inspected
            )
        }
        return visit(element, depth: 0)
    }

    private func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func text(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        (attribute(element, name) as? [AnyObject] ?? []).compactMap(self.element)
    }

    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
