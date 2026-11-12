import ACP
import ACPModel
import Foundation
import Logging
import SpotCore

/// The dsh runtime bundled with the app: Node, dsh trimmed to what it loads, and Spot Chat's profile.
public struct CommandRuntime: Sendable, Equatable {
    public let folder: URL

    public init?(folder: URL) {
        guard FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("dsh").path) else { return nil }
        self.folder = folder
    }

    /// The runtime in the app's resources, if this build has one.
    public static func bundled(in bundle: Bundle = .main) -> CommandRuntime? {
        bundle.resourceURL.flatMap { CommandRuntime(folder: $0.appendingPathComponent("Agent")) }
    }

    var launcher: URL { folder.appendingPathComponent("dsh") }
    var profile: URL { folder.appendingPathComponent("profile") }

    /// The dsh version the runtime was built with, from the VERSION file the build writes beside it.
    public var version: String {
        let file = folder.appendingPathComponent("VERSION")
        do {
            return try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "unknown"
        }
    }
}

/// Where commands run: in a dsh Spot Chat starts from its bundled runtime, or in the DeepSeek Harness the
/// user runs, through Spot Chat's plugin there, where its sessions can be watched.
public enum CommandConnection: Sendable, Equatable {
    case bundled(CommandRuntime)
    case bridge(DshBridge, token: String)

    public var isHarness: Bool {
        if case .bridge = self { return true }
        return false
    }
}

/// What dsh is started with.
public struct CommandAgentOptions: Sendable {
    /// The DeepSeek API key.
    public var apiKey: String
    /// Another address for DeepSeek's API, for tests.
    public var baseURL: String?
    /// dsh's own folder for its profile and sessions.
    public var home: URL
    /// The DeepSeek model to use, when dsh offers it.
    public var model: String?
    /// dsh's reasoning effort: off, low, high or max.
    public var effort: String?
    /// Another address for DeepSeek's Search and Fetch API, for tests.
    public var webToolsURL: String?
    /// Whether dsh may search the web and read pages.
    public var searchesTheWeb = true

    public init(
        apiKey: String, baseURL: String? = nil, home: URL, model: String? = nil, effort: String? = nil,
        webToolsURL: String? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.webToolsURL = webToolsURL
        self.home = home
        self.model = model
        self.effort = effort
    }
}

/// What happens during a turn, as the reply view shows it.
public enum CommandEvent: Sendable {
    case text(String)
    case thought(String)
    /// A tool call started or changed.
    case run(CommandRun)
}

/// The user's answer to running a command outside the folder.
public enum CommandApproval: Sendable {
    case allow
    case deny
    /// The reply was stopped while dsh waited.
    case cancel
}

public enum CommandAgentError: LocalizedError {
    case exited(String)
    case noSession
    case folderMissing(String)

    public var errorDescription: String? {
        switch self {
        case let .exited(detail):
            return detail.isEmpty ? String(localized: "Commands stopped unexpectedly.") : String(localized: "Commands stopped unexpectedly: \(detail)")
        case .noSession:
            return String(localized: "Couldn't start running commands.")
        case let .folderMissing(name):
            return String(localized: "The folder “\(name)” can’t be found.")
        }
    }
}

/// One connection to dsh speaking ACP, holding one session in one folder: a dsh process of its own, or a
/// connection to the user's DeepSeek Harness. dsh runs each command in its sandbox, which lets it write only
/// inside the folder; when a command needs more, dsh asks and `approver` answers.
public actor CommandAgent {
    public typealias Approver = @Sendable (CommandRun) async -> CommandApproval

    public let folder: URL
    public nonisolated let connection: CommandConnection
    private var options: CommandAgentOptions
    private let approver: Approver

    private var process: Process?
    /// Set while a connection to the user's DeepSeek Harness is open; a closing that isn't this one's is old.
    private var bridgeConnection: UUID?
    private var rpc: ACPProtocol?
    private var stderrTail = ""
    public private(set) var sessionID: String?
    private var configOptions: [SessionConfigOption] = []
    private var appliedModel: String?
    private var appliedEffort: String?

    private var onEvent: (@Sendable (CommandEvent) -> Void)?
    private var runs: [String: CommandRun] = [:]
    /// Set when the user stops the turn: what fails from then on was stopped.
    private var isCancelling = false
    /// Set when a setting dsh reads at launch has changed.
    private var needsRestart = false

    /// dsh's session updates in the order it sent them, and marks for catching up with them.
    private enum Inbound: Sendable {
        case update(SessionUpdate)
        case caughtUp(CheckedContinuation<Void, Never>)
    }
    private let inbound: AsyncStream<Inbound>
    private let inboundSink: AsyncStream<Inbound>.Continuation
    private var inboundReader: Task<Void, Never>?

    public init(connection: CommandConnection, options: CommandAgentOptions, folder: URL, approver: @escaping Approver) {
        self.connection = connection
        self.options = options
        self.folder = folder
        self.approver = approver
        (inbound, inboundSink) = AsyncStream.makeStream()
    }

    /// Returns once every update read so far has been handled.
    private func catchUp() async {
        await withCheckedContinuation { continuation in
            inboundSink.yield(.caughtUp(continuation))
        }
    }

    public var isRunning: Bool {
        process?.isRunning == true || bridgeConnection != nil
    }

    /// Starts dsh and opens a session: the earlier one when dsh still has it, otherwise a new one.
    /// Returns the session's id.
    public func start(resuming earlier: String?) async throws -> String {
        // dsh keeps the folder it started in, and fails every turn once it is renamed or moved.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            SpotLog.agent.error("The command folder is gone", metadata: ["folder": "\(folder.path)"])
            shutDown()
            throw CommandAgentError.folderMissing(folder.lastPathComponent)
        }
        // dsh holds one session; a question for another session starts it again in that one.
        if let sessionID, let earlier, earlier != sessionID, isRunning {
            SpotLog.agent.warning("dsh holds another session; starting it again", metadata: [
                "holds": "\(sessionID)", "wanted": "\(earlier)",
            ])
            needsRestart = true
            self.sessionID = earlier
        }
        if let sessionID, isRunning, !needsRestart { return sessionID }
        var earlier = earlier
        if needsRestart {
            earlier = sessionID ?? earlier
            shutDown()
            needsRestart = false
        }
        let sink = inboundSink
        let onOrdered: @Sendable (JsonRpcNotification) -> Void = { notification in
            guard let params = notification.params,
                  let data = try? JSONEncoder().encode(params),
                  let note = try? JSONDecoder().decode(SessionNotification.self, from: data)
            else { return }
            sink.yield(.update(note.update))
        }
        if inboundReader == nil {
            let updates = inbound
            inboundReader = Task { [weak self] in
                for await item in updates {
                    switch item {
                    case let .update(update): await self?.handle(update)
                    case let .caughtUp(continuation): continuation.resume()
                    }
                }
            }
        }
        let transport: PipeTransport
        switch connection {
        case let .bundled(runtime):
            transport = try launch(runtime, onOrdered: onOrdered)
        case let .bridge(bridge, token):
            transport = try open(bridge, token: token, onOrdered: onOrdered)
        }
        // A turn can run for a long time; it ends when dsh answers or exits.
        let rpc = ACPProtocol(transport: transport, defaultTimeoutSeconds: 7 * 24 * 3600)
        self.rpc = rpc

        await rpc.onRequest(method: "session/request_permission", requestType: RequestPermissionRequest.self) { [weak self] request in
            guard let self else { return RequestPermissionResponse(outcome: .cancelled) }
            return await self.answer(request)
        }
        try await rpc.start()
        // Replies are read only for what is used: the SDK's models require fields that ACP leaves
        // optional and dsh leaves out, such as `mcpCapabilities.sse`.
        _ = try await rpc.sendRequest(method: "initialize", params: InitializeRequest(
            protocolVersion: .current,
            // No file or terminal access through Spot Chat: dsh uses its own sandboxed tools.
            clientCapabilities: ClientCapabilities(),
            clientInfo: Implementation(name: "spot-chat", version: Self.appVersion)
        ))

        if let earlier {
            do {
                let resumed = try await rpc.sendRequest(
                    method: "session/resume",
                    params: ResumeSessionRequest(sessionId: SessionId(value: earlier), cwd: folder.path, mcpServers: [])
                )
                sessionID = earlier
                configOptions = Self.configOptions(in: resumed.result)
                SpotLog.agent.info("Resumed the dsh session", metadata: ["session": "\(earlier)"])
            } catch {
                // A new session starts instead, without what dsh remembered of the earlier one.
                SpotLog.agent.warning("Couldn't resume the dsh session", metadata: [
                    "session": "\(earlier)", "error": "\(error)",
                ])
            }
        }
        if sessionID == nil {
            let created = try await rpc.sendRequest(
                method: "session/new", params: NewSessionRequest(cwd: folder.path, mcpServers: [])
            )
            guard case let .object(result) = created.result, case let .string(id)? = result["sessionId"] else {
                throw CommandAgentError.noSession
            }
            sessionID = id
            configOptions = Self.configOptions(in: created.result)
        }
        appliedModel = nil
        appliedEffort = nil
        guard let sessionID else { throw CommandAgentError.noSession }
        return sessionID
    }

    /// Settings for the next turn. dsh reads whether it may search the web when it starts, so a change
    /// there restarts it, back in the same session.
    public func update(model: String?, effort: String?, searchesTheWeb: Bool) {
        options.model = model
        options.effort = effort
        // The user's own dsh keeps its own web settings.
        if options.searchesTheWeb != searchesTheWeb, !connection.isHarness {
            options.searchesTheWeb = searchesTheWeb
            needsRestart = isRunning
        }
    }

    /// Sends the question with links to `paths`, and returns when dsh has answered.
    /// Returns false when the turn was stopped.
    @discardableResult
    public func send(_ text: String, paths: [URL], onEvent: @escaping @Sendable (CommandEvent) -> Void) async throws -> Bool {
        guard let rpc, let sessionID else { throw CommandAgentError.noSession }
        try await applyOptions()
        var blocks: [ContentBlock] = []
        if !text.isEmpty { blocks.append(.text(TextContent(text: text))) }
        for path in paths {
            blocks.append(.resourceLink(ResourceLinkContent(name: path.lastPathComponent, uri: path.absoluteString)))
        }
        self.onEvent = onEvent
        runs = [:]
        isCancelling = false
        defer { self.onEvent = nil }
        let response = try await rpc.sendRequest(
            method: "session/prompt", params: PromptRequest(sessionId: SessionId(value: sessionID), prompt: blocks)
        )
        // The updates dsh sent before its answer are part of this turn.
        await catchUp()
        var stopped = isCancelling
        if case let .object(result) = response.result, case let .string(reason)? = result["stopReason"] {
            stopped = reason == "cancelled"
            // dsh also reports a turn that ended without a reason as cancelled.
            if stopped && !isCancelling {
                SpotLog.agent.warning("dsh ended the turn as stopped without being asked", metadata: ["session": "\(sessionID)"])
            }
        }
        for (id, var run) in runs where !run.isFinished {
            run.state = stopped ? .stopped : .succeeded
            run.duration = Date().timeIntervalSince(run.startedAt)
            runs[id] = run
            onEvent(.run(run))
        }
        return !stopped
    }

    /// Asks dsh to stop the turn; `send` then returns.
    public func cancel() async {
        guard let rpc, let sessionID else { return }
        isCancelling = true
        try? await rpc.sendCancel(notification: CancelNotification(sessionId: SessionId(value: sessionID)))
    }

    public func shutDown() {
        if process != nil { SpotLog.agent.info("Stopping dsh") }
        if bridgeConnection != nil { SpotLog.agent.info("Disconnecting from DeepSeek Harness") }
        bridgeConnection = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        let rpc = rpc
        self.rpc = nil
        sessionID = nil
        Task { await rpc?.close() }
    }

    // MARK: Updates

    private func handle(_ update: SessionUpdate) {
        switch update {
        case let .agentMessageChunk(chunk):
            if case let .text(text) = chunk.content { onEvent?(.text(text.text)) }
        case let .agentThoughtChunk(chunk):
            if case let .text(text) = chunk.content { onEvent?(.thought(text.text)) }
        case let .toolCall(call):
            var run = Self.run(id: call.toolCallId.value, title: call.title, input: call.rawInput)
            if let status = call.status { apply(status, content: call.content, to: &run) }
            runs[run.id] = run
            onEvent?(.run(run))
        case let .toolCallUpdate(change):
            let id = change.toolCallId.value
            var run = runs[id] ?? Self.run(id: id, title: change.title ?? "", input: change.rawInput)
            if let input = change.rawInput {
                let fresh = Self.run(id: id, title: change.title ?? "", input: input)
                run.summary = fresh.summary
                run.detail = fresh.detail
            }
            if let status = change.status { apply(status, content: change.content ?? [], to: &run) }
            runs[id] = run
            onEvent?(.run(run))
        default:
            break
        }
    }

    private func apply(_ status: ToolCallStatus, content: [ToolCallContent], to run: inout CommandRun) {
        let raw = content.compactMap { item -> String? in
            if case let .content(block) = item, case let .text(text) = block.content { return text.text }
            return nil
        }.joined(separator: "\n")
        switch status {
        case .pending, .inProgress:
            if run.state != .waitingForApproval { run.state = .running }
            return
        case .completed, .failed:
            break
        }
        let result = CommandOutput.read(raw)
        switch run.tool {
        case .webSearch:
            // Shown as a list of results; the text around them is meant for the model.
            run.sources = WebResult.sources(in: raw)
            run.output = ""
        case .webFetch:
            run.pageTitle = WebResult.pageTitle(in: raw)
            run.output = ""
        case .shell, .other:
            run.output = result.text
            run.exitCode = result.exitCode
        }
        run.duration = Date().timeIntervalSince(run.startedAt)
        if run.state == .denied { return }
        if isCancelling, status == .failed {
            run.state = .stopped
        } else if result.blockedBySandbox {
            run.state = .blocked
        } else if status == .failed || (result.exitCode ?? 0) != 0 {
            run.state = .failed
        } else {
            run.state = .succeeded
        }
    }

    private func answer(_ request: RequestPermissionRequest) async -> RequestPermissionResponse {
        // dsh announces the command before asking about it.
        await catchUp()
        let id = request.toolCall.toolCallId.value
        guard var run = runs[id] else { return Self.choose(.deny, from: request.options) }
        run.state = .waitingForApproval
        runs[id] = run
        onEvent?(.run(run))

        let decision = await approver(run)

        guard var run = runs[id] else { return Self.choose(decision, from: request.options) }
        switch decision {
        case .allow:
            run.state = .running
            run.outsideFolder = true
            run.startedAt = Date()
        case .deny:
            run.state = .denied
        case .cancel:
            run.state = .stopped
        }
        runs[id] = run
        onEvent?(.run(run))
        return Self.choose(decision, from: request.options)
    }

    private static func choose(_ decision: CommandApproval, from options: [PermissionOption]) -> RequestPermissionResponse {
        let kinds: [PermissionOptionKind]
        switch decision {
        case .allow: kinds = [.allowOnce]
        case .deny: kinds = [.rejectOnce]
        case .cancel: return RequestPermissionResponse(outcome: .cancelled)
        }
        guard let option = options.first(where: { kinds.contains($0.kind) }) else {
            return RequestPermissionResponse(outcome: .cancelled)
        }
        return RequestPermissionResponse(outcome: .selected(option.optionId))
    }

    /// A tool call as the reply shows it, from dsh's input to the tool.
    static func run(id: String, title: String, input: JsonValue?) -> CommandRun {
        func field(_ key: String) -> String? {
            if case let .object(object)? = input, case let .string(value)? = object[key], !value.isEmpty { return value }
            return nil
        }
        let tool: CommandRun.Tool
        switch title {
        case "bash": tool = .shell
        case "web_search": tool = .webSearch
        case "web_fetch": tool = .webFetch
        default: tool = .other
        }
        var query: String?
        if case let .object(object)? = input, case let .array(queries)? = object["queries"],
           case let .string(first)? = queries.first {
            query = first
        }
        // working_directory takes `cd`, the folder it moves to.
        let detail = field("command") ?? query ?? field("query") ?? field("url") ?? field("path") ?? field("cd") ?? ""
        return CommandRun(
            id: id, tool: tool, summary: field("description") ?? "", detail: detail,
            justification: field("justification"),
            outsideFolder: field("sandbox_permissions") != nil
        )
    }

    // MARK: Model and effort

    private func applyOptions() async throws {
        guard let rpc, let sessionID else { return }
        if let model = options.model, model != appliedModel,
           await setOption("model", to: model, rpc: rpc, sessionID: sessionID) {
            appliedModel = model
        }
        if let effort = options.effort, effort != appliedEffort,
           await setOption("reasoning_effort", to: effort, rpc: rpc, sessionID: sessionID) {
            appliedEffort = effort
        }
    }

    /// Sets one of the session's options before a turn. One dsh doesn't offer or refuses is logged and
    /// left unapplied, so the next turn tries it again.
    private func setOption(_ optionID: String, to wanted: String, rpc: ACPProtocol, sessionID: String) async -> Bool {
        guard let value = value(of: optionID, matching: wanted) else {
            SpotLog.agent.notice("dsh doesn't offer this option", metadata: ["option": "\(optionID)", "value": "\(wanted)"])
            return false
        }
        do {
            _ = try await rpc.sendRequest(method: "session/set_config_option", params: SetSessionConfigOptionRequest(
                sessionId: SessionId(value: sessionID), configId: SessionConfigId(value: optionID), value: .string(value)
            ))
            SpotLog.agent.info("Set a session option", metadata: ["option": "\(optionID)", "value": "\(value)"])
            return true
        } catch {
            SpotLog.agent.error("Couldn't set a session option", metadata: [
                "option": "\(optionID)", "value": "\(value)", "error": "\(error)",
            ])
            return false
        }
    }

    /// The session's options that the SDK can read; one it can't is skipped rather than failing them all.
    static func configOptions(in result: JsonValue) -> [SessionConfigOption] {
        guard case let .object(object) = result, case let .array(items)? = object["configOptions"] else { return [] }
        return items.compactMap { item in
            (try? JSONEncoder().encode(item)).flatMap { try? JSONDecoder().decode(SessionConfigOption.self, from: $0) }
        }
    }

    /// The option value whose name, or value, is `wanted`. dsh's model values are JSON such as
    /// `["deepseek-official","deepseek-v4-pro"]`.
    private func value(of optionID: String, matching wanted: String) -> String? {
        for option in configOptions {
            guard case let .select(select) = option, select.id.value == optionID else { continue }
            let choices: [SessionConfigSelectOption]
            switch select.options {
            case let .flat(list): choices = list
            case let .grouped(groups): choices = groups.flatMap(\.options)
            }
            let wanted = wanted.lowercased()
            return choices.first { choice in
                let value = choice.value.value
                let modelName = (try? JSONDecoder().decode([String].self, from: Data(value.utf8)))?.last ?? value
                return choice.name.lowercased() == wanted || modelName.lowercased() == wanted
            }?.value.value
        }
        return nil
    }

    // MARK: Process

    /// Starts dsh from the bundled runtime, and returns ACP over its standard input and output.
    private func launch(_ runtime: CommandRuntime, onOrdered: @escaping @Sendable (JsonRpcNotification) -> Void) throws -> PipeTransport {
        try prepareHome(runtime)

        let process = Process()
        process.executableURL = runtime.launcher
        process.arguments = ["--profile", "spot"]
        process.currentDirectoryURL = folder
        process.environment = environment()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.noteError(text) }
        }
        let transport = PipeTransport(
            reading: output.fileHandleForReading, writing: input.fileHandleForWriting, ordered: ["session/update"],
            onOrderedNotification: onOrdered
        )
        process.terminationHandler = { [weak self] _ in
            Task { await self?.exited() }
        }
        // Only the names of the variables: one of them holds the API key.
        SpotLog.agent.info("Starting dsh", metadata: [
            "version": "\(runtime.version)", "launcher": "\(runtime.launcher.path)", "folder": "\(folder.path)",
            "environment": "\(process.environment?.keys.sorted().joined(separator: ",") ?? "")",
            "model": "\(options.model ?? "")", "effort": "\(options.effort ?? "")", "web": "\(options.searchesTheWeb)",
        ])
        do {
            try process.run()
        } catch {
            SpotLog.agent.error("Couldn't start dsh", metadata: ["error": "\(error)"])
            throw error
        }
        SpotLog.agent.info("dsh started", metadata: ["pid": "\(process.processIdentifier)"])
        self.process = process
        return transport
    }

    /// Connects to the user's DeepSeek Harness through Spot Chat's plugin, and returns ACP over the socket.
    /// The user's dsh runs with its own settings, key and model list; Spot Chat only picks the model.
    private func open(_ bridge: DshBridge, token: String, onOrdered: @escaping @Sendable (JsonRpcNotification) -> Void) throws -> PipeTransport {
        SpotLog.agent.info("Connecting to DeepSeek Harness", metadata: [
            "socket": "\(bridge.socket.path)", "folder": "\(folder.path)",
            "model": "\(options.model ?? "")", "effort": "\(options.effort ?? "")",
        ])
        let (handle, version) = try bridge.connect(token: token)
        let id = UUID()
        bridgeConnection = id
        SpotLog.agent.info("Connected to DeepSeek Harness", metadata: ["acp": "\(version)"])
        return PipeTransport(
            reading: handle, writing: handle, ordered: ["session/update"], onOrderedNotification: onOrdered,
            onClose: { [weak self] in
                Task { await self?.bridgeClosed(id) }
            }
        )
    }

    private func bridgeClosed(_ id: UUID) async {
        guard bridgeConnection == id else { return }
        SpotLog.agent.warning("DeepSeek Harness closed the connection")
        stderrTail = String(localized: "DeepSeek Harness closed the connection.")
        await exited()
    }

    private func prepareHome(_ runtime: CommandRuntime) throws {
        let files = FileManager.default
        let profile = options.home.appendingPathComponent("profiles/spot")
        try files.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The profile is replaced on every start so it always matches the bundled dsh.
        try? files.removeItem(at: profile)
        try files.copyItem(at: runtime.profile, to: profile)
        // dsh sends this id with every model request. The same one for everyone tells no one apart.
        try "00000000-0000-0000-0000-000000000000\n".write(
            to: options.home.appendingPathComponent(".anonymous-user-id"), atomically: true, encoding: .utf8
        )
    }

    private func environment() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR"] {
            environment[key] = parent[key]
        }
        // Apps start with the system's short PATH; add where Homebrew and others put tools such as ffmpeg.
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let system = (parent["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        environment["PATH"] = (extra + system.filter { !extra.contains($0) }).joined(separator: ":")
        environment["DSH_HOME"] = options.home.path
        environment["DEEPSEEK_API_KEY"] = options.apiKey
        if let baseURL = options.baseURL { environment["DEEPSEEK_BASE_URL"] = baseURL }
        if let webToolsURL = options.webToolsURL { environment["SPOT_CHAT_WEB_TOOLS_URL"] = webToolsURL }
        if !options.searchesTheWeb { environment["SPOT_CHAT_WEB"] = "off" }
        environment["NO_COLOR"] = "1"
        environment["DO_NOT_TRACK"] = "1"
        return environment
    }

    private func noteError(_ text: String) {
        SpotLog.agent.notice("dsh wrote to its error output", metadata: ["text": "\(SpotLog.clip(text))"])
        stderrTail = String((stderrTail + text).suffix(2000))
    }

    private func exited() async {
        SpotLog.agent.warning("dsh exited", metadata: [
            "status": "\(process?.terminationStatus ?? -1)", "reason": "\(process?.terminationReason.rawValue ?? 0)",
            "lastError": "\(stderrTail.split(separator: "\n").last.map(String.init) ?? "")",
        ])
        let detail = stderrTail.split(separator: "\n").last.map(String.init) ?? ""
        await rpc?.cancelPendingOutgoingRequests(error: CommandAgentError.exited(detail))
        await rpc?.close()
        rpc = nil
        process = nil
        bridgeConnection = nil
        sessionID = nil
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
