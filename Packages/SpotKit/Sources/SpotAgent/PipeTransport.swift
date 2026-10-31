import ACP
import ACPModel
import Foundation
import Logging
import SpotCore

/// ACP's newline-delimited JSON-RPC over a child process's pipes. Lines are read as data arrives,
/// so no thread waits on the pipe.
///
/// Notifications named in `ordered` go to `onOrderedNotification` instead, in the order they were read:
/// the SDK hands each notification to a task of its own, which can reorder a reply's chunks.
final class PipeTransport: Transport, @unchecked Sendable {
    enum Failure: Error {
        case closed
    }

    let state: AsyncStream<TransportState>
    let messages: AsyncStream<JsonRpcMessage>

    private let reading: FileHandle
    private let writing: FileHandle
    private let stateContinuation: AsyncStream<TransportState>.Continuation
    private let messageContinuation: AsyncStream<JsonRpcMessage>.Continuation
    private let lock = NSLock()
    private var buffer = Data()
    private var isClosed = false
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private let ordered: Set<String>
    private let onOrderedNotification: @Sendable (JsonRpcNotification) -> Void

    /// `reading` is the child's standard output, `writing` its standard input.
    init(
        reading: FileHandle, writing: FileHandle, ordered: Set<String> = [],
        onOrderedNotification: @escaping @Sendable (JsonRpcNotification) -> Void = { _ in }
    ) {
        self.reading = reading
        self.writing = writing
        self.ordered = ordered
        self.onOrderedNotification = onOrderedNotification
        (state, stateContinuation) = AsyncStream.makeStream()
        (messages, messageContinuation) = AsyncStream.makeStream()
        stateContinuation.yield(.created)
    }

    func start() async throws {
        stateContinuation.yield(.started)
        reading.readabilityHandler = { [weak self] handle in
            self?.received(handle.availableData)
        }
    }

    func send(_ message: JsonRpcMessage) async throws {
        var data = try encoder.encode(message)
        SpotLog.agent.trace("Sent", metadata: ["line": "\(SpotLog.clip(String(decoding: data, as: UTF8.self)))"])
        data.append(0x0A)
        try lock.withLock {
            guard !isClosed else { throw Failure.closed }
            try writing.write(contentsOf: data)
        }
    }

    func close() async {
        finish()
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else {
            // The child closed its output: it has exited.
            finish()
            return
        }
        let lines: [Data] = lock.withLock {
            buffer.append(data)
            var lines: [Data] = []
            while let end = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<end])
                buffer.removeSubrange(buffer.startIndex...end)
            }
            return lines
        }
        for line in lines where !line.isEmpty {
            SpotLog.agent.trace("Received", metadata: ["line": "\(SpotLog.clip(String(decoding: line, as: UTF8.self)))"])
            guard let message = try? decoder.decode(JsonRpcMessage.self, from: line) else {
                SpotLog.agent.warning("Received a line that isn't JSON-RPC")
                continue
            }
            if case let .notification(notification) = message, ordered.contains(notification.method) {
                onOrderedNotification(notification)
            } else {
                messageContinuation.yield(message)
            }
        }
    }

    private func finish() {
        let wasClosed = lock.withLock {
            defer { isClosed = true }
            return isClosed
        }
        guard !wasClosed else { return }
        reading.readabilityHandler = nil
        try? writing.close()
        stateContinuation.yield(.closed)
        stateContinuation.finish()
        messageContinuation.finish()
    }
}
