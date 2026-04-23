import Foundation

extension AppSnapshotRecord {
    mutating func applyLocalThreadTitle(_ title: String, for key: ThreadKey) -> Bool {
        var mutated = false

        if let threadIndex = threads.firstIndex(where: { $0.key == key }),
           threads[threadIndex].info.title != title {
            threads[threadIndex].info.title = title
            mutated = true
        }

        if let summaryIndex = sessionSummaries.firstIndex(where: { $0.key == key }),
           sessionSummaries[summaryIndex].title != title {
            sessionSummaries[summaryIndex].title = title
            mutated = true
        }

        return mutated
    }

    func threadHasTrackedTurn(for key: ThreadKey) -> Bool {
        guard let thread = threadSnapshot(for: key) else { return false }
        return threadHasTrackedTurn(thread)
    }

    private func threadHasTrackedTurn(_ thread: AppThreadSnapshot) -> Bool {
        if thread.hasActiveTurn {
            return true
        }

        let key = thread.key
        if pendingApprovals.contains(where: {
            $0.serverId == key.serverId && $0.threadId == key.threadId
        }) {
            return true
        }

        return pendingUserInputs.contains(where: {
            $0.serverId == key.serverId && $0.threadId == key.threadId
        })
    }

    var threadsWithTrackedTurns: [AppThreadSnapshot] {
        threads.filter { threadHasTrackedTurn($0) }
    }
}
