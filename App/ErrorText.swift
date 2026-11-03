import Foundation
import SpotAI

/// Turns failures into the text shown in place of a reply.
enum ErrorText {
    /// Where the words are looked up: the app itself, or, for the reply writer inside it, the app around it.
    static let bundle: Bundle = {
        let main = Bundle.main
        guard main.bundleURL.pathExtension != "app" else { return main }
        // The writer runs from Contents/MacOS of the app.
        let app = main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.flatMap(Bundle.init(url:)) ?? main
    }()

    static func describe(_ error: Error) -> String {
        if !(error is ChatServiceError), let description = (error as? LocalizedError)?.errorDescription {
            return description
        }
        switch ChatServiceError(error) {
        case let .api(message):
            return message
        case let .http(statusCode):
            return String(localized: "The service returned HTTP \(statusCode).", bundle: bundle)
        case .network:
            return String(localized: "Couldn't reach the service. Check the API address and your connection.", bundle: bundle)
        case .invalidEndpoint:
            return String(localized: "The API address in Settings isn't valid.", bundle: bundle)
        case let .other(message):
            return message
        }
    }
}
