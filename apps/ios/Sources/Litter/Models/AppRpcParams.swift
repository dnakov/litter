import Foundation

struct AppThreadLaunchConfig: Equatable, Sendable {
    var model: String?
    var approvalPolicy: AskForApproval?
    var sandbox: SandboxMode?
    var developerInstructions: String?
    var persistExtendedHistory: Bool

    func threadStartParams(cwd: String) -> ThreadStartParams {
        ThreadStartParams(
            model: model,
            modelProvider: nil,
            serviceTier: nil,
            cwd: cwd,
            approvalPolicy: approvalPolicy,
            approvalsReviewer: nil,
            sandbox: sandbox,
            config: nil,
            serviceName: nil,
            baseInstructions: nil,
            developerInstructions: developerInstructions,
            personality: nil,
            ephemeral: nil,
            dynamicTools: nil,
            mockExperimentalField: nil,
            experimentalRawEvents: false,
            persistExtendedHistory: persistExtendedHistory
        )
    }

    func threadResumeParams(threadId: String, cwdOverride: String?) -> ThreadResumeParams {
        ThreadResumeParams(
            threadId: threadId,
            history: nil,
            path: nil,
            model: model,
            modelProvider: nil,
            serviceTier: nil,
            cwd: cwdOverride,
            approvalPolicy: approvalPolicy,
            approvalsReviewer: nil,
            sandbox: sandbox,
            config: nil,
            baseInstructions: nil,
            developerInstructions: developerInstructions,
            personality: nil,
            persistExtendedHistory: persistExtendedHistory
        )
    }

    func threadForkParams(threadId: String, cwdOverride: String?) -> ThreadForkParams {
        ThreadForkParams(
            threadId: threadId,
            path: nil,
            model: model,
            modelProvider: nil,
            serviceTier: nil,
            cwd: cwdOverride,
            approvalPolicy: approvalPolicy,
            approvalsReviewer: nil,
            sandbox: sandbox,
            config: nil,
            baseInstructions: nil,
            developerInstructions: developerInstructions,
            ephemeral: false,
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
            cwd: nil,
            approvalPolicy: approvalPolicy,
            approvalsReviewer: nil,
            sandboxPolicy: sandboxPolicy,
            model: model,
            serviceTier: serviceTier.map(Optional.some),
            effort: effort,
            summary: nil,
            personality: nil,
            outputSchema: nil,
            collaborationMode: nil
        )
    }
}
