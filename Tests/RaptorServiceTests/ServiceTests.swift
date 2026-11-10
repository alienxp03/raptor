import XCTest
@testable import RaptorService

final class ServiceTests: XCTestCase {
    private func tempDir() -> String {
        NSTemporaryDirectory() + "raptor-service-\(UUID().uuidString)"
    }

    /// Go's servicePath layout with a pinned HOME.
    func testServicePathLayout() {
        let home = tempDir()
        setenv("HOME", home, 1)
        defer { unsetenv("HOME") }
        XCTAssertEqual(
            Service.servicePath(),
            home + "/.local/share/mise/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        )
    }

    func testPlistPathUsesCacheDir() {
        let cache = tempDir()
        setenv("XDG_CACHE_HOME", cache, 1)
        defer { unsetenv("XDG_CACHE_HOME") }
        XCTAssertEqual(Service.plistPath(), cache + "/raptor/launcher.plist")
    }

    func testDefinitionShape() {
        let home = tempDir()
        setenv("HOME", home, 1)
        defer { unsetenv("HOME") }
        let def = Service.definition(appExecutable: "/Applications/Raptor.app/Contents/MacOS/Raptor")
        XCTAssertEqual(def.keys.count, 9)
        XCTAssertEqual(def["Label"], .string("com.alienxp03.raptor.panel"))
        XCTAssertEqual(def["ProgramArguments"], .stringArray(["/Applications/Raptor.app/Contents/MacOS/Raptor", "serve"]))
        XCTAssertEqual(def["KeepAlive"], .bool(true))
        XCTAssertEqual(def["ThrottleInterval"], .int(2))
        XCTAssertEqual(def["ExitTimeOut"], .int(1))
        XCTAssertEqual(def["ProcessType"], .string("Interactive"))
        XCTAssertEqual(def["StandardOutPath"], .string("/dev/null"))
        XCTAssertEqual(def["StandardErrorPath"], .string(home + "/Library/Caches/raptor/service.log"))
        if case .dict(let env)? = def["EnvironmentVariables"] {
            XCTAssertEqual(env["PATH"], .string(Service.servicePath()))
        } else {
            XCTFail("EnvironmentVariables must be a dict")
        }
    }

    /// Byte-identical plist XML, keys sorted like Go's sortStrings.
    func testMarshalPlistMatchesGoOutput() throws {
        let home = tempDir()
        setenv("HOME", home, 1)
        defer { unsetenv("HOME") }
        let def = Service.definition(appExecutable: "/Applications/Raptor.app/Contents/MacOS/Raptor")
        let xml = String(data: try Service.marshalPlist(def), encoding: .utf8)!
        let want = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>EnvironmentVariables</key>
        <dict>
        <key>PATH</key>
        <string>\(home)/.local/share/mise/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        </dict>
        <key>ExitTimeOut</key>
        <integer>1</integer>
        <key>KeepAlive</key>
        <true/>
        <key>Label</key>
        <string>com.alienxp03.raptor.panel</string>
        <key>ProcessType</key>
        <string>Interactive</string>
        <key>ProgramArguments</key>
        <array>
        <string>/Applications/Raptor.app/Contents/MacOS/Raptor</string>
        <string>serve</string>
        </array>
        <key>StandardErrorPath</key>
        <string>\(home)/Library/Caches/raptor/service.log</string>
        <key>StandardOutPath</key>
        <string>/dev/null</string>
        <key>ThrottleInterval</key>
        <integer>2</integer>
        </dict>
        </plist>

        """
        XCTAssertEqual(xml, want)
    }

    func testXmlEscape() {
        XCTAssertEqual(Service.xmlEscape("a&b<c>d"), "a&amp;b&lt;c&gt;d")
    }

    func testInstallRejectsMissingExecutable() {
        let cache = tempDir()
        setenv("XDG_CACHE_HOME", cache, 1)
        defer { unsetenv("XDG_CACHE_HOME") }
        XCTAssertThrowsError(try Service.install(appPath: tempDir() + "/Missing.app")) { error in
            XCTAssertTrue("\(error)".contains("not a Raptor app executable"), "\(error)")
        }
    }
}
