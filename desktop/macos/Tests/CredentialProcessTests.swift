@testable import BadMeetingKit
import Foundation

@main
struct CredentialProcessTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BadMeeting-credential-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("aiw")
        let script = #"""
        #!/usr/bin/python3
        import fcntl, os, sys, time
        from pathlib import Path
        root = Path(os.environ['HOME'])
        key = sys.argv[2]
        if key == 'BUSY_ONCE' and not (root / 'retried').exists():
            (root / 'retried').touch()
            print('Keychain vault is busy; retry after the other aiw command finishes', file=sys.stderr)
            sys.exit(1)
        if key == 'BROKEN':
            with (root / 'broken-attempts').open('a') as out: out.write('x')
            print('fixture-secret-value', file=sys.stderr)
            sys.exit(7)
        with (root / 'vault.lock').open('w') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print('Keychain vault is busy; retry after the other aiw command finishes', file=sys.stderr)
                sys.exit(1)
            time.sleep(0.08)
            print('fixture-' + key)
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let environment = ["HOME": root.path, "PATH": root.path + ":/usr/bin:/bin"]
        var failures = 0
        await withTaskGroup(of: Bool.self) { group in
            for key in ["ELEVENLABS_API_KEY", "ELEVENLABS_API_KEY", "OPENROUTER_API_KEY"] {
                group.addTask {
                    do {
                        let value = try await CredentialSettings.aiwValue(key, environment: environment)
                        return value.trimmingCharacters(in: .whitespacesAndNewlines) == "fixture-" + key
                    } catch { return false }
                }
            }
            for await success in group { if !success { failures += 1 } }
        }
        guard failures == 0 else { print("FAIL: concurrent credential reads:", failures); exit(1) }
        let retried = try await CredentialSettings.aiwValue("BUSY_ONCE", environment: environment)
        precondition(retried.trimmingCharacters(in: .whitespacesAndNewlines) == "fixture-BUSY_ONCE")
        do {
            _ = try await CredentialSettings.aiwValue("BROKEN", environment: environment)
            preconditionFailure("Non-busy failures must be reported")
        } catch {
            precondition(!error.localizedDescription.contains("fixture-secret-value"))
            let attempts = try String(contentsOf: root.appendingPathComponent("broken-attempts"), encoding: .utf8)
            precondition(attempts == "x")
        }
        print("Credential process checks passed: concurrent fields, busy retry, no retry for other errors, secret-free errors")
    }
}
