import os

enum Log {
    private static let subsystem = "red.forbes.sounding"

    static let api = Logger(subsystem: subsystem, category: "api")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let player = Logger(subsystem: subsystem, category: "player")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let dj = Logger(subsystem: subsystem, category: "dj")
    static let analysis = Logger(subsystem: subsystem, category: "analysis")
    static let download = Logger(subsystem: subsystem, category: "download")
    static let link = Logger(subsystem: subsystem, category: "link")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let cues = Logger(subsystem: subsystem, category: "cues")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let topShelf = Logger(subsystem: subsystem, category: "topShelf")
}
