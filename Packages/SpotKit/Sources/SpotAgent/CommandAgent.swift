import ACP
import ACPModel
import Foundation
import SpotCore

/// The dsh runtime bundled with the app: Node, dsh trimmed to what it loads, and Spot Chat's profile.
public struct CommandRuntime: Sendable {
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

    public init(apiKey: String, baseURL: String? = nil, home: URL, model: String? = nil, effort: String? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL
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

    public var errorDescription: String? {
        switch self {
        case let .exited(detail):
            return detail.isEmpty ? String(localized: "Commands stopped unexpectedly.") : String(localized: "Commands stopped unexpectedly: \(detail)")
        case .noSession:
            return String(localized: "Couldn't start running commands.")
        }
    }
}

/// One dsh process speaking ACP, holding one session in one folder. dsh runs each command in its sandbox,
/// which lets it write only inside the folder; when a command needs more, dsh asks and `approver` answers.
public actor CommandAgent {
    public typealias Approver = @Sendable (CommandRun) async -> CommandApproval

    public let folder: URL
    private let runtime: CommandRuntime
    private var options: CommandAgentOptions
    private let approver: Approver

    private var process: Process?
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

    /// dsh's session updates in the order it sent them, and marks for catching up with them.
    private enum Inbound: Sendable {
        case update(SessionUpdate)
        case caughtUp(CheckedContinuation<Void, Never>)
    }
    private let inbound: AsyncStream<Inbound>
    private let inboundSink: AsyncStream<Inbound>.Continuation
    private var inboundReader: Task<Void, Never>?

    public init(runtime: CommandRuntime, options: CommandAgentOptions, folder: URL, approver: @escaping Approver) {
        self.runtime = runtime
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
        process?.isRunning == true
    }

    /// Starts dsh and opens a session: the earlier one when dsh still has it, otherwise a new one.
    /// Returns the session's id.
    public func start(resuming earlier: String?) async throws -> String {
        if let sessionID, isRunning { return sessionID }
        try prepareHome()

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

        let sink = inboundSink
        let transport = PipeTransport(
            reading: output.fileHandleForReading, writing: input.fileHandleForWriting, ordered: ["session/update"]
        ) { notification in
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
        // A turn can run for a long time; it ends when dsh answers or exits.
        let rpc = ACPProtocol(transport: transport, defaultTimeoutSeconds: 7 * 24 * 3600)
        process.terminationHandler = { [weak self] _ in
            Task { await self?.exited() }
        }
        try process.run()
        self.process = process
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

        if let earlier,
           let resumed = try? await rpc.sendRequest(
               method: "session/resume",
               params: ResumeSessionRequest(sessionId: SessionId(value: earlier), cwd: folder.path, mcpServers: [])
           ) {
            sessionID = earlier
            configOptions = Self.configOptions(in: resumed.result)
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

    public func update(model: String?, effort: String?) {
        options.model = model
        options.effort = effort
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
        run.output = result.text
        run.exitCode = result.exitCode
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
        let detail = field("command") ?? field("query") ?? field("url") ?? field("path") ?? ""
        return CommandRun(
            id: id, tool: tool, summary: field("description") ?? "", detail: detail,
            justification: field("justification"),
            outsideFolder: field("sandbox_permissions") != nil
        )
    }

    // MARK: Model and effort

    private func applyOptions() async throws {
        guard let rpc, let sessionID else { return }
        if let model = options.model, model != appliedModel, let value = value(of: "model", matching: model) {
            _ = try? await rpc.sendRequest(method: "session/set_config_option", params: SetSessionConfigOptionRequest(
                sessionId: SessionId(value: sessionID), configId: SessionConfigId(value: "model"), value: .string(value)
            ))
            appliedModel = model
        }
        if let effort = options.effort, effort != appliedEffort, let value = value(of: "reasoning_effort", matching: effort) {
            _ = try? await rpc.sendRequest(method: "session/set_config_option", params: SetSessionConfigOptionRequest(
                sessionId: SessionId(value: sessionID), configId: SessionConfigId(value: "reasoning_effort"), value: .string(value)
            ))
            appliedEffort = effort
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

    private func prepareHome() throws {
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
        environment["NO_COLOR"] = "1"
        environment["DO_NOT_TRACK"] = "1"
        return environment
    }

    private func noteError(_ text: String) {
        stderrTail = String((stderrTail + text).suffix(2000))
    }

    private func exited() async {
        let detail = stderrTail.split(separator: "\n").last.map(String.init) ?? ""
        await rpc?.cancelPendingOutgoingRequests(error: CommandAgentError.exited(detail))
        await rpc?.close()
        rpc = nil
        process = nil
        sessionID = nil
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
