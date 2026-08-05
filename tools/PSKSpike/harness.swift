// PSKSpike harness — measures what the platform TLS stack actually
// negotiates for `sec_protocol_options_add_pre_shared_key`, on-device (via
// simulator), for TASK #90. Mirrors PairingTLS.configure(_:sessionId:secret:)
// in SoundingTV.swiftpm/Sources/Services/TokenTransferProtocol.swift.
//
// Not linked against the app; standalone `swiftc` harness per CLAUDE.md
// precedent. Builds two NWListener/NWConnection loopback pairs, both ends
// configured identically (as the shipped code requires), and reports:
//   1. Does min == max == .TLSv13 with only a PSK configured complete?
//   2. What does the shipped 1.2 + 0xCCAC config actually negotiate, read
//      back from sec_protocol_metadata_get_negotiated_tls_ciphersuite /
//      ..._protocol_version on a COMPLETED handshake?
//
// Never logs the PSK bytes or anything derived from them — only pass/fail
// and the negotiated version/ciphersuite codepoints.
//
// How to run (repeat per platform — this is the whole point, a macOS-only
// run is not an answer for tvOS/iOS):
//
//   macOS:
//     xcrun swiftc harness.swift -o /tmp/psk-harness-macos
//     /tmp/psk-harness-macos
//
//   tvOS/iOS simulator — swiftc targets the simulator SDK directly, and
//   `simctl spawn` runs the binary inside a booted simulator of your own
//   (never reuse a simulator another agent/session might be holding):
//     xcrun simctl create PSKSpikeTV27 \
//       "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p" \
//       "com.apple.CoreSimulator.SimRuntime.tvOS-27-0"
//     xcrun simctl boot <udid-just-printed>
//     xcrun swiftc -target arm64-apple-tvos27.0-simulator \
//       -sdk "$(xcrun --sdk appletvsimulator --show-sdk-path)" \
//       harness.swift -o /tmp/psk-harness-tvos
//     xcrun simctl spawn <udid> /tmp/psk-harness-tvos
//     xcrun simctl delete <udid>   # clean up when done
//
//   Same shape for iOS with `-target arm64-apple-ios27.0-simulator`,
//   `--sdk iphonesimulator`, and an iPhone device type / iOS runtime id.
//
// Last run (2026-07-31, Xcode 27.0 / build 27A5228h): TLS 1.3-only PSK still
// fails closed on all three platforms (macOS 27 build 26A5388g, tvOS 27
// build 24J5325d, iOS 27 build 24A5390f) — error -9858 (errSSLPeerInternalError),
// though on the 27 SDK it now surfaces via a persistent NWConnection
// `.waiting` state rather than an immediate `.failed` the way it did on 26
// (this harness treats a `.waiting` that doesn't clear within ~1.5s as
// terminal). The shipped 1.2 + 0xCCAC config negotiates unchanged: version
// 0x0303, ciphersuite 0xCCAC. See TASK #90 for the full readout.

import Network
import CryptoKit
import Foundation

// Throwaway constants for this harness only — NOT a real pairing secret.
let harnessSecret = Data("PSKSpike-not-a-real-secret-0001".utf8)
let harnessSessionId = "psk-spike-session"

func derivePSK(secret: Data, sessionId: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: secret),
        salt: Data(sessionId.utf8),
        info: Data("SoundingTV-Pairing-TLS-PSK-v1".utf8),
        outputByteCount: 32
    )
}

enum VersionPin {
    case tls13Only
    case tls12PinnedWithCCAC
}

func configure(_ options: sec_protocol_options_t, pin: VersionPin) {
    let pskKey = derivePSK(secret: harnessSecret, sessionId: harnessSessionId)
    let pskData = pskKey.withUnsafeBytes { Data($0) }
    let identityData = Data(harnessSessionId.utf8)

    let pskDispatchData = pskData.withUnsafeBytes { DispatchData(bytes: $0) }
    let identityDispatchData = identityData.withUnsafeBytes { DispatchData(bytes: $0) }

    sec_protocol_options_add_pre_shared_key(
        options,
        pskDispatchData as __DispatchData,
        identityDispatchData as __DispatchData
    )

    switch pin {
    case .tls13Only:
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        // Deliberately do NOT pin a ciphersuite here — TLS 1.3 external PSK
        // per RFC 8446 negotiates via the generic AEAD suite list, not the
        // PSK-ciphersuite family. Let the stack pick to see if 1.3 external
        // PSK works AT ALL first.
    case .tls12PinnedWithCCAC:
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0xCCAC)!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
    }
}

struct HandshakeResult {
    var completed = false
    var error: String?
    var negotiatedVersionRaw: UInt16?
    var negotiatedCiphersuiteRaw: UInt16?
}

/// Runs one listener+connection pair over loopback with the given pin,
/// waits for completion or failure, and reports what actually negotiated.
func runTrial(pin: VersionPin, label: String) -> HandshakeResult {
    var result = HandshakeResult()
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "psk-spike.\(label)")
    let doneLock = NSLock()
    var isDone = false

    func finishOnce(_ block: () -> Void) {
        doneLock.lock()
        defer { doneLock.unlock() }
        guard !isDone else { return }
        isDone = true
        block()
    }

    let tlsOptionsServer = NWProtocolTLS.Options()
    configure(tlsOptionsServer.securityProtocolOptions, pin: pin)
    let serverParams = NWParameters(tls: tlsOptionsServer, tcp: NWProtocolTCP.Options())
    serverParams.includePeerToPeer = false
    serverParams.allowLocalEndpointReuse = true

    guard let listener = try? NWListener(using: serverParams) else {
        result.error = "listener construction failed"
        return result
    }

    group.enter() // for overall completion
    var connectionHandled = false

    listener.newConnectionHandler = { conn in
        guard !connectionHandled else { return }
        connectionHandled = true
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Server side reached ready too; nothing more needed from it.
                break
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    listener.stateUpdateHandler = { state in
        if case .failed(let err) = state {
            finishOnce {
                result.error = "listener failed: \(err)"
                group.leave()
            }
        }
    }

    listener.start(queue: queue)

    // Give the listener a moment to bind before connecting.
    let listenerReadySem = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
        if case .ready = state {
            listenerReadySem.signal()
        } else if case .failed(let err) = state {
            finishOnce {
                result.error = "listener failed: \(err)"
                group.leave()
            }
            listenerReadySem.signal()
        }
    }
    _ = listenerReadySem.wait(timeout: .now() + 5)

    guard let port = listener.port else {
        finishOnce {
            result.error = "listener has no port"
            group.leave()
        }
        _ = group.wait(timeout: .now() + 1)
        listener.cancel()
        return result
    }

    let tlsOptionsClient = NWProtocolTLS.Options()
    configure(tlsOptionsClient.securityProtocolOptions, pin: pin)
    let clientParams = NWParameters(tls: tlsOptionsClient, tcp: NWProtocolTCP.Options())
    clientParams.includePeerToPeer = false

    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
    let clientConn = NWConnection(to: endpoint, using: clientParams)

    clientConn.stateUpdateHandler = { state in
        switch state {
        case .ready:
            finishOnce {
                result.completed = true
                if let metadata = clientConn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                    let secMetadata = metadata.securityProtocolMetadata
                    result.negotiatedVersionRaw = sec_protocol_metadata_get_negotiated_tls_protocol_version(secMetadata).rawValue
                    result.negotiatedCiphersuiteRaw = sec_protocol_metadata_get_negotiated_tls_ciphersuite(secMetadata).rawValue
                }
                group.leave()
            }
        case .failed(let err):
            finishOnce {
                result.error = "\(err)"
                group.leave()
            }
        case .waiting(let err):
            // On the 27 SDK this is where a PSK/version mismatch actually
            // surfaces: NWConnection treats the TLS handshake failure as
            // retryable and stays in `.waiting` (indefinitely retrying)
            // rather than transitioning to `.failed` the way it did on the
            // 26 SDK. Capture the underlying error and give it a short
            // grace period in case it is a genuinely transient condition,
            // then treat a persistent `.waiting` with a TLS-shaped error as
            // the answer.
            FileHandle.standardError.write("  [\(label)] client .waiting: \(err)\n".data(using: .utf8)!)
            let capturedDescription = "\(err)"
            queue.asyncAfter(deadline: .now() + 1.5) {
                finishOnce {
                    result.error = "persistent .waiting (handshake did not complete): \(capturedDescription)"
                    group.leave()
                }
            }
        case .preparing:
            FileHandle.standardError.write("  [\(label)] client .preparing\n".data(using: .utf8)!)
        default:
            break
        }
    }

    clientConn.start(queue: queue)

    let waitResult = group.wait(timeout: .now() + 12)
    if waitResult == .timedOut {
        finishOnce {
            result.error = "timed out waiting for handshake to complete or fail (12s)"
        }
    }

    clientConn.cancel()
    listener.cancel()
    Thread.sleep(forTimeInterval: 0.2) // let cancellation settle before next trial reuses the port range

    return result
}

func describeVersion(_ raw: UInt16?) -> String {
    guard let raw else { return "nil" }
    switch raw {
    case 0x0301: return "0x0301 (TLS 1.0)"
    case 0x0302: return "0x0302 (TLS 1.1)"
    case 0x0303: return "0x0303 (TLS 1.2)"
    case 0x0304: return "0x0304 (TLS 1.3)"
    default: return String(format: "0x%04X (unknown)", raw)
    }
}

func describeCiphersuite(_ raw: UInt16?) -> String {
    guard let raw else { return "nil" }
    switch raw {
    case 0xCCAC: return "0xCCAC (TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256)"
    case 0x1301: return "0x1301 (TLS_AES_128_GCM_SHA256)"
    case 0x1302: return "0x1302 (TLS_AES_256_GCM_SHA384)"
    case 0x1303: return "0x1303 (TLS_CHACHA20_POLY1305_SHA256)"
    case 0x00A8: return "0x00A8 (TLS_PSK_WITH_AES_128_GCM_SHA256)"
    default: return String(format: "0x%04X (unknown)", raw)
    }
}

print("=== PSKSpike / TASK #90 — TLS-PSK negotiation on \(ProcessInfo.processInfo.operatingSystemVersionString) ===")
#if os(tvOS)
print("platform: tvOS")
#elseif os(iOS)
print("platform: iOS")
#elseif os(macOS)
print("platform: macOS")
#endif

print("\n--- Trial 1: min == max == .TLSv13, PSK only, no ciphersuite pin ---")
let t1 = runTrial(pin: .tls13Only, label: "tls13")
print("completed: \(t1.completed)")
print("error: \(t1.error ?? "none")")
print("negotiated version: \(describeVersion(t1.negotiatedVersionRaw))")
print("negotiated ciphersuite: \(describeCiphersuite(t1.negotiatedCiphersuiteRaw))")

print("\n--- Trial 2: shipped config — min == max == .TLSv12, 0xCCAC only ---")
let t2 = runTrial(pin: .tls12PinnedWithCCAC, label: "tls12ccac")
print("completed: \(t2.completed)")
print("error: \(t2.error ?? "none")")
print("negotiated version: \(describeVersion(t2.negotiatedVersionRaw))")
print("negotiated ciphersuite: \(describeCiphersuite(t2.negotiatedCiphersuiteRaw))")

print("\n=== DONE ===")
