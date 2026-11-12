import SwiftUI

@MainActor
@Observable
final class OnboardingModel {
    private let defaults: UserDefaults
    let mode: OnboardingMode
    private(set) var step: OnboardingStep
    var enabledIntegrations: String {
        didSet {
            defaults.set(enabledIntegrations, forKey: AssistantRoutingSettings.enabledKey)
            let kinds = AssistantRoutingSettings.configuredKinds(in: defaults)
            path = kinds.isEmpty ? .later : kinds == [.ollama] ? .private : .cli
        }
    }
    var path: CopilotPath? {
        didSet { defaults.set(path?.rawValue, forKey: CopilotPath.defaultsKey) }
    }
    var copilotOn: Bool
    var ollamaModel: String
    var ollamaModelReady = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        OnboardingFlow.migrateLegacyStep(in: defaults)
        AssistantRoutingSettings.migrate(in: defaults)
        mode = OnboardingMode(rawValue: defaults.string(forKey: OnboardingMode.defaultsKey) ?? "") ?? .full
        enabledIntegrations = defaults.string(forKey: AssistantRoutingSettings.enabledKey) ?? ""
        let kinds = AssistantRoutingSettings.configuredKinds(in: defaults)
        let savedPath: CopilotPath? = kinds.isEmpty ? nil : kinds == [.ollama] ? .private : .cli
        path = savedPath
        copilotOn = defaults.object(forKey: "copilotEnabled") as? Bool ?? true
        ollamaModel = defaults.string(forKey: "copilotOllamaModel")
            ?? MachineFit.ollamaModel(memoryGB: MachineFit.memoryGB())
        let steps = OnboardingFlow.steps(mode: mode, path: savedPath, includesOllama: kinds.contains(.ollama))
        let stored = OnboardingStep(rawValue: defaults.string(forKey: OnboardingFlow.stepKey) ?? "")
        step = OnboardingFlow.resolve(stored ?? steps[0], in: steps)
    }

    var steps: [OnboardingStep] { OnboardingFlow.steps(mode: mode, path: path, includesOllama: AssistantRoutingSettings.enabled(.ollama, defaults: defaults)) }
    var isFirst: Bool { step == steps.first }
    var isLast: Bool { step == steps.last }

    func move(_ offset: Int) {
        if offset > 0, step == .copilotPath || step == .copilotSetup { applyChoices() }
        go(to: OnboardingFlow.step(offset, from: step, in: steps))
    }

    func go(to newStep: OnboardingStep) {
        step = newStep
        defaults.set(newStep.rawValue, forKey: OnboardingFlow.stepKey)
    }

    func decideLater() {
        copilotOn = false
        applyChoices()
        move(1)
    }

    func applyChoices() {
        defaults.set(ollamaModel, forKey: "copilotOllamaModel")
        CopilotPathSettings.apply(enabled: copilotOn, ollamaModelReady: ollamaModelReady, to: defaults)
    }

    func finish() {
        defaults.removeObject(forKey: OnboardingFlow.stepKey)
        defaults.set(OnboardingMode.full.rawValue, forKey: OnboardingMode.defaultsKey)
    }
}
