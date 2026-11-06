import XCTest
import Darwin
@testable import DeskCapture

final class SavePanelPresentationTests: XCTestCase {
    // Use a real independent AppKit run loop instead of inheriting the test
    // host's modal sessions and remote file-panel connections.
    private static let fixture = #"""
    import AppKit
    @MainActor final class Fixture: NSObject, NSApplicationDelegate {
        let directory: URL, report: URL
        init(_ directory: URL, _ report: URL) { self.directory=directory; self.report=report }
        func applicationDidFinishLaunching(_ notification: Notification) {
            Task {
                var result: [String:Any] = ["success":false]
                do { result = try await verify() }
                catch { result["error"]=error.localizedDescription }
                if let bytes=try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]) {
                    try? bytes.write(to:report,options:.atomic)
                }
                NSApp.terminate(nil)
            }
        }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<300 {
                if predicate() { return }
                try await Task.sleep(for:.milliseconds(10))
            }
            throw NSError(domain:"SavePanelFixture",code:1,userInfo:[NSLocalizedDescriptionKey:"Native sheet did not reach its required state"])
        }
        func verify() async throws -> [String:Any] {
            let root=NSWindow(contentRect:CGRect(x:40,y:40,width:360,height:240),styleMask:[.titled],backing:.buffered,defer:false)
            let editor=NSPanel(contentRect:CGRect(x:0,y:0,width:300,height:160),styleMask:[.titled],backing:.buffered,defer:false)
            root.isReleasedWhenClosed=false;editor.isReleasedWhenClosed=false
            root.animationBehavior = .none;editor.animationBehavior = .none
            root.title="DeskCapture isolated save regression"
            NSApp.activate(ignoringOtherApps:true);root.makeKeyAndOrderFront(nil)
            root.beginSheet(editor,completionHandler:nil)
            defer {
                if let child=editor.attachedSheet {editor.endSheet(child);child.orderOut(nil)}
                root.endSheet(editor);editor.orderOut(nil);root.close()
            }
            try await wait {root.attachedSheet === editor && editor.isVisible}
            let panel=NSSavePanel();panel.directoryURL=directory;panel.nameFieldStringValue="owned-result.png"
            var response:NSApplication.ModalResponse?
            SavePanelPresentation.begin(panel,parent:root) {response=$0}
            defer {if panel.isVisible {panel.cancel(nil)}}
            try await wait {panel.isVisible}
            guard panel.sheetParent === editor,root.attachedSheet === editor else {
                throw NSError(domain:"SavePanelFixture",code:2,userInfo:[NSLocalizedDescriptionKey:"Save panel queued behind the editor instead of being its subsheet"])
            }
            panel.cancel(nil)
            try await wait {response != nil}
            return ["success":response == .cancel && editor.isVisible && root.attachedSheet === editor,
                    "saveWasVisible":true,"nestedOnEditor":true,"cancelled":response == .cancel,
                    "editorPreserved":editor.isVisible && root.attachedSheet === editor,
                    "fileWritten":FileManager.default.fileExists(atPath:directory.appendingPathComponent("owned-result.png").path)]
        }
    }
    @main struct Main {
        static func main() {
            let app=NSApplication.shared;app.setActivationPolicy(.accessory)
            let fixture=Fixture(URL(fileURLWithPath:CommandLine.arguments[1]),URL(fileURLWithPath:CommandLine.arguments[2]))
            app.delegate=fixture
            withExtendedLifetime(fixture) {app.run()}
        }
    }
    """#

    func testSaveInsideEditorSheetIsPresentedImmediatelyAndCancelPreservesEditor() async throws {
        let production = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DeskCapture/SavePanelPresentation.swift")
        let fixture = Self.fixture
        let data = try await Task.detached(priority: .userInitiated) { () throws -> Data in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("save-subsheet-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("preferences"), withIntermediateDirectories: true)
            let source = root.appendingPathComponent("Fixture.swift"), output = root.appendingPathComponent("report.json")
            let contents = root.appendingPathComponent("SaveFixture.app/Contents")
            let executable = contents.appendingPathComponent("MacOS/SaveFixture")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fixture.write(to: source, atomically: true, encoding: .utf8)
            let info: [String: Any] = ["CFBundleExecutable":"SaveFixture", "CFBundleName":"DeskCapture Save Regression",
                                       "CFBundleIdentifier":"app.monoware.deskcapture.test.save.\(UUID().uuidString)",
                                       "CFBundlePackageType":"APPL", "LSUIElement":true, "NSHighResolutionCapable":true]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let logURL = root.appendingPathComponent("fixture.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
            func run(_ binary: String, _ arguments: [String], timeout: TimeInterval) throws {
                let process = Process(); process.executableURL=URL(fileURLWithPath:binary);process.arguments=arguments
                var environment = ProcessInfo.processInfo.environment
                environment["CFFIXED_USER_HOME"]=root.appendingPathComponent("preferences").path
                environment["DESKCAPTURE_DIAGNOSTIC_DIR"]=root.path
                process.environment=environment;process.standardOutput=log;process.standardError=log
                try process.run()
                let deadline=Date().addingTimeInterval(timeout)
                while process.isRunning,Date()<deadline {Thread.sleep(forTimeInterval:0.02)}
                if process.isRunning {
                    process.terminate()
                    let stopDeadline=Date().addingTimeInterval(1)
                    while process.isRunning,Date()<stopDeadline {Thread.sleep(forTimeInterval:0.02)}
                    if process.isRunning {kill(process.processIdentifier,SIGKILL)}
                }
                process.waitUntilExit()
                guard process.terminationStatus==0 else {
                    let text=(try? String(contentsOf:logURL,encoding:.utf8)) ?? ""
                    throw CaptureError.message("Native save fixture failed: \(text)")
                }
            }
            try run("/usr/bin/xcrun",["swiftc","-parse-as-library",production.path,source.path,"-o",executable.path],timeout:60)
            try run(executable.path,[root.path,output.path],timeout:20)
            return try Data(contentsOf:output)
        }.value
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(report["success"] as? Bool, true, "\(report)")
        XCTAssertEqual(report["saveWasVisible"] as? Bool, true)
        XCTAssertEqual(report["nestedOnEditor"] as? Bool, true)
        XCTAssertEqual(report["cancelled"] as? Bool, true)
        XCTAssertEqual(report["editorPreserved"] as? Bool, true)
        XCTAssertEqual(report["fileWritten"] as? Bool, false)
    }
}
