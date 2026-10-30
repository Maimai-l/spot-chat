import Foundation

/// Placeholders a system prompt can hold, with the names Cherry Studio uses (src/main/utils/prompt.ts).
/// Dates and times are those of the conversation's start, not of each request: a prompt that changes
/// with every request would miss the service's prompt cache every time.
public enum PromptVariable: String, CaseIterable, Sendable {
    case date, time, datetime, username, system, language, arch
    case modelName = "model_name"

    public var placeholder: String { "{{\(rawValue)}}" }
}

public enum PromptVariables {
    public struct Context: Sendable {
        public var start: Date
        public var modelName: String
        public var userName: String
        public var systemName: String
        public var languageName: String
        public var architecture: String
        public var locale: Locale
        public var timeZone: TimeZone

        public init(
            start: Date, modelName: String, userName: String, systemName: String, languageName: String,
            architecture: String, locale: Locale = .current, timeZone: TimeZone = .current
        ) {
            self.start = start
            self.modelName = modelName
            self.userName = userName
            self.systemName = systemName
            self.languageName = languageName
            self.architecture = architecture
            self.locale = locale
            self.timeZone = timeZone
        }
    }

    public static func resolve(_ prompt: String, in context: Context) -> String {
        guard prompt.contains("{{") else { return prompt }
        var result = prompt
        for variable in PromptVariable.allCases where result.contains(variable.placeholder) {
            result = result.replacingOccurrences(of: variable.placeholder, with: value(of: variable, in: context))
        }
        return result
    }

    static func value(of variable: PromptVariable, in context: Context) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        func format(_ style: Date.FormatStyle) -> String {
            context.start.formatted(style.locale(context.locale))
        }
        let base = Date.FormatStyle(calendar: calendar, timeZone: context.timeZone)
        switch variable {
        case .date:
            return format(base.weekday(.abbreviated).year().month(.defaultDigits).day())
        case .time:
            return format(base.hour().minute())
        case .datetime:
            return format(base.weekday(.abbreviated).year().month(.defaultDigits).day().hour().minute())
        case .username:
            return context.userName
        case .system:
            return context.systemName
        case .language:
            return context.languageName
        case .arch:
            return context.architecture
        case .modelName:
            return context.modelName
        }
    }
}
