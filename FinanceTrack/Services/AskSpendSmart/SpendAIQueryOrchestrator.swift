import Foundation

/// GENERALIZED ORCHESTRATOR PHASE — the injectable seam between "how a plan gets produced"/"how a
/// verified result gets worded" and the orchestration logic itself, so
/// `SpendAIQueryOrchestrator.handle(...)` is testable with zero `FoundationModels` dependency and
/// without ever invoking the real on-device model. Production conformers
/// (`AppleFoundationModelQueryPlanner`/`AppleFoundationModelWordingService`) live in
/// `AskSpendSmartToolProvider.swift` (`@available(iOS 26.0, *)`); tests use fakes conforming to
/// these same two protocols.
protocol SpendAIQueryPlanning: Sendable {
    /// Returns `nil` when the question is confidently NOT about the user's own SpendSmart data
    /// (a greeting, small talk, something with no matching domain at all) — safe to answer
    /// directly and ungrounded in that case. A genuine PLANNING FAILURE (context size, guardrail,
    /// etc.) must throw, never silently return `nil` — `nil` and "failed to plan" are not the same
    /// thing, and conflating them would let a real factual question slip through ungrounded.
    func makePlan(for question: String, now: Date, followUp: SpendAIFollowUpContext?) async throws -> SpendAIQueryPlan?
}

protocol SpendAIWordingGenerating: Sendable {
    /// Turns an already-verified `SpendAIQueryResult` into a natural conversational reply. Must
    /// never be given raw source data (transactions/accounts) — only the already-computed,
    /// already-Sendable result, per Phase I's own "do not send the complete database" requirement.
    func word(question: String, result: SpendAIQueryResult) async throws -> String
    /// For the genuinely non-factual case (`makePlan` returned `nil`) — an ordinary conversational
    /// reply with no grounding data, since there is nothing about SpendSmart's own data to verify.
    func plainReply(to question: String) async throws -> String
}

/// PHASE H's own central guarantee, expressed as one function: a factual SpendSmart-data question
/// NEVER reaches an ungrounded `session.respond(originalQuestion)` — it either resolves to a
/// `SpendAIQueryPlan` (via the local router FIRST, then Apple's model) and executes through
/// `SpendAIDataRegistry` before any wording happens, or it is confidently classified as non-factual
/// by the planner and answered directly. There is no third path.
enum SpendAIQueryOrchestrator {
    struct Outcome: Sendable, Equatable {
        let answer: String
        let followUp: SpendAIFollowUpContext?
    }

    static func handle(
        question: String,
        context: AskSpendSmartToolContext,
        now: Date,
        followUp: SpendAIFollowUpContext?,
        planner: any SpendAIQueryPlanning,
        wording: any SpendAIWordingGenerating
    ) async throws -> Outcome {
        // 1. High-confidence local classification FIRST (Phase D's own preferred order) — fast,
        // free, and doesn't depend on the model's own tool-selection/planning judgment at all.
        if let plan = AskSpendSmartFallbackRouter.routeGeneralized(question, now: now, followUp: followUp) {
            return execute(plan, context: context)
        }

        // 2. Otherwise, ask Apple's on-device model to produce a validated typed plan.
        guard let plan = try await planner.makePlan(for: question, now: now, followUp: followUp) else {
            // Confidently non-factual — safe to answer directly, ungrounded (Phase H's own
            // explicit carve-out: "general non-data conversation... only if it does not make
            // claims about current SpendSmart data"). This is the ONLY remaining use of `wording`
            // — see `execute(_:context:)`'s own header for why a VERIFIED result never reaches it.
            let reply = try await wording.plainReply(to: question)
            return Outcome(answer: reply, followUp: followUp)
        }
        return execute(plan, context: context)
    }

    private static func execute(_ plan: SpendAIQueryPlan, context: AskSpendSmartToolContext) -> Outcome {
        guard SpendAIQueryPlanValidator.validate(plan) else {
            return Outcome(answer: "I can't quite tell what to look up for that yet — could you rephrase it?", followUp: nil)
        }

        // THE REGISTRY EXECUTES HERE — before any wording call, for every recognized domain,
        // unconditionally. This line is what Phase H's guarantee actually is, in code.
        let result = SpendAIDataRegistry.execute(plan, using: context)
        let newFollowUp = SpendAIFollowUpContext(domain: plan.domain, dateRange: plan.dateRange, dateRangeLabel: plan.dateRangeLabel)

        // FINANCIAL DATA CORRECTNESS PHASE — root-caused Scott's reported "You've spent $720.76
        // this week, which is within your $500.00 limit. You still have $1,220.76 left." bug to
        // EXACTLY this call: the deterministic result was correct (over budget by $220.76, per
        // `BudgetCalculator.remaining`/`status` — verified by direct audit, not assumed), but
        // Apple's wording pass, asked to rephrase "over budget by $220.76," independently
        // recomputed its own (wrong) arithmetic — $500.00 − (−$720.76) = $1,220.76, and inverted
        // the over/under status — despite an explicit "do not change or invent any number"
        // instruction. On-device guided/plain generation has no mechanism to GUARANTEE arithmetic
        // fidelity, so per this feature's own "AUTHORITATIVE SPENDAI RESPONSE" requirement, Option
        // A (the safest of the two offered): every verified `SpendAIQueryResult` is now answered
        // with `SpendAIResultFormatter`'s OWN deterministic sentence directly, unconditionally —
        // Apple's model is NEVER given the chance to alter a figure, a sign, or an over/under
        // status once the registry has produced a verified result. `wording` (still injected,
        // still exercised by tests) is now used ONLY for the genuinely non-factual `plainReply`
        // path in `handle(...)` above, where there is no verified figure to protect.
        return Outcome(answer: SpendAIResultFormatter.format(result), followUp: newFollowUp)
    }
}
