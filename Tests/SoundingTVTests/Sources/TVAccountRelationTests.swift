import XCTest
@testable import SoundingTV

private let alex = PeerAccount(userId: "1001", name: "Alex", username: "alex")
private let sam = PeerAccount(userId: "2002", name: "Sam", username: "sam")
private let alexRenamed = PeerAccount(userId: "1001", name: "Alexander", username: "alex-dj")

final class TVAccountRelationTests: XCTestCase {
    private let knownAndProvable = TVAccountEvidence(ownerProvable: true, knownLink: .linked)

    func testRow1SameAccountLinked() {
        let relation = TVAccountRelation.resolve(tv: .signedIn(alex), phone: .signedIn(alex), link: .linked(reachable: true), evidence: knownAndProvable)
        XCTAssertEqual(relation, .sameAccount(linked: true, autoLink: false))
    }

    func testRow2SameAccountKnownLinkAutoLinks() {
        let relation = TVAccountRelation.resolve(tv: .signedInSame, phone: .signedIn(alex), link: .unlinked, evidence: knownAndProvable)
        XCTAssertEqual(relation, .sameAccount(linked: false, autoLink: true))
    }

    func testRow2NeverLinkedNeedsTheCard() {
        let evidence = TVAccountEvidence(ownerProvable: true, knownLink: .never)
        XCTAssertEqual(
            TVAccountRelation.resolve(tv: .signedInSame, phone: .signedIn(alex), link: .unlinked, evidence: evidence),
            .sameAccount(linked: false, autoLink: false)
        )
    }

    func testRow2UnlinkedNeedsTheCardEvenWithTheSameAppleID() {
        let evidence = TVAccountEvidence(ownerProvable: true, knownLink: .unlinked)
        XCTAssertEqual(
            TVAccountRelation.resolve(tv: .signedInSame, phone: .signedIn(alex), link: .unlinked, evidence: evidence),
            .sameAccount(linked: false, autoLink: false)
        )
    }

    func testKnownLinkOnAnotherAccountNeedsTheCard() {
        let evidence = TVAccountEvidence(ownerProvable: true, knownLink: .otherAccount)
        XCTAssertEqual(
            TVAccountRelation.resolve(tv: .signedInSame, phone: .signedIn(alex), link: .unlinked, evidence: evidence),
            .sameAccount(linked: false, autoLink: false)
        )
    }

    func testRow3OtherAppleIDNeedsTheCard() {
        let evidence = TVAccountEvidence(ownerProvable: false, knownLink: .linked)
        XCTAssertEqual(
            TVAccountRelation.resolve(tv: .signedInSame, phone: .signedIn(alex), link: .unlinked, evidence: evidence),
            .sameAccount(linked: false, autoLink: false)
        )
    }

    func testRow4SignedOutTV() {
        XCTAssertEqual(TVAccountRelation.resolve(tv: .signedOut, phone: .signedIn(alex), link: .unlinked), .tvSignedOut(linked: false))
        XCTAssertEqual(TVAccountRelation.resolve(tv: .signedOut, phone: .signedIn(alex), link: .linked(reachable: true)), .tvSignedOut(linked: true))
    }

    func testRow5NeedsSignInWasMine() {
        XCTAssertEqual(
            TVAccountRelation.resolve(tv: .needsSignIn(last: alex), phone: .signedIn(alex), link: .linked(reachable: true)),
            .tvNeedsSignIn(last: alex, mine: alex)
        )
        XCTAssertEqual(
            TVAccountRelation.resolve(tv: .needsSignIn(last: nil), phone: .signedIn(alex), link: .linked(reachable: true)),
            .tvNeedsSignIn(last: nil, mine: alex)
        )
    }

    func testRow6NeedsSignInWasSomeoneElse() {
        XCTAssertEqual(
            TVAccountRelation.resolve(tv: .needsSignIn(last: sam), phone: .signedIn(alex), link: .linked(reachable: false)),
            .tvNeedsSignIn(last: sam, mine: alex)
        )
    }

    func testRow7BothSignedOut() {
        XCTAssertEqual(TVAccountRelation.resolve(tv: .signedOut, phone: .signedOut, link: .unlinked), .nothing)
        XCTAssertEqual(TVAccountRelation.resolve(tv: .needsSignIn(last: sam), phone: .signedOut, link: .linked(reachable: true)), .nothing)
    }

    func testRow8PhoneSignedOutUnlinkedWithICloudOffer() {
        let offer = ICloudSessionOffer(account: sam, writerName: "Living Room")
        XCTAssertEqual(
            TVAccountRelation.resolve(tv: .signedInOther, phone: .signedOut, link: .unlinked, evidence: TVAccountEvidence(iCloudOffer: offer)),
            .phoneSignedOut(tv: nil, offer: offer)
        )
        XCTAssertEqual(
            TVAccountRelation.resolve(tv: .unknown, phone: .signedOut, link: .unlinked, evidence: TVAccountEvidence(iCloudOffer: offer)),
            .phoneSignedOut(tv: nil, offer: offer)
        )
    }

    func testRow9PhoneSignedOutLinked() {
        XCTAssertEqual(
            TVAccountRelation.resolve(tv: .signedIn(sam), phone: .signedOut, link: .linked(reachable: true)),
            .phoneSignedOut(tv: sam, offer: nil)
        )
    }

    func testRow10DifferentAccountUnlinkedFromTheHint() {
        XCTAssertEqual(
            TVAccountRelation.resolve(tv: .signedInOther, phone: .signedIn(alex), link: .unlinked),
            .differentAccounts(tv: nil, mine: alex)
        )
    }

    func testRow11DifferentAccountLinked() {
        let relation = TVAccountRelation.resolve(tv: .signedIn(sam), phone: .signedIn(alex), link: .linked(reachable: true))
        XCTAssertEqual(relation, .differentAccounts(tv: sam, mine: alex))
        XCTAssertTrue(relation.isDifferentAccounts)
        XCTAssertEqual(relation.otherAccount, sam)
    }

    func testRow12AfterTheSwitchTheRelationIsFlowOne() {
        let before = TVAccountRelation.resolve(tv: .signedIn(sam), phone: .signedIn(alex), link: .linked(reachable: true))
        let after = TVAccountRelation.resolve(tv: .signedIn(alex), phone: .signedIn(alex), link: .linked(reachable: true))
        XCTAssertEqual(before, .differentAccounts(tv: sam, mine: alex))
        XCTAssertEqual(after, .sameAccount(linked: true, autoLink: false))
    }

    func testOlderTVIsUnknown() {
        XCTAssertEqual(TVAccountRelation.resolve(tv: .unknown, phone: .signedIn(alex), link: .linked(reachable: true)), .unknown)
        XCTAssertEqual(TVAccountRelation.resolve(tv: .unknown, phone: .signedOut, link: .linked(reachable: true)), .unknown)
    }

    func testNeedsSignInSeenWithoutALinkIsTreatedAsSignedOut() {
        XCTAssertEqual(TVAccountRelation.resolve(tv: .needsSignIn(last: sam), phone: .signedIn(alex), link: .unlinked), .tvSignedOut(linked: false))
    }

    func testAccountsCompareByTagNotName() {
        XCTAssertEqual(
            TVAccountRelation.resolve(tv: .signedIn(alexRenamed), phone: .signedIn(alex), link: .linked(reachable: true)),
            .sameAccount(linked: true, autoLink: false)
        )
        let samCalledAlex = PeerAccount(userId: "2002", name: "Alex", username: "alex")
        XCTAssertEqual(
            TVAccountRelation.resolve(tv: .signedIn(samCalledAlex), phone: .signedIn(alex), link: .linked(reachable: true)),
            .differentAccounts(tv: samCalledAlex, mine: alex)
        )
    }

    func testTVAccountFromStatus() {
        let secret = Data(repeating: 1, count: 32)
        let signedIn = AccountStatusPayload.create(state: .signedIn, account: sam.encoded(), last: nil, sessionId: "s", secret: secret)
        XCTAssertEqual(TVAccount(status: signedIn), .signedIn(sam))
        let needs = AccountStatusPayload.create(state: .needsSignIn, account: nil, last: alex.encoded(), sessionId: "s", secret: secret)
        XCTAssertEqual(TVAccount(status: needs), .needsSignIn(last: alex))
        let out = AccountStatusPayload.create(state: .signedOut, account: nil, last: nil, sessionId: "s", secret: secret)
        XCTAssertEqual(TVAccount(status: out), .signedOut)
        XCTAssertEqual(TVAccount(status: nil), .unknown)
    }
}

final class TVAccountCopyTests: XCTestCase {
    func testPlayOnSubtitles() {
        XCTAssertEqual(TVAccountCopy.playOnSubtitle(.differentAccounts(tv: sam, mine: alex)), "Signed in as Sam")
        XCTAssertEqual(TVAccountCopy.playOnSubtitle(.differentAccounts(tv: nil, mine: alex)), "Signed in to another account")
        XCTAssertEqual(TVAccountCopy.playOnSubtitle(.phoneSignedOut(tv: sam, offer: nil)), "Signed in as Sam")
        XCTAssertNil(TVAccountCopy.playOnSubtitle(.sameAccount(linked: true, autoLink: false)))
    }

    func testCardAndCapsule() {
        XCTAssertEqual(TVAccountCopy.cardSignInMessage(mine: alex), "Sign it in to Sounding as Alex.")
        XCTAssertEqual(TVAccountCopy.cardLinkSubtitle(mine: alex), "Apple TV · Signed in as Alex")
        XCTAssertEqual(TVAccountCopy.linkedCapsule(tv: "Living Room"), "Linked to Living Room")
    }

    func testNeedsSignInCopy() {
        let mine = TVAccountCopy.needsSignIn(tv: "Living Room", last: alex, mine: alex, device: "iPhone")
        XCTAssertEqual(mine.title, "Living Room is waiting to sign in.")
        XCTAssertEqual(mine.footer, "It'll use the SoundCloud account on this iPhone.")
        XCTAssertEqual(mine.action, "Sign In This Apple TV")
        let other = TVAccountCopy.needsSignIn(tv: "Living Room", last: sam, mine: alex, device: "iPhone")
        XCTAssertEqual(other.title, "Living Room was signed in as Sam.")
        XCTAssertEqual(other.footer, "Sign it in as Alex, or sign Sam in on Living Room.")
        XCTAssertEqual(other.action, "Sign In as Alex")
        XCTAssertEqual(TVAccountCopy.needsSignInTimedOut(tv: "Living Room"), "Living Room didn't answer. Keep it on and try again.")
    }

    func testChoiceCopy() {
        let choice = TVAccountCopy.choice(tv: "Living Room", theirs: sam, mine: alex, controlling: false)
        XCTAssertEqual(choice.title, "Living Room is signed in as Sam")
        XCTAssertEqual(choice.message, "You're signed in as Alex. Living Room plays from Sam's SoundCloud, so tracks only Alex can play won't play there.")
        XCTAssertEqual(choice.proceed, "Play on Living Room")
        XCTAssertEqual(choice.switchAction, "Switch Living Room to Alex…")
        XCTAssertEqual(TVAccountCopy.choice(tv: "Living Room", theirs: sam, mine: alex, controlling: true).proceed, "Control Living Room")
    }

    func testSwitchCopy() {
        let confirm = TVAccountCopy.confirmSwitch(tv: "Living Room", theirs: sam, mine: alex)
        XCTAssertEqual(confirm.title, "Switch Living Room to Alex?")
        XCTAssertEqual(confirm.message, "Sam will be signed out on Living Room. Sam's downloads and recent plays on it are removed.")
        XCTAssertEqual(TVAccountCopy.waiting(tv: "Living Room"), "Waiting for Living Room…")
        XCTAssertEqual(TVAccountCopy.waitingFooter(tv: "Living Room"), "Choose Switch on Living Room.")
        XCTAssertEqual(TVAccountCopy.switchOutcome(.declined, tv: "Living Room", theirs: sam), "Living Room kept Sam's account.")
        XCTAssertEqual(TVAccountCopy.switchOutcome(.timedOut, tv: "Living Room", theirs: sam), "Living Room didn't answer. Its account hasn't changed.")
        XCTAssertEqual(TVAccountCopy.switchOutcome(.unavailable, tv: "Living Room", theirs: sam), "Living Room couldn't reach SoundCloud. Its account hasn't changed.")
        XCTAssertEqual(TVAccountCopy.switchOutcome(.refused, tv: "Living Room", theirs: sam, device: "iPhone"), "Your sign-in on this iPhone needs renewing. Try again in a moment.")
        XCTAssertEqual(TVAccountCopy.switchOutcome(.dropped, tv: "Living Room", theirs: sam), "Living Room isn't reachable. Its account hasn't changed.")
        XCTAssertEqual(TVAccountCopy.switched(tv: "Living Room", mine: alex), "Living Room is signed in as Alex.")
    }

    func testTVCopy() {
        XCTAssertEqual(TVAccountCopy.tvAllowTitle(device: "Alex's iPhone"), "Allow “Alex's iPhone” to control this Apple TV?")
        XCTAssertEqual(TVAccountCopy.tvAllowMessage(device: "Alex's iPhone", sameAccount: true), "It's signed in to the same SoundCloud account. Only allow it if Alex's iPhone shows this code.")
        XCTAssertEqual(TVAccountCopy.tvAllowMessage(device: "Alex's iPhone", sameAccount: false), "It's signed in to a different SoundCloud account. Only allow it if Alex's iPhone shows this code.")
        XCTAssertEqual(TVAccountCopy.tvSwitchTitle(mine: alex), "Switch to Alex's SoundCloud?")
        XCTAssertEqual(TVAccountCopy.tvSwitchMessage(device: "Alex's iPhone", mine: alex, theirs: sam), "Alex's iPhone wants to sign this Apple TV in as Alex. Sam will be signed out here.")
        XCTAssertEqual(TVAccountCopy.tvKeep(sam), "Keep Sam")
        XCTAssertEqual(TVAccountCopy.tvSwitching(to: alex), "Switching to Alex…")
        XCTAssertEqual(TVAccountCopy.tvConnectedCapsule(device: "Alex's iPhone", controller: alex), "Alex's iPhone is connected · Alex")
        XCTAssertEqual(TVAccountCopy.tvLinkedCapsule(device: "Alex's iPhone"), "Alex's iPhone is linked")
        XCTAssertEqual(TVAccountCopy.tvSignedInSubtitle(alex), "Signed in as Alex.")
    }

    func testOtherCopy() {
        XCTAssertEqual(TVAccountCopy.trackUnavailable(tv: "Living Room", theirs: sam), .init(title: "Couldn't Play on Living Room", message: "It's signed in as Sam, who can't play this."))
        XCTAssertEqual(TVAccountCopy.commandRefused(tv: "Living Room"), "Living Room couldn't do that.")
        XCTAssertEqual(TVAccountCopy.linkOtherAccount(tv: "Living Room", device: "iPhone"), .init(title: "Living Room is signed in to another SoundCloud account", message: "Link it to control it from this iPhone. You can switch it to your account afterwards."))
        XCTAssertEqual(TVAccountCopy.accountSectionFooter(mine: alex), "You're signed in as Alex. Your likes and library stay with Alex.")
        XCTAssertEqual(TVAccountCopy.welcomeLine(tv: "Living Room", account: sam), "Living Room is signed in as Sam.")
        XCTAssertEqual(TVAccountCopy.continueAs(sam), "Continue as Sam")
        XCTAssertEqual(TVAccountCopy.signedInOn("Living Room"), "Signed in on Living Room")
        XCTAssertEqual(TVAccountCopy.continueExpired(sam), "Sam's sign-in has expired. Sign in with SoundCloud instead.")
    }

    func testNamesWithApostrophesAndLongNames() {
        let device = "Sam's \"Big\" iPhone"
        XCTAssertEqual(TVAccountCopy.tvAllowTitle(device: device), "Allow “Sam's \"Big\" iPhone” to control this Apple TV?")
        let long = PeerAccount(userId: "3", name: String(repeating: "x", count: 200), username: "x")
        XCTAssertEqual(long.name.count, PeerAccount.maximumNameLength)
        XCTAssertTrue(TVAccountCopy.signedInAs(long).hasPrefix("Signed in as xxx"))
    }
}

final class AutoLinkPolicyTests: XCTestCase {
    private let ready = AutoLinkPolicy.Input(
        isSignedIn: true,
        isForeground: true,
        holdsLinkKey: true,
        hintMatches: true,
        listedAsLinked: false,
        alreadyLinked: false,
        dismissed: false,
        showingOtherSheet: false,
        attemptedThisLaunch: false,
        knownLink: .linked
    )

    func testAttemptsOnlyForAKnownLinkThatWasNeverUnlinked() {
        XCTAssertTrue(AutoLinkPolicy.shouldAttempt(ready))
        for status in [KnownLinkLedger.Status.never, .unlinked, .otherAccount] {
            var input = ready
            input.knownLink = status
            XCTAssertFalse(AutoLinkPolicy.shouldAttempt(input), "\(status)")
        }
    }

    func testEveryGuardBlocks() {
        let blockers: [(inout AutoLinkPolicy.Input) -> Void] = [
            { $0.isSignedIn = false },
            { $0.isForeground = false },
            { $0.holdsLinkKey = false },
            { $0.hintMatches = false },
            { $0.listedAsLinked = true },
            { $0.alreadyLinked = true },
            { $0.dismissed = true },
            { $0.showingOtherSheet = true },
            { $0.attemptedThisLaunch = true },
        ]
        for (index, block) in blockers.enumerated() {
            var input = ready
            block(&input)
            XCTAssertFalse(AutoLinkPolicy.shouldAttempt(input), "blocker \(index)")
        }
    }

    func testOwnerTagsAreSentOnlyForKnownLinks() {
        XCTAssertTrue(AutoLinkPolicy.sendsOwnerTags(knownLink: .linked, hintMatches: true))
        XCTAssertFalse(AutoLinkPolicy.sendsOwnerTags(knownLink: .never, hintMatches: true))
        XCTAssertFalse(AutoLinkPolicy.sendsOwnerTags(knownLink: .unlinked, hintMatches: true))
        XCTAssertFalse(AutoLinkPolicy.sendsOwnerTags(knownLink: .linked, hintMatches: false))
    }
}

final class KnownLinkLedgerTests: XCTestCase {
    private let tv = KnownLinkLedger.identity(name: " Living Room ", kind: .tv)

    func testLinkedThenUnlinkedBlocksAutoLinkUntilLinkedAgain() {
        var ledger = KnownLinkLedger()
        XCTAssertEqual(ledger.status(of: tv, accountTag: alex.tag), .never)
        ledger.recordLinked(tv, accountTag: alex.tag)
        XCTAssertTrue(ledger.allowsAutoLink(tv, accountTag: alex.tag))
        XCTAssertEqual(ledger.status(of: tv, accountTag: sam.tag), .otherAccount)
        ledger.recordUnlinked(tv)
        XCTAssertEqual(ledger.status(of: tv, accountTag: alex.tag), .unlinked)
        XCTAssertFalse(ledger.allowsAutoLink(tv, accountTag: alex.tag))
        ledger.recordLinked(tv, accountTag: alex.tag)
        XCTAssertTrue(ledger.allowsAutoLink(tv, accountTag: alex.tag))
    }

    func testUnlinkingAnUnknownDeviceIsRemembered() {
        var ledger = KnownLinkLedger()
        ledger.recordUnlinked(tv)
        XCTAssertEqual(ledger.status(of: tv, accountTag: alex.tag), .unlinked)
    }

    func testIdentityIgnoresCaseAndSpacing() {
        XCTAssertEqual(KnownLinkLedger.identity(name: "living room", kind: .tv), tv)
        XCTAssertNotEqual(KnownLinkLedger.identity(name: "Living Room", kind: .mac), tv)
    }

    func testPersistsAndCapsItsSize() {
        let defaults = UserDefaults(suiteName: "KnownLinkLedgerTests")!
        defaults.removePersistentDomain(forName: "KnownLinkLedgerTests")
        KnownLinkLedger.update(defaults: defaults) { ledger in
            for index in 0..<(KnownLinkLedger.capacity + 5) {
                ledger.recordLinked("tv|\(index)", accountTag: alex.tag, at: Date(timeIntervalSince1970: TimeInterval(index)))
            }
        }
        let loaded = KnownLinkLedger.load(defaults: defaults)
        XCTAssertEqual(loaded.entries.count, KnownLinkLedger.capacity)
        XCTAssertEqual(loaded.status(of: "tv|\(KnownLinkLedger.capacity + 4)", accountTag: alex.tag), .linked)
        XCTAssertEqual(loaded.status(of: "tv|0", accountTag: alex.tag), .never)
        defaults.removePersistentDomain(forName: "KnownLinkLedgerTests")
    }
}

final class CrossAccountChoiceTests: XCTestCase {
    func testRememberedPerLinkAndAccounts() {
        var choice = CrossAccountChoice()
        let relation = TVAccountRelation.differentAccounts(tv: sam, mine: alex)
        XCTAssertTrue(CrossAccountChoice.needsChoice(relation, link: "link-1", choice: choice))
        choice.remember(link: "link-1", tv: sam, mine: alex)
        XCTAssertFalse(CrossAccountChoice.needsChoice(relation, link: "link-1", choice: choice))
        XCTAssertTrue(CrossAccountChoice.needsChoice(relation, link: "link-2", choice: choice))
    }

    func testForgottenWhenEitherAccountChanges() {
        var choice = CrossAccountChoice()
        choice.remember(link: "link-1", tv: sam, mine: alex)
        let other = PeerAccount(userId: "3003", name: "Kim", username: "kim")
        XCTAssertTrue(CrossAccountChoice.needsChoice(.differentAccounts(tv: other, mine: alex), link: "link-1", choice: choice))
        XCTAssertTrue(CrossAccountChoice.needsChoice(.differentAccounts(tv: sam, mine: other), link: "link-1", choice: choice))
        choice.remember(link: "link-1", tv: other, mine: alex)
        XCTAssertFalse(choice.isRemembered(link: "link-1", tv: sam, mine: alex))
    }

    func testForgottenWithTheLink() {
        var choice = CrossAccountChoice()
        choice.remember(link: "link-1", tv: sam, mine: alex)
        choice.remember(link: "link-10", tv: sam, mine: alex)
        choice.forget(link: "link-1")
        XCTAssertFalse(choice.isRemembered(link: "link-1", tv: sam, mine: alex))
        XCTAssertTrue(choice.isRemembered(link: "link-10", tv: sam, mine: alex))
    }

    func testOnlyDifferentAccountsAsk() {
        let choice = CrossAccountChoice()
        XCTAssertFalse(CrossAccountChoice.needsChoice(.sameAccount(linked: true, autoLink: false), link: "l", choice: choice))
        XCTAssertFalse(CrossAccountChoice.needsChoice(.unknown, link: "l", choice: choice))
        XCTAssertTrue(CrossAccountChoice.needsChoice(.differentAccounts(tv: nil, mine: alex), link: "l", choice: choice))
    }
}

final class AccountSwitchHandshakeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func waiting(_ nonce: String = "n1") -> AccountSwitchHandshake {
        var handshake = AccountSwitchHandshake()
        handshake.begin()
        XCTAssertEqual(handshake.phase, .confirming)
        XCTAssertTrue(handshake.confirm(nonce: nonce, at: start))
        return handshake
    }

    func testHappyPath() {
        var handshake = waiting()
        XCTAssertEqual(handshake.phase, .waiting(nonce: "n1", since: start))
        XCTAssertFalse(handshake.mayReleaseCredentials)
        XCTAssertEqual(handshake.receive(.accepted, nonce: "n1", at: start + 5), .sendCredentials(nonce: "n1"))
        XCTAssertTrue(handshake.mayReleaseCredentials)
        handshake.credentialsSent(at: start + 5)
        XCTAssertEqual(handshake.phase, .validating(nonce: "n1", since: start + 5))
        XCTAssertFalse(handshake.mayReleaseCredentials)
        XCTAssertEqual(handshake.receive(.switched, nonce: "n1", at: start + 8), .none)
        XCTAssertEqual(handshake.phase, .done)
    }

    func testCancelFromConfirming() {
        var handshake = AccountSwitchHandshake()
        handshake.begin()
        handshake.cancel()
        XCTAssertEqual(handshake.phase, .idle)
    }

    func testDeclined() {
        var handshake = waiting()
        XCTAssertEqual(handshake.receive(.declined, nonce: "n1", at: start + 3), .none)
        XCTAssertEqual(handshake.phase, .failed(.declined))
    }

    func testTimesOutAfterSixtySeconds() {
        var handshake = waiting()
        handshake.tick(at: start + 59)
        XCTAssertEqual(handshake.phase, .waiting(nonce: "n1", since: start))
        handshake.tick(at: start + 60)
        XCTAssertEqual(handshake.phase, .failed(.timedOut))
    }

    func testCredentialsStepTimesOutAfterThirtySeconds() {
        var handshake = waiting()
        _ = handshake.receive(.accepted, nonce: "n1", at: start + 1)
        handshake.credentialsSent(at: start + 1)
        handshake.tick(at: start + 30)
        XCTAssertEqual(handshake.phase, .validating(nonce: "n1", since: start + 1))
        handshake.tick(at: start + 31)
        XCTAssertEqual(handshake.phase, .failed(.dropped))
    }

    func testLinkDropped() {
        var handshake = waiting()
        handshake.linkDropped()
        XCTAssertEqual(handshake.phase, .failed(.dropped))
    }

    func testValidationUnavailableAndPairRefused() {
        var unavailable = waiting()
        _ = unavailable.receive(.accepted, nonce: "n1", at: start)
        unavailable.credentialsSent(at: start)
        _ = unavailable.receive(.unavailable, nonce: "n1", at: start + 2)
        XCTAssertEqual(unavailable.phase, .failed(.unavailable))

        var refused = waiting()
        _ = refused.receive(.accepted, nonce: "n1", at: start)
        refused.credentialsSent(at: start)
        _ = refused.receive(.refused, nonce: "n1", at: start + 2)
        XCTAssertEqual(refused.phase, .failed(.refused))
    }

    func testCredentialsAreNeverReleasedBeforeAccepted() {
        var handshake = waiting()
        XCTAssertEqual(handshake.receive(.switched, nonce: "n1", at: start), .none)
        XCTAssertFalse(handshake.mayReleaseCredentials)
        XCTAssertEqual(handshake.receive(.accepted, nonce: "other", at: start), .none)
        XCTAssertFalse(handshake.mayReleaseCredentials)
        XCTAssertEqual(handshake.phase, .waiting(nonce: "n1", since: start))
    }

    func testNonceReuseIsRejected() {
        var handshake = waiting()
        _ = handshake.receive(.declined, nonce: "n1", at: start)
        handshake.begin()
        XCTAssertFalse(handshake.confirm(nonce: "n1", at: start + 1))
        XCTAssertTrue(handshake.confirm(nonce: "n2", at: start + 1))
        XCTAssertEqual(handshake.receive(.accepted, nonce: "n1", at: start + 2), .none)
    }

    func testCannotBeginWhileBusy() {
        var handshake = waiting()
        handshake.begin()
        XCTAssertEqual(handshake.phase, .waiting(nonce: "n1", since: start))
    }
}

final class TVAccountSwitchGateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testAcceptThenCredentials() {
        var gate = TVAccountSwitchGate()
        XCTAssertTrue(gate.receive(nonce: "n1", sessionId: "s1", account: alex, deviceName: "Alex's iPhone", at: start))
        XCTAssertEqual(gate.asking?.account, alex)
        XCTAssertNil(gate.credentials(nonce: "n1", sessionId: "s1", at: start + 1))
        XCTAssertNotNil(gate.accept(at: start + 2))
        XCTAssertNil(gate.asking)
        XCTAssertNil(gate.credentials(nonce: "n1", sessionId: "s2", at: start + 3))
        XCTAssertNil(gate.credentials(nonce: "n2", sessionId: "s1", at: start + 3))
        XCTAssertEqual(gate.credentials(nonce: "n1", sessionId: "s1", at: start + 3)?.account, alex)
        XCTAssertNil(gate.credentials(nonce: "n1", sessionId: "s1", at: start + 4))
    }

    func testCredentialsTooLateAreRefused() {
        var gate = TVAccountSwitchGate()
        _ = gate.receive(nonce: "n1", sessionId: "s1", account: alex, deviceName: "iPhone", at: start)
        _ = gate.accept(at: start)
        XCTAssertNil(gate.credentials(nonce: "n1", sessionId: "s1", at: start + 30))
    }

    func testOneAtATimeAndNoncesAreSingleUse() {
        var gate = TVAccountSwitchGate()
        XCTAssertTrue(gate.receive(nonce: "n1", sessionId: "s1", account: alex, deviceName: "iPhone", at: start))
        XCTAssertFalse(gate.receive(nonce: "n2", sessionId: "s2", account: alex, deviceName: "iPad", at: start))
        XCTAssertNotNil(gate.decline())
        XCTAssertFalse(gate.receive(nonce: "n1", sessionId: "s1", account: alex, deviceName: "iPhone", at: start + 1))
    }

    func testExpiresAndDrops() {
        var gate = TVAccountSwitchGate()
        _ = gate.receive(nonce: "n1", sessionId: "s1", account: alex, deviceName: "iPhone", at: start)
        XCTAssertNil(gate.expire(at: start + 59))
        XCTAssertNotNil(gate.expire(at: start + 60))
        _ = gate.receive(nonce: "n2", sessionId: "s1", account: alex, deviceName: "iPhone", at: start)
        XCTAssertNil(gate.drop(sessionId: "s2"))
        XCTAssertNotNil(gate.drop(sessionId: "s1"))
    }
}

final class LinkEstablishTests: XCTestCase {
    private let salt = Data(repeating: 0x5A, count: LinkAccountHint.saltLength)

    func testOfferHints() {
        let advert = LinkAccountHint.advert(accountId: "1001", linkedDeviceIds: [], salt: salt)
        XCTAssertEqual(LinkEstablishPolicy.hint(for: advert, offerSeen: true, accountId: "1001"), .sameAccount)
        XCTAssertEqual(LinkEstablishPolicy.hint(for: advert, offerSeen: true, accountId: "2002"), .otherAccount)
        XCTAssertEqual(LinkEstablishPolicy.hint(for: advert, offerSeen: true, accountId: nil), .otherAccount)
        XCTAssertEqual(LinkEstablishPolicy.hint(for: nil, offerSeen: true, accountId: "1001"), .signedOut)
        XCTAssertEqual(LinkEstablishPolicy.hint(for: nil, offerSeen: false, accountId: "1001"), .notSeen)
    }

    func testOpeningSendsATokenOnlyToSignedOutTVs() {
        XCTAssertEqual(LinkEstablishPolicy.opening(for: .signedOut), .tokenTransfer)
        XCTAssertEqual(LinkEstablishPolicy.opening(for: .sameAccount), .linkEstablish)
        XCTAssertEqual(LinkEstablishPolicy.opening(for: .otherAccount), .linkEstablish)
        XCTAssertEqual(LinkEstablishPolicy.opening(for: .notSeen), .linkEstablish)
    }

    func testCredentialsRequestedOnlyWhenTheTVNeedsThem() {
        let secret = Data(repeating: 2, count: 32)
        let signedOut = LinkEstablishedPayload.create(needsCredentials: true, account: nil, sessionId: "s", secret: secret)
        let signedIn = LinkEstablishedPayload.create(needsCredentials: false, account: sam.encoded(), sessionId: "s", secret: secret)
        XCTAssertTrue(LinkEstablishPolicy.sendsCredentials(signedOut))
        XCTAssertFalse(LinkEstablishPolicy.sendsCredentials(signedIn))
        XCTAssertTrue(signedIn.verify(sessionId: "s", secret: secret))
        XCTAssertFalse(signedIn.verify(sessionId: "other", secret: secret))
    }

    func testOlderTVFallbackNeverSendsATokenToAnotherAccount() {
        XCTAssertTrue(LinkEstablishPolicy.fallsBackToTokenTransfer(.notSeen))
        XCTAssertTrue(LinkEstablishPolicy.fallsBackToTokenTransfer(.sameAccount))
        XCTAssertFalse(LinkEstablishPolicy.fallsBackToTokenTransfer(.otherAccount))
    }

    func testHelloDigestPicksTheAllowCopy() {
        let digest = LinkEstablishPolicy.helloDigest(accountId: "1001", salt: salt)
        XCTAssertNotNil(digest)
        XCTAssertTrue(LinkEstablishPolicy.isSameAccountApproval(digest: digest, salt: salt, accountId: "1001"))
        XCTAssertFalse(LinkEstablishPolicy.isSameAccountApproval(digest: digest, salt: salt, accountId: "2002"))
        XCTAssertFalse(LinkEstablishPolicy.isSameAccountApproval(digest: nil, salt: salt, accountId: "1001"))
        XCTAssertFalse(LinkEstablishPolicy.isSameAccountApproval(digest: digest, salt: nil, accountId: "1001"))
        XCTAssertNil(LinkEstablishPolicy.helloDigest(accountId: nil, salt: salt))
        XCTAssertNil(LinkEstablishPolicy.helloDigest(accountId: "1001", salt: Data([1, 2])))
    }
}

final class CompanionRejectionTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(CompanionRejection.classify(code: "track_unavailable", message: "x"), .trackUnavailable)
        XCTAssertEqual(CompanionRejection.classify(code: "queue_unavailable", message: nil), .queueUnavailable)
        XCTAssertEqual(CompanionRejection.classify(code: "sync_refused", message: nil), .syncRefused)
        XCTAssertEqual(CompanionRejection.classify(code: "not_expected", message: nil), .notExpected)
        XCTAssertEqual(CompanionRejection.classify(code: nil, message: "Library sync rejected"), .syncRefused)
        XCTAssertEqual(CompanionRejection.classify(code: nil, message: "Local music offer rejected"), .syncRefused)
        XCTAssertEqual(CompanionRejection.classify(code: nil, message: "Continue session rejected"), .syncRefused)
        XCTAssertEqual(CompanionRejection.classify(code: nil, message: "Could not load the queue"), .queueUnavailable)
        XCTAssertEqual(CompanionRejection.classify(code: nil, message: "Unsupported message"), .other)
    }

    @MainActor
    func testSyncRefusalResolvesNoWaiter() async {
        let tracker = PlaybackConfirmationTracker()
        let outcome = Task { @MainActor in
            await tracker.confirm(trackId: "a", timeout: .milliseconds(300)) { true }
        }
        await Self.waitUntil { tracker.pendingCount == 1 }
        tracker.observeRejection("Library sync rejected")
        tracker.observeRejection("Nope", code: CompanionErrorCode.syncRefused)
        XCTAssertEqual(tracker.pendingCount, 1)
        let result = await outcome.value
        XCTAssertEqual(result, .timedOut)
    }

    @MainActor
    func testRejectionResolvesOnlyTheMatchingWaiter() async {
        let tracker = PlaybackConfirmationTracker()
        let first = Task { @MainActor in await tracker.confirm(trackId: "a", timeout: .seconds(5)) { true } }
        let second = Task { @MainActor in await tracker.confirm(trackId: "b", timeout: .milliseconds(300)) { true } }
        await Self.waitUntil { tracker.pendingCount == 2 }
        tracker.observeRejection("Can't play", code: CompanionErrorCode.trackUnavailable, trackId: "a")
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .trackUnavailable("Can't play"))
        XCTAssertEqual(tracker.pendingCount, 1)
        let secondResult = await second.value
        XCTAssertEqual(secondResult, .timedOut)
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testPresenceFilterDropsOtherAccountTVsUnlessOutput() {
        XCTAssertFalse(PresenceAccountFilter.keeps(isOutput: false, tv: .signedIn(sam), mine: alex))
        XCTAssertTrue(PresenceAccountFilter.keeps(isOutput: true, tv: .signedIn(sam), mine: alex))
        XCTAssertTrue(PresenceAccountFilter.keeps(isOutput: false, tv: .signedIn(alex), mine: alex))
        XCTAssertTrue(PresenceAccountFilter.keeps(isOutput: false, tv: .unknown, mine: alex))
    }

    func testTVControllerLines() {
        XCTAssertEqual(TVControllerAccount.settingsLine(controller: alex, tv: sam), "Signed in as Alex")
        XCTAssertNil(TVControllerAccount.settingsLine(controller: alex, tv: alexRenamed))
        XCTAssertNil(TVControllerAccount.settingsLine(controller: nil, tv: sam))
        XCTAssertEqual(TVControllerAccount.connectedCapsule(device: "Alex's iPhone", controller: alex, tv: sam), "Alex's iPhone is connected · Alex")
        XCTAssertFalse(TVControllerAccount.acceptsAuthHandoff(needsSignIn: false, requestOutstanding: true))
        XCTAssertFalse(TVControllerAccount.acceptsAuthHandoff(needsSignIn: true, requestOutstanding: false))
        XCTAssertTrue(TVControllerAccount.acceptsAuthHandoff(needsSignIn: true, requestOutstanding: true))
    }
}

final class TVPairingCopyTests: XCTestCase {
    private let pad = PeerDevice(deviceClass: .pad, name: "Alex's iPad")
    private let namedOnly = PeerDevice(deviceClass: nil, name: "Alex's Mac mini")

    func testUnknownPeerUsesNeutralWording() {
        let peer = PeerDevice.unknown
        XCTAssertFalse(peer.isKnown)
        XCTAssertEqual(peer.symbolName, PeerDevice.neutralSymbolName)
        XCTAssertEqual(TVPairingCopy.finishOn(peer), "Finish on your device.")
        XCTAssertEqual(TVPairingCopy.connected(peer), "Device connected")
        XCTAssertEqual(TVPairingCopy.found(peer), "Device found")
        XCTAssertEqual(TVPairingCopy.connectedFinish(peer), "Connected. Finish on your device.")
        XCTAssertEqual(TVPairingCopy.droppedOff(peer), "Your device dropped off")
        XCTAssertEqual(TVPairingCopy.signInOnceMore(peer), "Try again for a fresh code, then sign in on your device once more.")
        XCTAssertEqual(TVPairingCopy.signInAgain(on: peer), "Your SoundCloud login has expired. Please sign in again on your device.")
    }

    func testKnownClassIsNamedWithItsOwnWordingAndSymbol() {
        XCTAssertTrue(pad.isKnown)
        XCTAssertEqual(pad.symbolName, DeviceClass.pad.symbolName)
        XCTAssertEqual(TVPairingCopy.finishOn(pad), "Finish on your iPad.")
        XCTAssertEqual(TVPairingCopy.connected(pad), "iPad connected")
        XCTAssertEqual(TVPairingCopy.droppedOff(pad), "Your iPad dropped off")
        XCTAssertEqual(TVPairingCopy.signInAgain(on: PeerDevice(deviceClass: .mac)), "Your SoundCloud login has expired. Please sign in again on your Mac.")
        XCTAssertEqual(TVPairingCopy.finishOn(PeerDevice(deviceClass: .phone)), "Finish on your iPhone.")
    }

    func testNameWithoutClassIsUsedVerbatim() {
        XCTAssertTrue(namedOnly.isKnown)
        XCTAssertEqual(namedOnly.symbolName, PeerDevice.neutralSymbolName)
        XCTAssertEqual(TVPairingCopy.finishOn(namedOnly), "Finish on Alex's Mac mini.")
        XCTAssertEqual(TVPairingCopy.connected(namedOnly), "Alex's Mac mini connected")
        XCTAssertEqual(TVPairingCopy.droppedOff(namedOnly), "Alex's Mac mini dropped off")
    }

    func testBlankNameCountsAsUnknown() {
        XCTAssertEqual(PeerDevice(deviceClass: nil, name: "  \n"), .unknown)
        XCTAssertEqual(PeerDevice(rawClass: nil, name: ""), .unknown)
    }

    func testRawClassResolvesOnlyKnownValues() {
        XCTAssertEqual(PeerDevice(rawClass: "mac").deviceClass, .mac)
        XCTAssertEqual(PeerDevice(rawClass: "pad", name: "x").deviceClass, .pad)
        XCTAssertNil(PeerDevice(rawClass: "toaster").deviceClass)
        XCTAssertNil(PeerDevice(rawClass: nil).deviceClass)
    }

    func testStaticLinesNeverNameAKindOfDevice() {
        XCTAssertEqual(TVPairingCopy.pickerTitle, "Sign in with Another Device")
        XCTAssertEqual(TVPairingCopy.unnamedDevice, "A device")
        for line in [TVPairingCopy.scanHint, TVPairingCopy.notified, TVPairingCopy.pickerConnecting, TVPairingCopy.pickerTitle, TVPairingCopy.unnamedDevice] {
            XCTAssertFalse(line.contains("iPhone"), line)
            XCTAssertFalse(line.contains("iPad"), line)
        }
        XCTAssertEqual(TVPairingCopy.scanAccessibility, "Sign-in QR code. Scan it with your phone's camera.")
        XCTAssertEqual(TVPairingCopy.nearbyHint("Alex's iPad"), "Alex's iPad is nearby: open Sounding on it to sign in.")
    }
}
