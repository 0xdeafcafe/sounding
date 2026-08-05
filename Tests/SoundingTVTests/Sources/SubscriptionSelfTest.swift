import Foundation
@testable import SoundingTV

#if DEBUG

enum SubscriptionSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[SubscriptionTest] \(status)"] + lines.map { "[SubscriptionTest]   \($0)" }
                + failures.map { "[SubscriptionTest]   ✗ \($0)" }).joined(separator: "\n")
        }
    }

    static func run() -> Report {
        var report = Report()
        resolveTierCases(&report)
        resolveShapeCases(&report)
        creatorPlanCases(&report)
        unknownReasonCases(&report)
        rawDescriptionCases(&report)
        classifyCases(&report)
        return report
    }

    private static func sub(_ productId: String?) -> ConsumerSubscription {
        ConsumerSubscription(product: productId.map(SubscriptionProductRef.init(id:)))
    }

    private static func expectTier(
        _ report: inout Report,
        _ name: String,
        consumerRows: [ConsumerSubscription]? = nil,
        consumerSingle: ConsumerSubscription? = nil,
        creatorRows: [CreatorSubscription]? = nil,
        creatorSingle: CreatorSubscription? = nil,
        resolves tier: SubscriptionService.Tier
    ) {
        let got = SubscriptionService.resolve(
            consumerRows: consumerRows,
            consumerSingle: consumerSingle,
            creatorRows: creatorRows,
            creatorSingle: creatorSingle
        ).tier
        if got == tier {
            report.lines.append("resolve: \(name) → \(tier)")
        } else {
            report.failures.append("resolve: \(name): expected \(tier), got \(got)")
        }
    }

    private static func resolveTierCases(_ report: inout Report) {
        func expect(_ name: String, _ subscriptions: [ConsumerSubscription]?, resolves tier: SubscriptionService.Tier) {
            let got = SubscriptionService.resolveTier(from: subscriptions)
            if got == tier {
                report.lines.append("resolveTier: \(name) → \(tier)")
            } else {
                report.failures.append("resolveTier: \(name): expected \(tier), got \(got)")
            }
        }

        expect("missing key", nil, resolves: .unknown)
        expect("empty array", [], resolves: .free)
        expect("Go+", [sub("consumer-high-tier")], resolves: .goPlus)
        expect("Go", [sub("consumer-mid-tier")], resolves: .go)
        expect("Creator Pro filed under the consumer key", [sub("creator-pro")], resolves: .creatorPro)
        expect("explicit free product id", [sub("free")], resolves: .free)
        expect("unrecognised product id", [sub("consumer-ultra-mega-tier")], resolves: .unknown)
        expect("null product", [sub(nil)], resolves: .unknown)
        expect("Go+ wins over Go", [sub("consumer-mid-tier"), sub("consumer-high-tier")], resolves: .goPlus)
    }

    private static func resolveShapeCases(_ report: inout Report) {
        expectTier(
            &report, "singular key only (the captured Go+ shape)",
            consumerRows: nil, consumerSingle: sub("consumer-high-tier"),
            resolves: .goPlus
        )
        expectTier(
            &report, "singular Go only",
            consumerRows: nil, consumerSingle: sub("consumer-mid-tier"),
            resolves: .go
        )
        expectTier(
            &report, "plural null + singular free",
            consumerRows: nil, consumerSingle: sub("free"),
            resolves: .free
        )
        expectTier(
            &report, "plural empty but singular populated — singular still counts",
            consumerRows: [], consumerSingle: sub("consumer-high-tier"),
            resolves: .goPlus
        )
        expectTier(
            &report, "both spellings agree",
            consumerRows: [sub("consumer-high-tier")], consumerSingle: sub("consumer-high-tier"),
            resolves: .goPlus
        )
        expectTier(
            &report, "spellings disagree — higher privilege wins",
            consumerRows: [sub("free")], consumerSingle: sub("consumer-high-tier"),
            resolves: .goPlus
        )
        expectTier(
            &report, "truly empty consumer array stays authoritative free",
            consumerRows: [], consumerSingle: nil,
            resolves: .free
        )
    }

    private static func creatorPlanCases(_ report: inout Report) {
        expectTier(
            &report, "creator-pro-unlimited (Next Pro) via plural",
            creatorRows: [sub("creator-pro-unlimited")],
            resolves: .creatorPro
        )
        expectTier(
            &report, "creator-pro-unlimited via singular",
            creatorSingle: sub("creator-pro-unlimited"),
            resolves: .creatorPro
        )
        expectTier(
            &report, "creator-mid-tier (legacy Pro)",
            creatorRows: [sub("creator-mid-tier")],
            resolves: .creatorPro
        )
        expectTier(
            &report, "creator-creator-mid-tier (observed quirk)",
            creatorRows: [sub("creator-creator-mid-tier")],
            resolves: .creatorPro
        )
        expectTier(
            &report, "legacy creator-pro still recognised",
            creatorRows: [sub("creator-pro")],
            resolves: .creatorPro
        )
        expectTier(
            &report, "unseen future creator id caught by prefix (e.g. Artist Pro)",
            creatorRows: [sub("creator-artist-pro-2027")],
            resolves: .creatorPro
        )
        expectTier(
            &report, "free consumer + Next Pro creator → creatorPro, not goPlus",
            consumerRows: [sub("free")], creatorRows: [sub("creator-pro-unlimited")],
            resolves: .creatorPro
        )
        expectTier(
            &report, "Go+ consumer + creator plan → goPlus",
            consumerRows: [sub("consumer-high-tier")], creatorRows: [sub("creator-pro-unlimited")],
            resolves: .goPlus
        )
        expectTier(
            &report, "consumer- prefix must NOT promote to Go+",
            consumerRows: [sub("consumer-high-tier-expired")],
            resolves: .unknown
        )
        expectTier(
            &report, "creator- prefix must NOT promote to Go+",
            creatorRows: [sub("creator-high-tier")],
            resolves: .creatorPro
        )
    }

    private static func unknownReasonCases(_ report: inout Report) {
        func expect(
            _ name: String,
            consumerRows: [ConsumerSubscription]? = nil,
            consumerSingle: ConsumerSubscription? = nil,
            creatorRows: [CreatorSubscription]? = nil,
            reason: SubscriptionService.UnknownReason?
        ) {
            let got = SubscriptionService.resolve(
                consumerRows: consumerRows,
                consumerSingle: consumerSingle,
                creatorRows: creatorRows
            ).unknownReason
            if got == reason {
                report.lines.append("reason: \(name) → \(String(describing: got))")
            } else {
                report.failures.append(
                    "reason: \(name): expected \(String(describing: reason)), got \(String(describing: got))"
                )
            }
        }

        expect("all keys absent", reason: .payloadUnreadable)
        expect("row with null product", consumerRows: [sub(nil)], reason: .payloadUnreadable)
        expect(
            "unrecognised consumer id carries the id",
            consumerRows: [sub("consumer-ultra-mega-tier")],
            reason: .unrecognisedProductIDs(["consumer-ultra-mega-tier"])
        )
        expect(
            "unrecognised ids are sorted and de-duplicated",
            consumerRows: [sub("zeta-plan"), sub("alpha-plan"), sub("zeta-plan")],
            reason: .unrecognisedProductIDs(["alpha-plan", "zeta-plan"])
        )
        expect("recognised Go+ has no reason", consumerRows: [sub("consumer-high-tier")], reason: nil)
        expect("authoritative free has no reason", consumerRows: [], reason: nil)
    }

    private static func rawDescriptionCases(_ report: inout Report) {
        func expect(_ name: String, _ value: JSONValue, renders expected: String) {
            let got = value.diagnosticDescription
            if got == expected {
                report.lines.append("raw: \(name) → \(got)")
            } else {
                report.failures.append("raw: \(name): expected \(expected), got \(got)")
            }
        }

        expect("null", .null, renders: "null")
        expect("integer renders without decimal point", .number(3), renders: "3")
        expect(
            "the captured Go+ shape",
            .object(["product": .object(["id": .string("consumer-high-tier")])]),
            renders: "{product: {id: \"consumer-high-tier\"}}"
        )
        expect(
            "keys are sorted for stable comparison",
            .object(["z": .bool(true), "a": .bool(false)]),
            renders: "{a: false, z: true}"
        )
        expect(
            "an unmodelled sibling field survives into the diagnostic",
            .object([
                "product": .object(["id": .string("creator-pro-unlimited")]),
                "recurring": .bool(true),
            ]),
            renders: "{product: {id: \"creator-pro-unlimited\"}, recurring: true}"
        )
        expect(
            "credential-shaped keys are redacted",
            .object([
                "product": .object(["id": .string("free")]),
                "access_token": .string("would-be-a-leak"),
                "oauth_token": .string("would-be-a-leak"),
            ]),
            renders: "{access_token: <redacted>, oauth_token: <redacted>, product: {id: \"free\"}}"
        )
    }

    private static func classifyCases(_ report: inout Report) {
        let now = Date()
        let grace: TimeInterval = 10 * 24 * 3600

        func expect(
            _ name: String,
            lastTier: SubscriptionService.Tier?,
            lastVerifiedAt: Date?,
            latestAttempt: SubscriptionService.AttemptOutcome,
            expectTier: SubscriptionService.Tier,
            expectVerification: SubscriptionService.VerificationStatus
        ) {
            let (tier, verification) = SubscriptionService.classify(
                lastTier: lastTier,
                lastVerifiedAt: lastVerifiedAt,
                latestAttempt: latestAttempt,
                now: now,
                gracePeriod: grace
            )
            if tier == expectTier, verification == expectVerification {
                report.lines.append("classify: \(name) → \(tier)/\(verification)")
            } else {
                report.failures.append(
                    "classify: \(name): expected \(expectTier)/\(expectVerification), got \(tier)/\(verification)"
                )
            }
        }

        expect(
            "fresh Go+ read", lastTier: nil, lastVerifiedAt: nil,
            latestAttempt: .succeeded(.goPlus),
            expectTier: .goPlus, expectVerification: .verified
        )
        expect(
            "fresh free read", lastTier: nil, lastVerifiedAt: nil,
            latestAttempt: .succeeded(.free),
            expectTier: .free, expectVerification: .verifiedNotSubscribed
        )
        expect(
            "never attempted, nothing persisted", lastTier: nil, lastVerifiedAt: nil,
            latestAttempt: .notYetAttempted,
            expectTier: .unknown, expectVerification: .unverifiable(withinGrace: false)
        )
        expect(
            "failed attempt, recent Go+ on file → within grace", lastTier: .goPlus,
            lastVerifiedAt: now.addingTimeInterval(-3 * 24 * 3600),
            latestAttempt: .failed,
            expectTier: .goPlus, expectVerification: .unverifiable(withinGrace: true)
        )
        expect(
            "failed attempt, Go+ on file just past the grace boundary", lastTier: .goPlus,
            lastVerifiedAt: now.addingTimeInterval(-(grace + 1)),
            latestAttempt: .failed,
            expectTier: .goPlus, expectVerification: .unverifiable(withinGrace: false)
        )
        expect(
            "failed attempt, Go+ on file exactly at the grace boundary", lastTier: .goPlus,
            lastVerifiedAt: now.addingTimeInterval(-grace),
            latestAttempt: .failed,
            expectTier: .goPlus, expectVerification: .unverifiable(withinGrace: true)
        )
        expect(
            "failed attempt, free confirmed long ago stays confirmed", lastTier: .free,
            lastVerifiedAt: now.addingTimeInterval(-90 * 24 * 3600),
            latestAttempt: .failed,
            expectTier: .free, expectVerification: .verifiedNotSubscribed
        )
        expect(
            "ambiguous unknown-shape read doesn't overturn a recent Go+ read", lastTier: .goPlus,
            lastVerifiedAt: now.addingTimeInterval(-3600),
            latestAttempt: .succeeded(.unknown),
            expectTier: .goPlus, expectVerification: .unverifiable(withinGrace: true)
        )
    }
}
#endif
