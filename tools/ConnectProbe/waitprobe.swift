import Foundation
import Network

// Premise check for TASK #91: when an NWConnection cannot reach its peer,
// does it report `.failed` (which RemoteQueueClient already handled) or park
// in `.waiting` (which it did not)?
//
// 192.0.2.0/24 is TEST-NET-1 (RFC 5737) — guaranteed not routable to a real
// host, so this models "the TV was resolved by Bonjour, then went away"
// without needing a second device or any teardown of a live service.

let host = NWEndpoint.Host("192.0.2.1")
let port = NWEndpoint.Port(rawValue: 55555)!

let params = NWParameters.tcp
params.includePeerToPeer = false
if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 5
    tcp.keepaliveInterval = 3
    tcp.keepaliveCount = 3
}

let conn = NWConnection(host: host, port: port, using: params)
let start = Date()
var sawWaiting = false
var sawFailed = false
var sawReady = false

func stamp() -> String { String(format: "%6.2fs", Date().timeIntervalSince(start)) }

conn.stateUpdateHandler = { state in
    switch state {
    case .preparing:
        print("[\(stamp())] .preparing")
    case .waiting(let error):
        sawWaiting = true
        print("[\(stamp())] .waiting  -> \(error) | localizedDescription: \(error.localizedDescription)")
    case .ready:
        sawReady = true
        print("[\(stamp())] .ready")
    case .failed(let error):
        sawFailed = true
        print("[\(stamp())] .failed   -> \(error)")
    case .cancelled:
        print("[\(stamp())] .cancelled")
    default:
        print("[\(stamp())] \(state)")
    }
}

conn.start(queue: .main)

// Observe for 20s — longer than the 15s connectTimeout the fix installs, so
// we can see whether anything would ever have rescued this on its own.
DispatchQueue.main.asyncAfter(deadline: .now() + 100) {
    print("")
    print("=== TASK #91 premise check, after 100s ===")
    print("reached .ready   : \(sawReady)")
    print("reached .failed  : \(sawFailed)")
    print("entered .waiting : \(sawWaiting)")
    print("")
    if sawWaiting && !sawFailed && !sawReady {
        print("RESULT: unbounded .waiting confirmed — 100s with no terminal state.")
        print("        A `.failed`-only handler never fires. The connect timeout is required.")
    } else if sawFailed {
        print("RESULT: reached .failed — the pre-existing handler would have caught this.")
    } else {
        print("RESULT: inconclusive — see trace above.")
    }
    conn.cancel()
    exit(0)
}

RunLoop.main.run()
