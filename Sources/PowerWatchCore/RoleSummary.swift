import Foundation

public struct RoleSummary: Sendable {
    public enum Source: Sendable { case generated, builtIn }
    public var text: String
    public var source: Source
    public var notice: String?
}

/// A generation failure never removes the local, deterministic role explanation.
@MainActor public enum RoleSummaries {
    public static func explain(roles: [String], digest: String? = nil, unavailableReason: String? = nil,
                               generate: ([String]) async throws -> String) async throws -> RoleSummary {
        try Task.checkCancellation()
        let roles = Array(Set(roles)).sorted()
        let maxLength = digest == nil ? 600 : 900
        if let unavailableReason {
            return fallback(roles, digest: digest, notice: unavailableReason + " Showing built-in descriptions.")
        }
        do {
            try Task.checkCancellation()
            let text = try await generate(roles).trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard !text.isEmpty, text.count <= maxLength,
                  !text.contains(where: { $0.isNewline }), !text.contains("**"), !text.contains("```"), !text.hasPrefix("#"),
                  text.last.map({ ".!?".contains($0) }) == true else {
                return fallback(roles, digest: digest, notice: "Apple Intelligence returned an unusable explanation. Showing built-in descriptions.")
            }
            return RoleSummary(text: text, source: .generated, notice: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return fallback(roles, digest: digest, notice: "Apple Intelligence couldn't complete this explanation. Showing built-in descriptions.")
        }
    }
    private static func fallback(_ roles: [String], digest: String?, notice: String) -> RoleSummary {
        let descriptions = Array(Set(roles.map(description))).sorted()
        var parts = descriptions.isEmpty ? ["No recognized role information is available for this selection."] : [descriptions.joined(separator: "\n\n")]
        if let digest = digest?.trimmingCharacters(in: .whitespacesAndNewlines), !digest.isEmpty { parts.append(digest) }
        return RoleSummary(text: parts.joined(separator: "\n\n"), source: .builtIn, notice: notice)
    }
    private static func description(_ role: String) -> String {
        switch role {
        case "Web renderer": return "Web renderers display web content and run page code. Monitoring metadata does not identify their tab or frame."
        case "Browser graphics / GPU process": return "The browser graphics process coordinates graphics work and compositing for browser content."
        case "Browser network service": return "The browser network service handles network connections and requests for browser content."
        case "Browser audio service": return "The browser audio service handles audio for browser content."
        case "Browser storage service": return "The browser storage service manages storage used by browser content."
        case "Browser crash reporting": return "Browser crash reporting collects crash information. Its role does not indicate that a crash occurred."
        case "Browser utility process": return "A browser utility process handles a supporting browser service; its specific service is unavailable."
        case "App helper": return "App helpers perform supporting work for an app. Their names and observed launch context provide further details."
        case "Application process": return "An application process runs part of an installed app. Its specific current task is unavailable."
        case "Interpreter", "Script", "Python module": return "An interpreter runs a script or module. Only the filtered launch metadata identifies the observed script or module; its purpose is not inferred."
        case "macOS service": return "A macOS service performs system work. No verified description of this particular service is available."
        case "Executable": return "An executable is running locally. Its specific purpose is unidentified; inspect the observed name, path and owner."
        case "macOS's shared display service. It combines app windows into the desktop image, manages windows, and routes interface events.",
             "Manages sleep, wake and power behavior for macOS.",
             "Builds and searches the Spotlight index of files and metadata.",
             "Coordinates iCloud data synchronization.",
             "Provides shared audio playback and recording services.",
             "Starts and supervises macOS services and background jobs.": return role
        default:
            return "This process role has no built-in explanation. Its observed identity and launch metadata remain available above."
        }
    }
}
