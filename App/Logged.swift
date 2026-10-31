import Logging
import SpotCore

/// Runs a write the app can carry on without, such as saving a setting or a message: a failure is
/// logged with where it happened instead of being dropped silently.
@discardableResult
func logged<T>(file: String = #fileID, line: Int = #line, _ body: () throws -> T) -> T? {
    do {
        return try body()
    } catch {
        SpotLog.data.error("Couldn't save", metadata: ["at": "\(file):\(line)", "error": "\(error)"])
        return nil
    }
}
