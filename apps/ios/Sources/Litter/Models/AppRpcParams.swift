import Foundation

struct AppThreadLaunchConfig: Equatable, Sendable {
    var model: String?
    var approvalPolicy: AppAskForApproval?
    var sandbox: AppSandboxMode?
    var developerInstructions: String?
    var persistExtendedHistory: Bool = true

    func threadStartRequest(cwd: String) -> AppStartThreadRequest {
        AppStartThreadRequest(
            model: model,
            cwd: cwd,
            approvalPolicy: approvalPolicy,
            sandbox: sandbox,
            developerInstructions: developerInstructions,
            persistExtendedHistory: persistExtendedHistory
        )
    }

    func threadResumeRequest(threadId: String, cwdOverride: String?) -> AppResumeThreadRequest {
        AppResumeThreadRequest(
            threadId: threadId,
            model: model,
            cwd: cwdOverride,
            approvalPolicy: approvalPolicy,
            sandbox: sandbox,
            developerInstructions: developerInstructions,
            persistExtendedHistory: persistExtendedHistory
        )
    }

    func threadForkRequest(threadId: String, cwdOverride: String?) -> AppForkThreadRequest {
        AppForkThreadRequest(
            threadId: threadId,
            model: model,
            cwd: cwdOverride,
            approvalPolicy: approvalPolicy,
            sandbox: sandbox,
            developerInstructions: developerInstructions,
            persistExtendedHistory: persistExtendedHistory
        )
    }

    func forkThreadFromMessageRequest(cwdOverride: String?) -> AppForkThreadFromMessageRequest {
        AppForkThreadFromMessageRequest(
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
    var additionalInputs: [AppUserInput]
    var approvalPolicy: AppAskForApproval?
    var sandboxPolicy: AppSandboxPolicy?
    var model: String?
    var effort: ReasoningEffort?
    var serviceTier: ServiceTier?

    func turnStartRequest(threadId: String) -> AppStartTurnRequest {
        var inputs = additionalInputs
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputs.insert(.text(text: text, textElements: []), at: 0)
        }
        return AppStartTurnRequest(
            threadId: threadId,
            input: inputs,
            approvalPolicy: approvalPolicy,
            sandboxPolicy: sandboxPolicy,
            model: model,
            serviceTier: serviceTier,
            effort: effort
        )
    }
}
