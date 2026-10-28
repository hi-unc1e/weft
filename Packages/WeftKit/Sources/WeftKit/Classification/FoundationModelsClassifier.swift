import Foundation
import FoundationModels

/// Classifies activity with Apple's on-device Foundation Models. The category list is
/// user-editable, so the output schema is built at runtime with `DynamicGenerationSchema`.
@available(macOS 26.0, *)
public struct FoundationModelsClassifier: AIClassifying {
    public init() {}

    public func availability() -> AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            // Also what regions without Apple Intelligence may report.
            return .unavailable("Apple Intelligence isn't available on this Mac or in your region.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Apple Intelligence is turned off in System Settings.")
        case .unavailable(.modelNotReady):
            return .unavailable("The on-device model is still downloading.")
        case .unavailable:
            return .unavailable("The on-device model is unavailable.")
        }
    }

    public func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification {
        let candidates = ModelPrompts.candidates(categories)
        let keys = candidates.map(\.key)

        let root = DynamicGenerationSchema(
            name: "ActivityClassification",
            properties: [
                .init(
                    name: "category",
                    description: "The category key that best describes the activity.",
                    schema: DynamicGenerationSchema(name: "CategoryKey", anyOf: keys)
                ),
                .init(
                    name: "confidence",
                    description: "How sure you are. Use low when the app or site could reasonably fit several categories.",
                    schema: DynamicGenerationSchema(name: "Confidence", anyOf: AIConfidence.allCases.map(\.rawValue))
                ),
            ]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])

        let session = LanguageModelSession(instructions: ModelPrompts.classifyInstructions(candidates))
        let response = try await session.respond(
            to: ModelPrompts.classifyPrompt(context), schema: schema, options: GenerationOptions(sampling: .greedy)
        )
        let key = try response.content.value(String.self, forProperty: "category")
        let confidence = try response.content.value(String.self, forProperty: "confidence")
        guard keys.contains(key) else { throw ClassificationError.unknownCategory(key) }
        return AIClassification(categoryKey: key, confidence: AIConfidence(rawValue: confidence) ?? .low)
    }

    public func describeActivity(_ facts: String, language: String) async throws -> String {
        let session = LanguageModelSession(instructions: ModelPrompts.describeInstructions(language: language))
        return try await session.respond(to: facts).content
    }

    public func summarize(_ facts: String) async throws -> String {
        let session = LanguageModelSession(instructions: ModelPrompts.summarizeInstructions)
        return try await session.respond(to: facts).content
    }
}
