import Foundation

public struct CacheEngine: Sendable {
    public init() {}

    public func makeRecord(provider: ProviderProfile, model: ModelProfile, snapshot: ContextSnapshot, usage: AIUsage, previous: CacheRecord?) -> CacheRecord {
        let promptTokens = usage.inputTokens ?? snapshot.staticTokenCount + snapshot.dynamicTokenCount
        let completionTokens = usage.outputTokens ?? 0
        let cachedTokens = usage.cachedInputTokens ?? 0
        let cacheMissTokens = usage.cacheMissInputTokens ?? max(promptTokens - cachedTokens, 0)
        let hitRate = promptTokens == 0 ? 0 : Double(cachedTokens) / Double(promptTokens)
        let missReasons = compare(previous: previous, currentSnapshot: snapshot, provider: provider, model: model)
        let estimatedCost = Double(promptTokens + completionTokens) * 0.000002
        let estimatedSavedCost = Double(cachedTokens) * 0.000002

        return CacheRecord(
            provider: provider.name,
            model: model.id,
            apiStyle: provider.apiStyle,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cachedTokens: cachedTokens,
            cacheMissTokens: cacheMissTokens,
            cacheHitRate: hitRate,
            prefixHash: snapshot.prefixHash,
            repoSnapshotHash: snapshot.repoSnapshotHash,
            toolSchemaHash: snapshot.blocks.first(where: { $0.type == .toolSchema })?.contentHash ?? "",
            projectRulesHash: snapshot.blocks.first(where: { $0.type == .projectRules })?.contentHash ?? "",
            fileTreeHash: snapshot.blocks.first(where: { $0.type == .fileTree })?.contentHash ?? "",
            symbolIndexHash: snapshot.blocks.first(where: { $0.type == .repoMap })?.contentHash ?? "",
            staticPrefixTokenCount: snapshot.staticTokenCount,
            dynamicTokenCount: snapshot.dynamicTokenCount,
            estimatedCost: estimatedCost,
            estimatedSavedCost: estimatedSavedCost,
            latencyMs: usage.latencyMs ?? 0,
            timeToFirstTokenMs: usage.timeToFirstTokenMs ?? 0,
            cacheStrategy: model.cacheStrategy,
            missReasons: missReasons
        )
    }

    private func compare(previous: CacheRecord?, currentSnapshot: ContextSnapshot, provider: ProviderProfile, model: ModelProfile) -> [CacheMissReason] {
        guard let previous else { return [] }
        var reasons: [CacheMissReason] = []

        if previous.prefixHash != currentSnapshot.prefixHash {
            reasons.append(.prefixHashChanged)
        }
        if previous.repoSnapshotHash != currentSnapshot.repoSnapshotHash {
            reasons.append(.fileTreeChanged)
        }
        if previous.model != model.id {
            reasons.append(.modelChanged)
        }
        if previous.provider != provider.name {
            reasons.append(.providerProfileChanged)
        }
        if previous.toolSchemaHash != currentSnapshot.blocks.first(where: { $0.type == .toolSchema })?.contentHash {
            reasons.append(.toolSchemaChanged)
        }
        if previous.projectRulesHash != currentSnapshot.blocks.first(where: { $0.type == .projectRules })?.contentHash {
            reasons.append(.projectRulesChanged)
        }

        return reasons
    }
}
