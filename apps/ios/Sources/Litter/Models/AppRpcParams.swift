import Foundation

struct AppThreadLaunchConfig: Equatable, Sendable {
    var model: String?
    var approvalPolicy: AskForApproval?
    var sandbox: SandboxMode?
    var developerInstructions: String?
    var persistExtendedHistory: Bool = true

    func threadStartParams(cwd: String) -> ThreadStartParams {
        ThreadStartParams(
            model: model,
            cwd: cwd,
            approvalPolicy: approvalPolicy,
            sandbox: sandbox,
            developerInstructions: developerInstructions,
            persistExtendedHistory: persistExtendedHistory
        )
    }

    func threadResumeParams(threadId: String, cwdOverride: String?) -> ThreadResumeParams {
        ThreadResumeParams(
            threadId: threadId,
            model: model,
            cwd: cwdOverride,
            approvalPolicy: approvalPolicy,
            sandbox: sandbox,
            developerInstructions: developerInstructions,
            persistExtendedHistory: persistExtendedHistory
        )
    }

    func threadForkParams(threadId: String, cwdOverride: String?) -> ThreadForkParams {
        ThreadForkParams(
            threadId: threadId,
            model: model,
            cwd: cwdOverride,
            approvalPolicy: approvalPolicy,
            sandbox: sandbox,
            developerInstructions: developerInstructions,
            persistExtendedHistory: persistExtendedHistory
        )
    }
}

struct AppComposerPayload: Equatable, Sendable {
    var text: String
    var additionalInputs: [UserInput]
    var approvalPolicy: AskForApproval?
    var sandboxPolicy: SandboxPolicy?
    var model: String?
    var effort: ReasoningEffort?
    var serviceTier: ServiceTier?

    func turnStartParams(threadId: String) -> TurnStartParams {
        var inputs = additionalInputs
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputs.insert(.text(text: text, textElements: []), at: 0)
        }
        return TurnStartParams(
            threadId: threadId,
            input: inputs,
            approvalPolicy: approvalPolicy,
            sandboxPolicy: sandboxPolicy,
            model: model,
            serviceTier: serviceTier.map(Optional.some),
            effort: effort
        )
    }
}
