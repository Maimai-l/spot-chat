// SpotChatWriter writes one chat reply apart from the app. The app starts it with a ReplyJob on its input;
// it streams the model's answer, saves the reply into the app's database as it arrives, and prints each
// update for the app as a line of JSON. It keeps going if the app quits, so a reply is finished and saved
// either way, and it exits when the reply is done. It holds no window and nothing else, so it stays small.

import Darwin
import Foundation
import SpotAI
import SpotCore
import SpotData

// The app may be gone by the time a line is printed; a closed pipe is then an error to note, not a crash.
signal(SIGPIPE, SIG_IGN)
AppLogging.start(forWriter: true)
await Writer.run()

/// Writes the job's reply and exits; everything lives here rather than in globals, which top-level code
/// that waits would tie to the main thread.
enum Writer {
    static func run() async -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let job: ReplyJob
        do {
            job = try JSONDecoder().decode(ReplyJob.self, from: input)
        } catch {
            SpotLog.reply.error("The writer couldn't read its job", metadata: ["error": "\(error)", "bytes": "\(input.count)"])
            exit(1)
        }

        let started = Date()
        let dataDirectory = URL(fileURLWithPath: job.dataDirectory, isDirectory: true)
        SpotLog.reply.info("Writer started", metadata: [
            "reply": "\(job.replyID)", "topic": "\(job.topicID)", "pid": "\(getpid())", "model": "\(job.request.model)",
        ])

        // A mark the app reads on launch to tell a reply still being written from one a quit or crash cut off.
        let marks = ReplyJob.writersDirectory(in: dataDirectory)
        let mark = marks.appendingPathComponent(job.replyID.uuidString)
        do {
            try FileManager.default.createDirectory(at: marks, withIntermediateDirectories: true)
            try Data("\(getpid())".utf8).write(to: mark, options: .atomic)
        } catch {
            SpotLog.reply.error("The writer couldn't leave its mark", metadata: ["error": "\(error)"])
        }

        func finish(_ code: Int32) -> Never {
            do {
                try FileManager.default.removeItem(at: mark)
            } catch {
                SpotLog.reply.error("The writer couldn't remove its mark", metadata: ["error": "\(error)"])
            }
            SpotLog.reply.info("Writer finished", metadata: [
                "reply": "\(job.replyID)", "seconds": "\(String(format: "%.1f", Date().timeIntervalSince(started)))",
                "memoryMB": "\(String(format: "%.1f", footprintMegabytes()))",
            ])
            exit(code)
        }

        let output = Output(replyID: job.replyID)
        let saved: SavedReply
        let runner: ChatReplyRunner
        do {
            let database = try AppDatabase.onDisk(at: dataDirectory.appendingPathComponent("SpotChat.sqlite"))
            let files = FileEntryService(database: database, directory: dataDirectory.appendingPathComponent("Files", isDirectory: true))
            let messages = MessageService(database: database, files: files)
            guard let reply = try messages.get(job.replyID) else {
                SpotLog.reply.error("The writer's reply isn't in the database", metadata: ["reply": "\(job.replyID)"])
                finish(1)
            }
            guard let provider = try ProviderService(database: database).list().first(where: { $0.id == job.providerID }) else {
                SpotLog.reply.error("The writer's provider isn't in the database", metadata: ["provider": "\(job.providerID)"])
                finish(1)
            }
            saved = SavedReply(reply, messages: messages)
            let client = try OpenAICompatibleClient(baseURL: provider.baseURL, apiKey: provider.apiKey)
            let tools = job.webToolsURL.map { DeepSeekWebTools(apiKey: provider.apiKey, baseURL: $0) }
            runner = ChatReplyRunner(responder: client, tools: tools, describe: ErrorText.describe)
        } catch {
            SpotLog.reply.error("The writer couldn't start the reply", metadata: ["reply": "\(job.replyID)", "error": "\(error)"])
            finish(1)
        }

        // The Mac stays awake while the reply is written, as it does while the app writes one.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Writing a reply"
        )
        let request = job.request
        let question = job.question
        let replyID = job.replyID
        let writing = Task {
            await runner.run(request, question: question, replyID: replyID) { event in
                switch event {
                case let .progress(progress):
                    saved.update { reply in
                        reply.text = progress.text
                        reply.reasoning = progress.reasoning
                        reply.reasoningDuration = progress.reasoningDuration
                        reply.commands = progress.steps
                    }
                    output.send(.progress(progress))
                case let .usage(usage):
                    saved.update { $0.usage = usage }
                    output.send(.usage(usage))
                case .effortRejected:
                    output.send(.effortRejected)
                }
            }
        }

        // Stop asks with SIGTERM; the reply is then saved as stopped, keeping what arrived.
        signal(SIGTERM, SIG_IGN)
        let stopSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        stopSignal.setEventHandler {
            SpotLog.reply.info("The writer was asked to stop", metadata: ["reply": "\(replyID)"])
            writing.cancel()
        }
        stopSignal.resume()

        let result = await writing.value
        saved.update(force: true) { reply in
            reply.text = result.progress.text
            reply.reasoning = result.progress.reasoning
            reply.reasoningDuration = result.progress.reasoningDuration
            reply.commands = result.progress.steps
            if let failure = result.failure {
                reply.status = .error
                reply.errorMessage = failure
            } else {
                reply.status = result.stopped ? .paused : .success
            }
        }
        // The text as saved, to compare with what the service sent and what the app showed.
        SpotLog.reply.debug("Reply text", metadata: ["reply": "\(replyID)", "text": "\(SpotLog.clip(result.progress.text))"])
        output.send(.finished(failure: result.failure, stopped: result.stopped))
        ProcessInfo.processInfo.endActivity(activity)
        stopSignal.cancel()
        finish(0)
    }
}

/// Prints lines for the app while it is there to read them.
final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true
    private let encoder = JSONEncoder()
    private let replyID: UUID

    init(replyID: UUID) {
        self.replyID = replyID
    }

    func send(_ line: ReplyWriterLine) {
        lock.withLock {
            guard isOpen, var data = try? encoder.encode(line) else { return }
            data.append(0x0A)
            do {
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch {
                isOpen = false
                SpotLog.reply.notice("The app stopped reading; writing on alone", metadata: ["reply": "\(replyID)"])
            }
        }
    }
}

/// The reply as saved, written at most five times a second so the database keeps up with the stream.
final class SavedReply: @unchecked Sendable {
    private let lock = NSLock()
    private var message: ChatMessage
    private var lastSave = Date.distantPast
    private let messages: MessageService

    init(_ message: ChatMessage, messages: MessageService) {
        self.message = message
        self.messages = messages
    }

    func update(force: Bool = false, _ change: (inout ChatMessage) -> Void) {
        lock.withLock {
            change(&message)
            guard force || Date().timeIntervalSince(lastSave) >= 0.2 else { return }
            lastSave = Date()
            do {
                try messages.update(message)
            } catch {
                SpotLog.data.error("The writer couldn't save the reply", metadata: ["reply": "\(message.id)", "error": "\(error)"])
            }
        }
    }
}

/// Memory the writer used, as Activity Monitor counts it.
func footprintMegabytes() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

