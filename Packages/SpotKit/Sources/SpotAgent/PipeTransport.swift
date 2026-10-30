import ACP
import ACPModel
import Foundation

/// ACP's newline-delimited JSON-RPC over a child process's pipes. Lines are read as data arrives,
/// so no thread waits on the pipe.
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

    /// `reading` is the child's standard output, `writing` its standard input.
    init(reading: FileHandle, writing: FileHandle) {
        self.reading = reading
        self.writing = writing
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
            if let message = try? decoder.decode(JsonRpcMessage.self, from: line) {
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
