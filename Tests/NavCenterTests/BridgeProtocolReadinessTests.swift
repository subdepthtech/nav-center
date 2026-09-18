import Foundation
import Darwin
import XCTest
@testable import NavCenterApp
import NavCenterCore

final class BridgeProtocolReadinessTests: XCTestCase {
    private func fixture(_ scenario: String, timeout: TimeInterval = 2) throws -> (URL, NativeCodexBridge) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("navcenter-protocol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("applications/example"), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: root.appendingPathComponent("applications/example/posting.md"))
        try Data(scenario.utf8).write(to: root.appendingPathComponent("scenario"))
        let script = root.appendingPathComponent("fake-codex")
        try Data(Self.server.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let bridge = NativeCodexBridge(repoRoot: root, command: script.path, turnTimeout: timeout, requestTimeout: 3, shutdownGrace: 0.15)
        addTeardownBlock { bridge.shutdown(); try? FileManager.default.removeItem(at: root) }
        return (root, bridge)
    }

    private func run(_ bridge: NativeCodexBridge) throws -> CodexChatResponse {
        try bridge.runPackageChat(CodexChatRequest(packageName: "example", message: "Synthetic request", threadId: nil, allowEdits: true, confirmed: true))
    }

    func testHandshakeUnicodeAndStringApprovalPreserveLegitimateEdits() throws {
        for scenario in ["positive", "unicode", "string", "numeric-string", "early"] {
            let (root, bridge) = try fixture(scenario)
            let response = try run(bridge)
            XCTAssertTrue(response.ok, scenario)
            XCTAssertEqual(response.message, "Before café résumé", scenario)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("applications/example/posting.md")), "approved", scenario)
            let trace = try String(contentsOf: root.appendingPathComponent("trace"))
            XCTAssertTrue(trace.contains("initialized"))
            if scenario == "string" { XCTAssertTrue(trace.contains("approval-string")) }
            if scenario == "numeric-string" { XCTAssertTrue(trace.contains("\"99\"")) }
        }
    }

    func testDeniedMetadataCommandsAndPermissionsDoNotWrite() throws {
        for scenario in ["missing", "wrong-thread-approval", "command", "permissions"] {
            let (root, bridge) = try fixture(scenario)
            let response = try run(bridge)
            XCTAssertTrue(response.ok)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("applications/example/posting.md")), "original")
            let trace = try String(contentsOf: root.appendingPathComponent("trace"))
            XCTAssertTrue(trace.contains(scenario == "permissions" ? "\"permissions\": {}" : "decline"), scenario)
        }
    }

    func testWrongThreadCompletionCannotFinishActiveTurn() throws {
        let (_, bridge) = try fixture("wrong-completion", timeout: 0.25)
        XCTAssertThrowsError(try run(bridge)) { error in XCTAssertTrue(error.localizedDescription.contains("timed out")) }
    }

    func testTimeoutInterruptsAndStopsWorkerBeforeDisposingStaging() throws {
        let (root, bridge) = try fixture("timeout", timeout: 0.25)
        XCTAssertThrowsError(try run(bridge))
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("worker.json"))) as! [String: Any]
        let pid = (info["pid"] as! NSNumber).int32Value
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: info["staging"] as! String))
        let trace = try String(contentsOf: root.appendingPathComponent("trace"))
        XCTAssertTrue(trace.contains("turn/interrupt"))
        XCTAssertTrue(trace.contains("staging-existed-at-interrupt"))
        try Data("positive".utf8).write(to: root.appendingPathComponent("scenario"))
        XCTAssertTrue(try bridge.status().ok)
        XCTAssertTrue(try run(bridge).ok)
    }

    func testBlockedInputWriteTimesOutWithoutSIGPIPEOrHanging() throws {
        let (root, bridge) = try fixture("blocked-input")
        let started = Date()
        XCTAssertThrowsError(try bridge.runPackageChat(CodexChatRequest(packageName: "example", message: String(repeating: "x", count: 1_048_576), threadId: nil, allowEdits: true, confirmed: true)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("applications/example/posting.md")), "original")
        try Data("positive".utf8).write(to: root.appendingPathComponent("scenario"))
        XCTAssertTrue(try run(bridge).ok)
    }

    func testForcedStopKillsOwnedDescendantsAndAggregateLimitStopsBeforeCleanup() throws {
        for scenario in ["descendant", "aggregate-limit"] {
            let (root, bridge) = try fixture(scenario, timeout: scenario == "descendant" ? 0.25 : 4)
            if scenario == "descendant" { XCTAssertThrowsError(try run(bridge)) }
            else { XCTAssertFalse(try run(bridge).ok) }
            let info = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("worker.json"))) as! [String: Any]
            XCTAssertEqual(kill((info["pid"] as! NSNumber).int32Value, 0), -1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: info["staging"] as! String))
            if let child = info["child"] as? NSNumber {
                let state = try ProcessRunner.run("/bin/ps", ["-p", child.stringValue, "-o", "stat="])
                XCTAssertTrue(state.stderr.isEmpty)
                XCTAssertTrue(state.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.stdout.contains("Z"))
            }
        }
    }

    func testMalformedJSONFailsExplicitly() throws {
        let (_, bridge) = try fixture("malformed")
        let response = try? run(bridge)
        XCTAssertNotEqual(response?.ok, true)
    }

    func testLinkedApplicationsRootRejectedByBroker() throws {
        let (root, _) = try fixture("positive")
        let source = root.appendingPathComponent("applications")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: source, to: outside)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        XCTAssertThrowsError(try CodexPackageEditBroker(packageURL: source.appendingPathComponent("example"), workspaceRoot: root))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("example/posting.md")), "original")
    }

    func testReboundStagingCleanupPreservesReplacement() throws {
        let (root, _) = try fixture("positive")
        let broker = try CodexPackageEditBroker(packageURL: root.appendingPathComponent("applications/example"), workspaceRoot: root, stagingParent: root)
        let retained = root.appendingPathComponent("original-stage")
        try FileManager.default.moveItem(at: broker.stagingURL, to: retained)
        try FileManager.default.createDirectory(at: broker.stagingURL, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: broker.stagingURL.appendingPathComponent("sentinel"))
        XCTAssertThrowsError(try broker.cleanup())
        XCTAssertEqual(try String(contentsOf: broker.stagingURL.appendingPathComponent("sentinel")), "replacement")
    }

    private static let server = #"""
    #!/usr/bin/python3
    import json, os, sys, time, signal, subprocess
    from pathlib import Path
    root = Path.cwd()
    scenario = (root/'scenario').read_text()
    initialized = False
    cwd = None
    def record(value):
        with (root/'trace').open('a') as f: f.write(json.dumps(value, ensure_ascii=False)+'\n')
    def send(value):
        sys.stdout.write(json.dumps(value, ensure_ascii=False)+'\n'); sys.stdout.flush()
    def reply(i, value): send({'id': i, 'result': value})
    def notify(method, params): send({'method': method, 'params': params})
    def complete(thread='thread', status='completed'):
        notify('turn/completed', {'threadId': thread, 'turn': {'id':'turn','status':status,'items':[{'id':'message','type':'agentMessage','text':'Before café résumé'}]}})
    def approval():
        method = 'item/fileChange/requestApproval'
        params = {'threadId':'thread','turnId':'turn','itemId':'item'}
        if scenario == 'missing': params = {}
        if scenario == 'wrong-thread-approval': params['threadId'] = 'other'
        if scenario == 'command': method = 'item/commandExecution/requestApproval'
        if scenario == 'permissions': method = 'item/permissions/requestApproval'
        ident = 'approval-string' if scenario == 'string' else '99' if scenario == 'numeric-string' else 99
        notify('item/started', {'threadId':'thread','turnId':'turn','item':{'id':'item','type':'fileChange','status':'inProgress','startedAtMs':0,'changes':[{'path':'posting.md','kind':{'type':'update'},'diff':'synthetic'}]}})
        send({'id':ident,'method':method,'params':params})
    for line in sys.stdin:
        obj = json.loads(line); record(obj)
        method = obj.get('method'); ident=obj.get('id')
        if method == 'initialized': initialized=True; continue
        if method == 'initialize': reply(ident, {'userAgent':'synthetic','codexHome':'synthetic'}); continue
        if method and not initialized: send({'id':ident,'error':{'code':-1,'message':'Not initialized'}}); continue
        if method == 'account/read': reply(ident, {'account':{'type':'chatgpt','email':'synthetic@example.invalid'},'requiresOpenaiAuth':False})
        elif method in ['thread/start','thread/resume']:
            reply(ident, {'thread':{'id':'thread'}})
            if scenario == 'blocked-input': time.sleep(30)
        elif method == 'turn/start':
            cwd = Path(obj['params']['cwd'])
            (root/'worker.json').write_text(json.dumps({'pid':os.getpid(),'staging':str(cwd)}))
            if scenario == 'early': approval()
            reply(ident, {'turn':{'id':'turn','status':'inProgress','items':[]}})
            if scenario == 'malformed': sys.stdout.write('{bad json}\n');sys.stdout.flush();continue
            if scenario == 'wrong-completion': complete('other');continue
            if scenario == 'timeout': continue
            if scenario == 'descendant':
                child=subprocess.Popen(['/usr/bin/python3','-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)'])
                (root/'worker.json').write_text(json.dumps({'pid':os.getpid(),'staging':str(cwd),'child':child.pid}))
                signal.signal(signal.SIGTERM,signal.SIG_IGN)
                time.sleep(30);continue
            if scenario == 'aggregate-limit':
                for _ in range(6): notify('item/agentMessage/delta', {'threadId':'thread','turnId':'turn','itemId':'message','delta':'x'*800000})
                continue
            if scenario != 'early': approval()
        elif method == 'turn/interrupt':
            record({'staging-existed-at-interrupt':cwd.exists()})
            reply(ident, {}); complete(status='interrupted')
        elif method is None and ident is not None:
            result = obj.get('result', {})
            if result.get('decision') == 'accept': (cwd/'posting.md').write_text('approved')
            notify('item/agentMessage/delta', {'threadId':'thread','turnId':'turn','itemId':'message','delta':'Before '})
            if scenario == 'unicode':
                data=(json.dumps({'method':'item/agentMessage/delta','params':{'threadId':'thread','turnId':'turn','itemId':'message','delta':'café résumé'}},ensure_ascii=False)+'\n').encode()
                boundary=data.index('é'.encode())+1
                sys.stdout.buffer.write(data[:boundary]);sys.stdout.buffer.flush();time.sleep(.03);sys.stdout.buffer.write(data[boundary:]);sys.stdout.buffer.flush()
            complete()
    """#
}
