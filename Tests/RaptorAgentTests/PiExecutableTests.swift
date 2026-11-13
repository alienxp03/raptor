import Foundation
import XCTest
@testable import RaptorAgent

final class PiExecutableTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("aux/pi-executable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ contents: String, executable: Bool = false) throws -> URL {
        let path = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: path)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path) }
        return path
    }

    private func installation() throws -> (package: URL, binary: URL) {
        let package = root.appendingPathComponent("install with spaces/lib/node_modules/@earendil-works/pi-coding-agent")
        _ = try write("install with spaces/lib/node_modules/@earendil-works/pi-coding-agent/package.json",
                      #"{"name":"@earendil-works/pi-coding-agent"}"#)
        let binary = try write("install with spaces/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js",
                               "#!/bin/sh\nexit 0\n", executable: true)
        let link = root.appendingPathComponent("install with spaces/bin/pi")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        return (package, link)
    }

    private func shim(managerOutput: String, status: Int = 0) throws -> URL {
        let manager = try write("manager/mise", """
        #!/bin/sh
        printf '%s\\n' "$*" > '\(root.path)/manager-args'
        pwd > '\(root.path)/manager-cwd'
        printf '%s\\n' '\(managerOutput)'
        exit \(status)
        """, executable: true)
        let path = root.appendingPathComponent("shims/pi")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: manager)
        return path
    }

    func testNormalPiSymlinkFindsPackageWithoutManager() throws {
        let installed = try installation()
        XCTAssertEqual(PiModels.packageRoot(piPath: installed.binary.path), installed.package.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("manager-args").path))
    }

    func testMiseShimUsesItsOwnManagerAndRequestedDirectory() throws {
        let installed = try installation()
        let pi = try shim(managerOutput: installed.binary.path)
        XCTAssertEqual(PiModels.packageRoot(piPath: pi.path, cwd: root.path), installed.package.path)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("manager-args"), encoding: .utf8), "which pi\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("manager-cwd"), encoding: .utf8), root.path + "\n")
    }

    func testFailedManagerDoesNotUseItsOutput() throws {
        let installed = try installation()
        let pi = try shim(managerOutput: installed.binary.path, status: 1)
        XCTAssertNil(PiModels.packageRoot(piPath: pi.path))
    }

    func testManagerMustReturnAnExecutableInThePiPackage() throws {
        let other = try write("other/pi", "#!/bin/sh\nexit 0\n", executable: true)
        let pi = try shim(managerOutput: other.path)
        XCTAssertNil(PiModels.packageRoot(piPath: pi.path))
    }

    func testRelativeManagerOutputIsRejected() throws {
        let pi = try shim(managerOutput: "relative/bin/pi")
        XCTAssertNil(PiModels.packageRoot(piPath: pi.path))
    }
}
