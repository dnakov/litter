import Foundation

extension AppServerSnapshot {
    var isConnected: Bool {
        health == .connected
    }

    var isIpcConnected: Bool {
        hasIpc && !isLocal && isConnected
    }

    var connectionModeLabel: String {
        guard !isLocal else { return "local" }
        return isIpcConnected ? "remote · ipc" : "remote"
    }

    var currentConnectionStep: AppConnectionStepSnapshot? {
        guard let progress = connectionProgress else { return nil }
        return progress.steps.first(where: {
            $0.state == .awaitingUserInput || $0.state == .inProgress
        }) ?? progress.steps.last(where: {
            $0.state == .failed || $0.state == .completed
        })
    }

    var connectionProgressLabel: String? {
        guard let step = currentConnectionStep else { return nil }
        switch step.kind {
        case .connectingToSsh:
            return "connecting"
        case .findingCodex:
            return "finding codex"
        case .installingCodex:
            return "installing"
        case .startingAppServer:
            return "starting"
        case .openingTunnel:
            return "tunneling"
        case .connected:
            return "connected"
        }
    }

    var connectionProgressDetail: String? {
        currentConnectionStep?.detail ?? connectionProgress?.terminalMessage
    }
}
