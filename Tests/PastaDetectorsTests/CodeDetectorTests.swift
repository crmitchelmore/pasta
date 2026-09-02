import PastaCore
import XCTest
@testable import PastaDetectors

final class CodeDetectorTests: XCTestCase {
    private let detector = CodeDetector()

    private static let swiftSnippet = """
    import SwiftUI
    struct ContentView: View {
        var body: some View { Text(\"Hi\") }
    }
    """

    private static let jsonSnippet = #"{"a":1,"b":[true,false]}"#

    /// One representative snippet per language; each must be classified as that language.
    private static let languageCases: [(snippet: String, language: CodeLanguage)] = [
        (swiftSnippet, .swift),
        (
            """
            def hello():
                print('hi')
            """,
            .python
        ),
        (
            """
            const fn = () => console.log('hi');
            export function hello() { return 1; }
            """,
            .javaScript
        ),
        (
            """
            interface User { id: number }
            const u: User = { id: 1 }
            """,
            .typeScript
        ),
        (
            """
            package main
            import \"fmt\"
            func main() { fmt.Println(\"hi\") }
            """,
            .go
        ),
        (
            """
            fn main() {
                println!(\"hi\");
            }
            """,
            .rust
        ),
        (
            """
            public class Main {
                public static void main(String[] args) {
                    System.out.println(\"hi\");
                }
            }
            """,
            .java
        ),
        (
            """
            #include <stdio.h>
            int main() { return 0; }
            """,
            .cCpp
        ),
        (
            """
            def hello
              puts 'hi'
            end
            """,
            .ruby
        ),
        ("SELECT * FROM users WHERE id = 1;", .sql),
        (jsonSnippet, .json),
        (
            """
            name: Pasta
            version: 1
            items:
              - a
            """,
            .yaml
        ),
        ("<html><body>Hello</body></html>", .html),
        ("body { color: red; }", .css),
        (
            """
            export FOO=bar
            cd /tmp
            echo hi
            """,
            .shell
        ),
    ]

    func testDetectsEachLanguage() {
        for testCase in Self.languageCases {
            XCTAssertEqual(
                detector.detect(in: testCase.snippet).first?.language,
                testCase.language,
                "Expected \(testCase.language) for:\n\(testCase.snippet)"
            )
        }
    }

    func testSwiftDetectionIsHighConfidence() {
        let detection = detector.detect(in: Self.swiftSnippet).first
        XCTAssertEqual(detection?.language, .swift)
        XCTAssertGreaterThanOrEqual(detection?.confidence ?? 0, 0.8)
    }

    func testJSONDetectionIsHighConfidence() {
        let detection = detector.detect(in: Self.jsonSnippet).first
        XCTAssertEqual(detection?.language, .json)
        XCTAssertGreaterThanOrEqual(detection?.confidence ?? 0, 0.9)
    }
}
