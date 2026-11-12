import Foundation

enum CopilotPathSettings {
    static let enableWhenReadyKey = "copilotEnableWhenOllamaReady"
    static let justTurnedOnKey = "copilotJustTurnedOn"
    static let cardDismissedKey = "copilotCardDismissed"

    static func apply(enabled: Bool, ollamaModelReady: Bool, to defaults: UserDefaults = .standard) {
        let kinds = AssistantRoutingSettings.configuredKinds(in: defaults)
        let localOnly = kinds == [.ollama]
        let waiting = enabled && localOnly && !ollamaModelReady
        defaults.set(waiting, forKey: enableWhenReadyKey)
        defaults.set(enabled && !kinds.isEmpty && !waiting, forKey: "copilotEnabled")
        defaults.set(TranscriptionBackend.local.rawValue, forKey: TranscriptionBackend.defaultsKey)
        defaults.set(true, forKey: TranscriptPolisher.onDeviceKey)
    }

    @discardableResult
    static func ollamaModelReady(_ model: String, in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: enableWhenReadyKey),
              AssistantRoutingSettings.enabled(.ollama, defaults: defaults),
              defaults.string(forKey: "copilotOllamaModel") == model else { return false }
        defaults.set(true, forKey: "copilotEnabled")
        defaults.set(false, forKey: enableWhenReadyKey)
        defaults.set(true, forKey: justTurnedOnKey)
        return true
    }
}

enum CopilotStatus: Equatable {
    case on
    case waitingForModel(progress: Double?)
    case finishOllama
    case needsIntegration
    case heldOnDevice
    case off

    static func current(copilotEnabled: Bool, enabledKinds: [CopilotProviderKind], onDeviceOnly: Bool,
                        enableWhenReady: Bool, ollamaPulling: Bool, ollamaProgress: Double?) -> CopilotStatus {
        if enabledKinds.isEmpty { return .needsIntegration }
        if onDeviceOnly && !enabledKinds.contains(.ollama) { return .heldOnDevice }
        if copilotEnabled { return .on }
        if enableWhenReady && enabledKinds.contains(.ollama) {
            return ollamaPulling ? .waitingForModel(progress: ollamaProgress) : .finishOllama
        }
        return .off
    }

    static func showsHomeCard(_ status: CopilotStatus, dismissed: Bool, justTurnedOn: Bool) -> Bool {
        switch status {
        case .on: justTurnedOn
        case .waitingForModel: true
        case .finishOllama, .needsIntegration, .heldOnDevice, .off: !dismissed
        }
    }
}
