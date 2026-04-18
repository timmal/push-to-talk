import XCTest
@testable import PushToTalkCore

final class TextCleanerTests: XCTestCase {
    func test_removesRussianFillers() {
        XCTAssertEqual(TextCleaner.clean("ну эээ я пошел"), "Я пошел.")
    }
    func test_removesEnglishFillers() {
        XCTAssertEqual(TextCleaner.clean("uhm I think uh we should go"), "I think we should go.")
    }
    func test_collapsesStutter() {
        XCTAssertEqual(TextCleaner.clean("я я я думаю"), "Я думаю.")
    }
    func test_preservesMixedEnglishTokens() {
        let out = TextCleaner.clean("у нас созвон в zoom с product manager")
        XCTAssertTrue(out.contains("zoom"))
        XCTAssertTrue(out.contains("product manager"))
    }
    func test_normalizesWhitespaceAndPunctuation() {
        XCTAssertEqual(TextCleaner.clean("   привет    мир"), "Привет мир.")
    }
    func test_preservesExistingPunctuation() {
        XCTAssertEqual(TextCleaner.clean("это вопрос?"), "Это вопрос?")
    }
    func test_returnsEmptyForWhitespaceOnly() {
        XCTAssertEqual(TextCleaner.clean("   "), "")
    }
    func test_removesLikeFiller() {
        // "like" as filler — rule is aggressive; accept removal for v1
        XCTAssertEqual(TextCleaner.clean("I like pizza"), "I pizza.")
    }
}
