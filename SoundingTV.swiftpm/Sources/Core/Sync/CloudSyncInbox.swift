import Foundation

actor CloudSyncInbox<Record: Sendable> {
    private var buffered: [Record] = []
    func append(_ records: [Record]) { buffered.append(contentsOf: records) }
    func drain() -> [Record] {
        defer { buffered.removeAll() }
        return buffered
    }
}
