import Foundation

/// The version as Spot Chat names it: "0.1.0 alpha 161" for a build CI packaged, whose build number is the
/// run that made it, and "0.1.0" for a local build, whose build number is 0.
public enum AppVersion {
    public static var display: String {
        display(info: Bundle.main.infoDictionary ?? [:])
    }

    public static func display(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        guard let number = Int(build), number > 0 else { return version }
        return "\(version) alpha \(number)"
    }
}
