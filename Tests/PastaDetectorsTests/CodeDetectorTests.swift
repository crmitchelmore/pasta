import XCTest
@testable import PastaDetectors

final class CodeDetectorTests: XCTestCase {
    func testDetectSwift() {
        let detector = CodeDetector()
        let code = """
        import SwiftUI
        struct ContentView: View {
            var body: some View { Text(\"Hi\") }
        }
        """
        let detection = detector.detect(in: code).first
        XCTAssertEqual(detection?.language, .swift)
        XCTAssertGreaterThanOrEqual(detection?.confidence ?? 0, 0.8)
    }

    func testDetectPython() {
        let detector = CodeDetector()
        let code = """
        def hello():
            print('hi')
        """
        XCTAssertEqual(detector.detect(in: code).first?.language, .python)
    }

    func testDetectJavaScript() {
        let detector = CodeDetector()
        let code = """
        const fn = () => console.log('hi');
        export function hello() { return 1; }
        """
        XCTAssertEqual(detector.detect(in: code).first?.language, .javaScript)
    }

    func testDetectTypeScript() {
        let detector = CodeDetector()
        let code = """
        interface User { id: number }
        const u: User = { id: 1 }
        """
        XCTAssertEqual(detector.detect(in: code).first?.language, .typeScript)
    }

    func testDetectGo() {
        let detector = CodeDetector()
        let code = """
        package main
        import \"fmt\"
        func main() { fmt.Println(\"hi\") }
        """
        XCTAssertEqual(detector.detect(in: code).first?.language, .go)
    }

    func testDetectRust() {
        let detector = CodeDetector()
        let code = """
        fn main() {
            println!(\"hi\");
        }
        """
        XCTAssertEqual(detector.detect(in: code).first?.language, .rust)
    }

    func testDetectJava() {
        let detector = CodeDetector()
        let code = """
        public class Main {
            public static void main(String[] args) {
                System.out.println(\"hi\");
            }
        }
        """
        XCTAssertEqual(detector.detect(in: code).first?.language, .java)
    }

    func testDetectCCpp() {
        let detector = CodeDetector()
        let code = """
        #include <stdio.h>
        int main() { return 0; }
        """
        XCTAssertEqual(detector.detect(in: code).first?.language, .cCpp)
    }

    func testDetectRuby() {
        let detector = CodeDetector()
        let code = """
        def hello
          puts 'hi'
        end
        """
        XCTAssertEqual(detector.detect(in: code).first?.language, .ruby)
    }

    func testDetectSQL() {
        let detector = CodeDetector()
        let code = "SELECT * FROM users WHERE id = 1;"
        XCTAssertEqual(detector.detect(in: code).first?.language, .sql)
    }

    func testDetectJSON() {
        let detector = CodeDetector()
        let code = #"{"a":1,"b":[true,false]}"#
        let detection = detector.detect(in: code).first
        XCTAssertEqual(detection?.language, .json)
        XCTAssertGreaterThanOrEqual(detection?.confidence ?? 0, 0.9)
    }

    func testDetectYAML() {
        let detector = CodeDetector()
        let code = """
        name: Pasta
        version: 1
        items:
          - a
        """
        XCTAssertEqual(detector.detect(in: code).first?.language, .yaml)
    }

    func testDetectHTML() {
        let detector = CodeDetector()
        let code = "<html><body>Hello</body></html>"
        XCTAssertEqual(detector.detect(in: code).first?.language, .html)
    }

    func testDetectCSS() {
        let detector = CodeDetector()
        let code = "body { color: red; }"
        XCTAssertEqual(detector.detect(in: code).first?.language, .css)
    }

    func testDetectShell() {
        let detector = CodeDetector()
        let code = """
        export FOO=bar
        cd /tmp
        echo hi
        """
        XCTAssertEqual(detector.detect(in: code).first?.language, .shell)
    }
}
