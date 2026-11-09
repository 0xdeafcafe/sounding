import Foundation

// SubscriptionProbe — run the app's subscription logic from a terminal.
//
//   swift run SubscriptionProbe selftest        # run SubscriptionSelfTest
//   swift run SubscriptionProbe resolve <file>  # resolve a real /me body
//   cat me.json | swift run SubscriptionProbe resolve -
//
// `resolve` is the one that answers "why doesn't the app know my plan?". Save
// a `/me` response to a file and point this at it: it prints the tier the app
// would pick, why, and the raw subscription payload verbatim.
//
// Deliberately has no way to authenticate. It never asks for, reads, stores or
// transmits a token, cookie or password — you bring it a JSON body you already
// have. Keeping credentials out of this tool is the point, not an omission.

// MARK: - Output helpers

func emit(_ text: String) {
    print(text)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(2)
}

// MARK: - Commands

func runSelfTest() -> Never {
    #if DEBUG
    let report = SubscriptionSelfTest.run()
    emit(report.summary)
    emit("")
    emit("\(report.lines.count) checks passed, \(report.failures.count) failed.")
    exit(report.failures.isEmpty ? 0 : 1)
    #else
    fail("built without DEBUG, so SubscriptionSelfTest is not compiled in. Use a debug build.")
    #endif
}

/// Decodes a `/me` body into the app's real `User` model.
///
/// Falls back to wrapping a bare subscription fragment in a synthetic user so
/// a partial paste still works — the subscription keys are what matter, and
/// requiring a pristine full `/me` would make this annoying to use in the one
/// situation it exists for.
func decodeUser(from data: Data) -> User {
    let decoder = JSONDecoder()
    if let user = try? decoder.decode(User.self, from: data) {
        return user
    }

    guard let object = try? JSONSerialization.jsonObject(with: data),
          var dictionary = object as? [String: Any] else {
        fail("input is not a JSON object.")
    }

    // Some captures nest the account under "user".
    if let nested = dictionary["user"] as? [String: Any],
       nested["consumer_subscriptions"] != nil || nested["consumer_subscription"] != nil
        || nested["creator_subscriptions"] != nil || nested["creator_subscription"] != nil {
        dictionary = nested
    }

    // Fill in only the fields `User` requires, preserving every subscription
    // key exactly as given.
    let synthetic: [String: Any] = dictionary.merging([
        "id": dictionary["id"] ?? 0,
        "username": dictionary["username"] ?? "unknown",
        "permalink": dictionary["permalink"] ?? "unknown",
        "permalink_url": dictionary["permalink_url"] ?? "https://soundcloud.com/unknown",
    ]) { current, _ in current }

    guard let patched = try? JSONSerialization.data(withJSONObject: synthetic),
          let user = try? decoder.decode(User.self, from: patched) else {
        fail("could not read a user out of that JSON. Pass a full /me response body.")
    }
    return user
}

func runResolve(path: String) -> Never {
    let data: Data
    if path == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        guard let contents = FileManager.default.contents(atPath: path) else {
            fail("could not read \(path)")
        }
        data = contents
    }
    guard !data.isEmpty else { fail("no input.") }

    let user = decodeUser(from: data)
    let resolution = SubscriptionService.resolve(from: user)
    let raw = SubscriptionService.rawSubscriptionDescription(for: user)

    emit("Resolved tier : \(resolution.tier.rawValue)")
    if let reason = resolution.unknownReason {
        emit("Why unknown   : \(reason)")
    }
    emit("Grants Go+    : \(resolution.tier == .goPlus ? "yes" : "no")")
    emit("")
    emit("Raw subscription payload as sent by api-v2:")
    emit(raw ?? "(none)")

    if case .unrecognisedProductIDs(let ids) = resolution.unknownReason {
        emit("")
        emit("These product ids are not in the catalogue yet:")
        for id in ids { emit("  - \(id)") }
        emit("Add them to SubscriptionService's product-id catalogue.")
    }
    exit(0)
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil, "selftest":
    runSelfTest()
case "resolve":
    guard arguments.count >= 2 else {
        fail("resolve needs a path to a /me JSON body, or - for stdin.")
    }
    runResolve(path: arguments[1])
case "help", "--help", "-h":
    emit("""
    SubscriptionProbe — exercise Sounding's subscription tier logic.

      selftest            Run SubscriptionSelfTest (default).
      resolve <file|->    Resolve a captured /me JSON body to a tier.

    Never handles credentials. Give it a response body you already have.
    """)
    exit(0)
default:
    fail("unknown command \"\(arguments[0])\". Try: help")
}
