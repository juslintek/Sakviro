import Foundation

/// One screen of the setup sheet. Raw values are what `onboardingStepName`
/// stores, so renaming a case strands saved progress.
enum OnboardingStep: String, CaseIterable {
    case welcome, permissions, meetCopilot, copilotPath, speechModel, copilotSetup, automatic, aiApps, ready
}

/// Raw values retained for saved onboarding progress from earlier versions.
enum CopilotPath: String, CaseIterable {
    case `private`, balanced, cloud, cli, later
    static let defaultsKey = "onboardingCopilotPath"
}

/// The full first-run tour, or the short "Set up Copilot" one from Home or
/// Settings.
enum OnboardingMode: String {
    case full, copilot
    static let defaultsKey = "onboardingMode"
}

enum OnboardingFlow {
    static let stepKey = "onboardingStepName"
    /// The old Int index (0 welcome … 4 ready), read once and removed.
    static let legacyStepKey = "onboardingStep"

    static func steps(mode: OnboardingMode, path: CopilotPath?, includesOllama: Bool = false) -> [OnboardingStep] {
        let setup: [OnboardingStep] = (path == .private || includesOllama) ? [.copilotSetup] : []
        if mode == .copilot { return [.meetCopilot, .copilotPath] + setup + [.ready] }
        let aiApps: [OnboardingStep] = path == .private ? [] : [.aiApps]
        return [.welcome, .permissions, .meetCopilot, .copilotPath, .speechModel] + setup + [.automatic] + aiApps + [.ready]
    }

    /// The step `offset` away, clamped to the list.
    static func step(_ offset: Int, from step: OnboardingStep, in steps: [OnboardingStep]) -> OnboardingStep {
        let index = steps.firstIndex(of: resolve(step, in: steps))! + offset
        return steps[min(max(index, 0), steps.count - 1)]
    }

    /// A saved step that no longer belongs to the list (the path changed
    /// under it) lands on the path choice.
    static func resolve(_ step: OnboardingStep, in steps: [OnboardingStep]) -> OnboardingStep {
        if steps.contains(step) { return step }
        return steps.contains(.copilotPath) ? .copilotPath : steps[0]
    }

    /// Moves the old Int step to a name, once. Anyone past permissions lands
    /// on Meet Copilot, so nobody mid-tour during an update skips it.
    static func migrateLegacyStep(in defaults: UserDefaults) {
        guard defaults.string(forKey: stepKey) == nil,
              let old = defaults.object(forKey: legacyStepKey) as? Int else { return }
        let step: OnboardingStep = old <= 0 ? .welcome : old == 1 ? .permissions : old >= 4 ? .ready : .meetCopilot
        defaults.set(step.rawValue, forKey: stepKey)
        defaults.removeObject(forKey: legacyStepKey)
    }
}

/// Defaults that fit this Mac's memory.
enum MachineFit {
    static func memoryGB(_ bytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        Int((Double(bytes) / 1_073_741_824).rounded())
    }

    private static func isLarge(_ memoryGB: Int) -> Bool { memoryGB >= 12 }

    static func whisperModel(memoryGB: Int) -> String { isLarge(memoryGB) ? "large-v3-turbo" : "base" }
    static func ollamaModel(memoryGB: Int) -> String { isLarge(memoryGB) ? "gemma3:4b" : "llama3.2:3b" }
}
