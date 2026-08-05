import Foundation
import CoreGraphics
import UIKit

@main
struct Harness {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 5 else {
            print("usage: harness <legacy|store|prefetch> <base-url> <count> <cache-dir>")
            exit(64)
        }
        let mode = args[1]
        let base = args[2]
        let imageCount = Int(args[3]) ?? 24
        let cacheDir = URL(fileURLWithPath: args[4], isDirectory: true)

        let urls = (0..<imageCount).map { URL(string: "\(base)/art/\($0).jpg")! }

        switch mode {
        case "legacy":
            let started = Date()
            let delivered = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for url in urls {
                    group.addTask { @MainActor in
                        await LegacyArtworkCache.shared.image(for: url, variant: .standard) != nil
                    }
                }
                var ok = 0
                for await success in group where success { ok += 1 }
                return ok
            }
            report(mode: mode, delivered: delivered, total: imageCount, elapsed: Date().timeIntervalSince(started))

        case "store":
            let store = SCArtworkStore(directory: cacheDir)
            let started = Date()
            let delivered = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for url in urls {
                    group.addTask {
                        await store.cgImage(for: url, variant: .standard) != nil
                    }
                }
                var ok = 0
                for await success in group where success { ok += 1 }
                return ok
            }
            report(mode: mode, delivered: delivered, total: imageCount, elapsed: Date().timeIntervalSince(started))

        case "prefetch":
            let store = SCArtworkStore(directory: cacheDir)
            let prefetchStarted = Date()
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask {
                        _ = await store.prefetchImage(for: url, variant: .standard)
                    }
                }
                await group.waitForAll()
            }
            let prefetchElapsed = Date().timeIntervalSince(prefetchStarted)

            let started = Date()
            let delivered = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for url in urls {
                    group.addTask {
                        await store.cgImage(for: url, variant: .standard) != nil
                    }
                }
                var ok = 0
                for await success in group where success { ok += 1 }
                return ok
            }
            print(String(format: "RESULT mode=prefetch prefetch_elapsed=%.3f", prefetchElapsed))
            report(mode: mode, delivered: delivered, total: imageCount, elapsed: Date().timeIntervalSince(started))

        default:
            print("unknown mode \(mode)")
            exit(64)
        }
    }

    static func report(mode: String, delivered: Int, total: Int, elapsed: TimeInterval) {
        print(String(format: "RESULT mode=%@ delivered=%d/%d elapsed=%.3f", mode, delivered, total, elapsed))
    }
}
