import XCTest
@testable import SoundingTV

@MainActor
final class SynchronizationGatewayTests: XCTestCase {
    func testLatestLaneCoalescesPendingSnapshots() async {
        let gateway = SynchronizationGateway.shared
        await gateway.flush(.companionContinuous)
        let key = "test.latest.\(UUID().uuidString)"
        var delivered: [Int] = []

        gateway.submit(lane: .companionContinuous, key: key) {
            delivered.append(1)
        }
        gateway.submit(lane: .companionContinuous, key: key) {
            delivered.append(2)
        }
        gateway.submit(lane: .companionContinuous, key: key) {
            delivered.append(3)
        }

        await gateway.flush(.companionContinuous)
        XCTAssertEqual(delivered, [3])
    }

    func testReliableLanePreservesCommandOrder() async {
        let gateway = SynchronizationGateway.shared
        await gateway.flush(.companionCommand)
        let key = "test.reliable.\(UUID().uuidString)"
        var delivered: [Int] = []

        gateway.submit(lane: .companionCommand, key: key) {
            delivered.append(1)
        }
        gateway.submit(lane: .companionCommand, key: key) {
            delivered.append(2)
        }
        gateway.submit(lane: .companionCommand, key: key) {
            delivered.append(3)
        }

        await gateway.flush(.companionCommand)
        XCTAssertEqual(delivered, [1, 2, 3])
    }

    func testDeliveredFingerprintSuppressesDuplicateState() async {
        let gateway = SynchronizationGateway.shared
        await gateway.flush(.companionState)
        let key = "test.fingerprint.\(UUID().uuidString)"
        var deliveryCount = 0

        gateway.submit(lane: .companionState, key: key, fingerprint: 42) {
            deliveryCount += 1
        }
        await gateway.flush(.companionState)
        gateway.submit(lane: .companionState, key: key, fingerprint: 42) {
            deliveryCount += 1
        }
        await gateway.flush(.companionState)

        XCTAssertEqual(deliveryCount, 1)
    }

    func testDisconnectCancelsDelayedOwnerSnapshots() async {
        let gateway = SynchronizationGateway.shared
        await gateway.flush(.companionState)
        let owner = "test.cancel.\(UUID().uuidString)"
        var didDeliver = false

        gateway.submit(lane: .companionState, key: "\(owner).playback") {
            didDeliver = true
        }
        gateway.cancel(keyPrefix: owner)
        await gateway.flush(.companionState)

        XCTAssertFalse(didDeliver)
    }
}
