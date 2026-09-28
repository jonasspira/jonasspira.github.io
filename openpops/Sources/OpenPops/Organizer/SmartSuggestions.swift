import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional app suggestions from Apple Intelligence's on-device model (macOS 26 or later,
/// on Macs that support it). Nothing leaves the Mac.
enum SmartSuggestions {
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Apple Intelligence isn't available on this Mac." }
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Returns names picked from `candidates`, best first.
    static func suggest(popName: String, current: [String], candidates: [String]) async throws -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { throw Failure.unavailable }
            let session = LanguageModelSession(instructions: """
                You help organize Mac apps into folders. Answer only with app names copied exactly \
                from the candidate list, one per line, with no other text.
                """)
            let shortList = Array(candidates.prefix(150))
            let prompt = """
                Folder name: \(popName)
                Apps already in the folder: \(current.isEmpty ? "none" : current.joined(separator: ", "))
                Candidate apps installed on this Mac: \(shortList.joined(separator: ", "))
                List up to 8 candidate apps that belong in this folder, best first.
                """
            let response = try await session.respond(to: prompt)
            let allowed = Set(shortList.map { $0.lowercased() })
            let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-•*.0123456789)\""))
            var seen = Set<String>()
            return response.content
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: trim) }
                .filter { allowed.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
        }
        #endif
        throw Failure.unavailable
    }
}
