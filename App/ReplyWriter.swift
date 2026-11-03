import Darwin
import Foundation
import SpotCore

/// Hands chat replies to SpotChatWriter, a process of its own inside the app, so a reply is finished and
/// saved even when the app quits or crashes partway through. The app shows what the writer reports while
/// it runs; after a relaunch it reads the reply from the database as the writer saves it.
enum ReplyWriter {
    static var executableURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "SpotChatWriter")
    }

    /// Starts writing the job's reply. Returns the writer's process id and the lines it prints, ending when it
    /// exits; nil when the writer isn't in this build or wouldn't start, and the app then writes the reply itself.
    static func start(_ job: ReplyJob) -> (pid: pid_t, lines: AsyncStream<ReplyWriterLine>)? {
        guard let executableURL else { return nil }
        let input: Data
        do {
            input = try JSONEncoder().encode(job)
        } catch {
            SpotLog.reply.error("Couldn't hand the reply to the writer", metadata: ["error": "\(error)"])
            return nil
        }
        let process = Process()
        process.executableURL = executableURL
        // The writer words failures in the language the app uses.
        process.arguments = ["-AppleLanguages", "(\(Bundle.main.preferredLocalizations.joined(separator: ",")))"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let replyID = job.replyID
        process.terminationHandler = { process in
            SpotLog.reply.info("Writer exited", metadata: [
                "reply": "\(replyID)", "status": "\(process.terminationStatus)",
                "reason": "\(process.terminationReason == .uncaughtSignal ? "signal" : "exit")",
            ])
        }
        do {
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        } catch {
            SpotLog.reply.error("Couldn't start the writer", metadata: ["error": "\(error)"])
            if process.isRunning { process.terminate() }
            return nil
        }
        SpotLog.reply.info("Handed the reply to the writer", metadata: ["reply": "\(replyID)", "pid": "\(process.processIdentifier)"])

        let lines = AsyncStream<ReplyWriterLine> { continuation in
            let reading = Task.detached {
                let decoder = JSONDecoder()
                do {
                    for try await text in stdout.fileHandleForReading.bytes.lines {
                        do {
                            continuation.yield(try decoder.decode(ReplyWriterLine.self, from: Data(text.utf8)))
                        } catch {
                            SpotLog.reply.error("Couldn't read a line from the writer", metadata: [
                                "line": "\(SpotLog.clip(text))", "error": "\(error)",
                            ])
                        }
                    }
                } catch {
                    SpotLog.reply.error("Lost the writer's output", metadata: ["error": "\(error)"])
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in reading.cancel() }
        }
        return (process.processIdentifier, lines)
    }

    /// The writer still at work on the reply, from the mark it leaves while it writes; nil when none is, as
    /// after a writer that finished or one cut off by a restart.
    static func writer(of replyID: UUID, dataDirectory: URL) -> pid_t? {
        let mark = ReplyJob.writersDirectory(in: dataDirectory).appendingPathComponent(replyID.uuidString)
        guard let text = try? String(contentsOf: mark, encoding: .utf8), let pid = pid_t(text), isWriter(pid) else {
            return nil
        }
        return pid
    }

    /// Asks the writer to stop; it saves the reply as stopped, keeping what arrived.
    static func stop(_ pid: pid_t) {
        guard isWriter(pid) else { return }
        if kill(pid, SIGTERM) != 0 {
            SpotLog.reply.error("Couldn't ask the writer to stop", metadata: ["pid": "\(pid)", "errno": "\(errno)"])
        }
    }

    /// Whether the process is a running SpotChatWriter, not another that reused its id.
    private static func isWriter(_ pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return URL(fileURLWithPath: String(cString: path)).lastPathComponent == "SpotChatWriter"
    }
}
