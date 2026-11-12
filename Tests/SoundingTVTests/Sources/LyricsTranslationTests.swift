import Foundation
import XCTest
@testable import SoundingTV

final class LyricsTranslationTests: XCTestCase {
    private let lines: [LyricLine] = [
        LyricLine(id: 0, text: "Te quiero", start: 12.5, end: 15, words: [
            LyricWord(text: "Te ", start: 12.5, end: 13),
            LyricWord(text: "quiero", start: 13, end: 15),
        ]),
        LyricLine(id: 1, text: "", start: 15.2),
        LyricLine(id: 2, text: "Bajo la luna ", start: 30.1),
        LyricLine(id: 3, text: "Te quiero", start: 44.75, end: 47),
    ]

    func testSourceTextsAreTrimmedUniqueAndSkipBlanks() {
        XCTAssertEqual(LyricsTranslation.sourceTexts(.synced(lines)), ["Te quiero", "Bajo la luna"])
        XCTAssertEqual(LyricsTranslation.sourceTexts(.plain(["Hola", "", " Hola ", "Adiós"])), ["Hola", "Adiós"])
        XCTAssertEqual(LyricsTranslation.sourceTexts(.instrumental), [])
    }

    func testTranslationKeepsEveryLinesTiming() {
        let translation = LyricsTranslation(target: "en", pairs: [
            (source: "Te quiero", translated: "I love you"),
            (source: "Bajo la luna", translated: "Under the moon"),
        ])
        let annotated = translation.annotate(lines)
        XCTAssertEqual(annotated.map(\.line), lines)
        XCTAssertEqual(annotated.map(\.translation), ["I love you", nil, "Under the moon", "I love you"])
        XCTAssertEqual(annotated[0].line.words, lines[0].words)
        XCTAssertEqual(annotated[3].line.start, 44.75)
        XCTAssertEqual(LyricsTimeline.displayLines(annotated.map(\.line)), LyricsTimeline.displayLines(lines))
    }

    func testLookupIgnoresSurroundingWhitespace() {
        let translation = LyricsTranslation(target: "en", pairs: [(source: " Bajo la luna", translated: " Under the moon ")])
        XCTAssertEqual(translation.text(for: "Bajo la luna  "), "Under the moon")
        XCTAssertNil(translation.text(for: "Otra línea"))
    }

    func testUntranslatedAndEmptyResultsAreDropped() {
        let translation = LyricsTranslation(target: "en", pairs: [
            (source: "Oh, oh, oh", translated: "oh, oh, oh"),
            (source: "Señor", translated: "senor"),
            (source: "Bajo la luna", translated: "   "),
            (source: "Te quiero", translated: "I love you"),
        ])
        XCTAssertEqual(translation.byText, ["Te quiero": "I love you"])
        XCTAssertFalse(translation.isEmpty)
        XCTAssertTrue(LyricsTranslation(target: "en", pairs: []).isEmpty)
    }

    func testOnlyOffersTranslationBetweenDifferentLanguages() {
        XCTAssertTrue(LyricsTranslation.needsTranslation(source: "es", target: "en-GB"))
        XCTAssertTrue(LyricsTranslation.needsTranslation(source: "ja", target: "en"))
        XCTAssertFalse(LyricsTranslation.needsTranslation(source: "en", target: "en-GB"))
        XCTAssertFalse(LyricsTranslation.needsTranslation(source: "zh-Hans", target: "zh-Hant"))
    }

    func testDetectsTheLyricsLanguage() {
        let spanish = [
            "Bajo la luna te espero cada noche",
            "Y el viento canta tu nombre en la calle",
            "No sé vivir sin tus ojos, mi amor",
            "Quédate conmigo hasta que salga el sol",
        ]
        XCTAssertEqual(LyricsTranslation.detectLanguage(spanish), "es")
        XCTAssertNil(LyricsTranslation.detectLanguage(["Oh"]))
    }
}
