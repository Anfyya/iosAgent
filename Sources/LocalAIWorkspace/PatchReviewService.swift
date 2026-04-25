import Foundation

public enum PatchReviewServiceError: Error, LocalizedError {
    case missingWorkspaceID(UUID)
    case missingProposal(UUID)
    case missingSnapshot(UUID)

    public var errorDescription: String? {
        switch self {
        case let .missingWorkspaceID(id):
            return "Patch proposal \(id.uuidString) is missing a workspace ID."
        case let .missingProposal(id):
            return "Patch proposal not found: \(id.uuidString)"
        case let .missingSnapshot(id):
            return "Snapshot not found: \(id.uuidString)"
        }
    }
}

public struct PatchReviewService: Sendable {
    public let patchStore: PatchStore
    public let patchEngine: PatchEngine
    public let workspaceManager: WorkspaceManager
    public let permissionManager: PermissionManager
    public let snapshotStore: SnapshotStore?

    public init(
        patchStore: PatchStore,
        patchEngine: PatchEngine = PatchEngine(),
        workspaceManager: WorkspaceManager,
        permissionManager: PermissionManager,
        snapshotStore: SnapshotStore? = nil
    ) {
        self.patchStore = patchStore
        self.patchEngine = patchEngine
        self.workspaceManager = workspaceManager
        self.permissionManager = permissionManager
        self.snapshotStore = snapshotStore
    }

    public func listPending(workspaceID: UUID) throws -> [PatchProposal] {
        try patchStore.list(workspaceID: workspaceID).filter { $0.status == .pendingReview }
    }

    @discardableResult
    public func apply(proposalID: UUID, confirmedByUser: Bool) throws -> PatchProposal {
        guard var proposal = try patchStore.proposal(id: proposalID) else {
            throw PatchReviewServiceError.missingProposal(proposalID)
        }
        guard let workspaceID = proposal.workspaceID else {
            throw PatchReviewServiceError.missingWorkspaceID(proposalID)
        }

        let workspace = try workspaceManager.loadWorkspace(id: workspaceID)
        let workspaceFS = try workspaceManager.workspaceFS(for: workspace)
        let impact = ToolImpact(
            changedFiles: proposal.changedFiles,
            changedLines: proposal.changedLines,
            touchedPaths: proposal.changes.flatMap { [Optional($0.path), $0.newPath].compactMap { $0 } },
            touchesProtectedPath: proposal.changes.flatMap { [Optional($0.path), $0.newPath].compactMap { $0 } }.contains {
                $0.hasPrefix(".mobiledev") || $0.hasPrefix(".github/workflows")
            },
            isDestructive: proposal.changes.contains { $0.operation == .delete || $0.operation == .rename }
        )
        let decision = permissionManager.decide(
            for: ToolCall(name: "propose_patch", arguments: [:]),
            impact: impact,
            currentBranch: workspace.currentBranch
        )

        do {
            let applied = try patchEngine.apply(
                proposal: proposal,
                workspaceID: workspaceID,
                workspaceFS: workspaceFS,
                options: PatchApplyOptions(
                    allowProtectedPaths: confirmedByUser,
                    confirmedByUser: confirmedByUser,
                    permissionDecision: decision
                )
            )
            proposal.status = .applied
            proposal.snapshotID = applied.snapshot.id
            proposal.applyResult = "Applied \(applied.appliedFiles.count) file(s)."
            proposal.errorMessage = nil
            try snapshotStore?.save(applied.snapshot)
            try patchStore.update(proposal)
            return proposal
        } catch {
            proposal.status = .failed
            proposal.errorMessage = error.localizedDescription
            try patchStore.update(proposal)
            throw error
        }
    }

    @discardableResult
    public func reject(proposalID: UUID) throws -> PatchProposal {
        guard var proposal = try patchStore.proposal(id: proposalID) else {
            throw PatchReviewServiceError.missingProposal(proposalID)
        }
        proposal.status = .rejected
        proposal.errorMessage = nil
        try patchStore.update(proposal)
        return proposal
    }

    @discardableResult
    public func markFailed(proposalID: UUID, error: String) throws -> PatchProposal {
        guard var proposal = try patchStore.proposal(id: proposalID) else {
            throw PatchReviewServiceError.missingProposal(proposalID)
        }
        proposal.status = .failed
        proposal.errorMessage = error
        try patchStore.update(proposal)
        return proposal
    }

    public func revise(proposalID: UUID, instruction: String) throws {
        guard var proposal = try patchStore.proposal(id: proposalID) else {
            throw PatchReviewServiceError.missingProposal(proposalID)
        }
        proposal.applyResult = """
        Revision requested:
        \(instruction)

        Re-open the chat with this patch title, reason, and diff context to generate a revised proposal.
        """
        try patchStore.update(proposal)
    }

    @discardableResult
    public func restoreSnapshot(snapshotID: UUID, workspaceID: UUID, confirmedByUser: Bool) throws -> SnapshotRecord {
        guard let snapshot = try snapshotStore?.snapshot(id: snapshotID) else {
            throw PatchReviewServiceError.missingSnapshot(snapshotID)
        }
        let workspace = try workspaceManager.loadWorkspace(id: workspaceID)
        let workspaceFS = try workspaceManager.workspaceFS(for: workspace)
        try patchEngine.restore(
            snapshot: snapshot,
            workspaceFS: workspaceFS,
            options: PatchApplyOptions(
                allowProtectedPaths: confirmedByUser,
                confirmedByUser: confirmedByUser,
                permissionDecision: PermissionDecision(permission: .ask, reason: "Snapshot restore approved by user.")
            )
        )
        return snapshot
    }
}
