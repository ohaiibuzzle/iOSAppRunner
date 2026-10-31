//
//  RuntimeLauncher+Processes.swift
//  BaseiOSAppHost
//

import AppKit
import Darwin

// ptrace isn't exported to Swift by the Darwin overlay; bridge it and define
// the request constants ourselves (sys/ptrace.h: PT_DETACH=11, PT_ATTACHEXC=14).
@_silgen_name("ptrace")
private func c_ptrace(_ request: Int32, _ pid: pid_t,
                      _ addr: UnsafeMutableRawPointer?, _ data: Int32) -> Int32

private let PT_DETACH: Int32 = 11
private let PT_ATTACHEXC: Int32 = 14

extension RuntimeLauncher {

    // MARK: - iOS runtime (LaunchServices + debugger attach)

    /// Launches the wrapped iOS runtime via LaunchServices. The runtime
    /// SIGSTOPs itself (--wait-for-host) and the host attaches/detaches a
    /// debugger so AMFI library validation and guest JIT are satisfied.
    static func launchiOSViaOpen(bundle: URL, installName: String, keychainSlot: Int32) -> LaunchOutcome {
        // Strip quarantine/xattrs so Gatekeeper doesn't flag the dev-signed
        // (unnotarized) bundle as damaged.
        _ = c_stripXattrsRecursive(bundle.path)

        let arguments = ["--launch-app", installName, "--wait-for-host"] + keychainSlotArgs(keychainSlot)
        let (status, stderrText) = runOpen(bundlePath: bundle.path,
                                           arguments: arguments)
        guard status == 0 else {
            let detail = stderrText.isEmpty ? String(localized: "open exited with \(status)") : stderrText
            return LaunchOutcome(ok: false, message: String(localized: "Failed to launch iOS runtime: \(detail)"))
        }

        // The runtime SIGSTOPs itself right after spawn; find it and attach.
        guard let exec = executablePath(of: bundle),
              let pid = pollForRuntimePID(executable: exec, installName: installName, timeout: 8.0) else {
            return LaunchOutcome(ok: false,
                                 message: String(localized: "iOS runtime launched, but its process can't be found. Try again."))
        }
        attachHostDebugger(pid: pid)
        return LaunchOutcome(ok: true,
                             message: String(localized: "Launched via iOS runtime"))
    }

    /// task_for_pid + ptrace attach/detach. The attach sets the CS_DEBUGGED
    /// flag AMFI consults for dynamic code / library validation; it stays set
    /// after the detach.
    @discardableResult
    private static func attachHostDebugger(pid: pid_t) -> Bool {
        // Attaching before the SIGSTOP lands can leave PT_ATTACHEXC in an
        // exception suspension PT_DETACH cannot clear (EBUSY); wait for the
        // kernel 'T' state first.
        if !waitForStoppedState(pid: pid, timeout: 10) {
            NSLog("[launcher] runtime pid %d never reached its debugger stop; attaching anyway", pid)
        }
        var task: mach_port_t = 0
        let kr = task_for_pid(mach_task_self_, pid, &task)
        guard kr == KERN_SUCCESS else {
            NSLog("[launcher] task_for_pid(%d) failed: %d (guests will not load; JIT disabled)", pid, kr)
            return false
        }
        guard c_ptrace(PT_ATTACHEXC, pid, nil, 0) != -1 else {
            NSLog("[launcher] ptrace(PT_ATTACHEXC) failed: errno %d", errno)
            return false
        }
        if c_ptrace(PT_DETACH, pid, nil, SIGCONT) == -1 {
            NSLog("[launcher] ptrace(PT_DETACH) failed: errno %d", errno)
            return false
        }
        // PT_DETACH's signal doesn't clear a SIGSTOP stop; resume explicitly.
        kill(pid, SIGCONT)
        NSLog("[launcher] debugger attached+detached for runtime pid %d", pid)
        return true
    }

    /// Waits for the kernel 'T' (stopped) state produced by the runtime's SIGSTOP.
    private static func waitForStoppedState(pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isStopped(pid) { return true }
            usleep(100 * 1000)
        }
        return false
    }

    // sys/proc.h's SSTOP; the macro isn't visible to Swift.
    private static let sstop: UInt32 = 4

    private static func isStopped(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status == sstop
    }

    // MARK: - Process discovery

    /// proc_pidpath reports the realpath (/private/...), which Foundation's
    /// resolvingSymlinksInPath() strips back to /tmp etc.
    private static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Every pid (except ours) whose executable path is in `executables`.
    private static func pids(running executables: Set<String>) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count))
        let listed = proc_listallpids(&pids, Int32(count) * Int32(MemoryLayout<pid_t>.size))
        guard listed > 0 else { return [] }

        // proc_pidpath's buffer size (PROC_PIDPATHINFO_MAXSIZE = 4*MAXPATHLEN;
        // the C macro isn't visible to Swift).
        let pathBufferSize = 4 * Int(MAXPATHLEN)
        return pids.prefix(Int(listed)).filter { pid in
            guard pid > 0, pid != getpid() else { return false }
            var buffer = [CChar](repeating: 0, count: pathBufferSize)
            guard proc_pidpath(pid, &buffer, UInt32(pathBufferSize)) > 0 else { return false }
            return executables.contains(String(cString: buffer))
        }
    }

    /// argv of `pid` via KERN_PROCARGS2 (argc, exec path, NUL padding, then argv).
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        let fields = buf[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
        // fields[0] is the exec path; argv follows.
        return fields.dropFirst().prefix(Int(argc)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Polls for the stopped runtime process started for exactly this guest:
    /// right executable, `--launch-app <installName>` in argv. A guest can't
    /// run twice (flock), so the match is unique.
    private static func pollForRuntimePID(executable: URL, installName: String, timeout: TimeInterval) -> pid_t? {
        let targets: Set<String> = [realPath(executable)]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for pid in pids(running: targets) where isStopped(pid) {
                guard let argv = arguments(of: pid),
                      let i = argv.firstIndex(of: "--launch-app"),
                      argv.indices.contains(i + 1), argv[i + 1] == installName else { continue }
                return pid
            }
            usleep(100 * 1000)
        }
        return nil
    }

    // MARK: - Low-level helpers

    @discardableResult
    static func runOpen(bundlePath: String, arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundlePath, "--args"] + arguments
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        process.waitUntilExit()
        let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }

    /// Direct exec of the Catalyst runtime, with argv; on failure falls back
    /// to `open -n --args` (WindowServer/TCC quirks).
    static func spawn(executable: String, args: [String]) -> Int32 {
        var argv: [UnsafeMutablePointer<CChar>?] =
            [strdup(executable)] + args.map { strdup($0) } + [nil]
        var envp = currentEnvp()
        defer {
            for case let p? in argv { free(p) }
            for case let p? in envp { free(p) }
        }

        var pid: pid_t = 0
        let rc = executable.withCString { execC in
            argv.withUnsafeMutableBufferPointer { argvBuf in
                envp.withUnsafeMutableBufferPointer { envBuf in
                    posix_spawn(&pid, execC, nil, nil, argvBuf.baseAddress!, envBuf.baseAddress!)
                }
            }
        }
        guard rc == 0 else {
            NSLog("[launcher] posix_spawn(%@) failed: rc=%d errno=%d", executable as NSString, rc, errno)
            return rc
        }

        // A runtime that dies immediately (AMFI/sandbox refusal) doesn't
        // count as a successful launch.
        usleep(300 * 1000)
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid {
            NSLog("[launcher] spawned runtime pid %d died immediately (status=0x%x)", pid, status)
            return -1
        }
        // Reap it when the guest quits, or it lingers as a zombie.
        DispatchQueue.global(qos: .utility).async { _ = waitpid(pid, nil, 0) }
        return 0
    }

    private static func currentEnvp() -> [UnsafeMutablePointer<CChar>?] {
        ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    }

    // MARK: - Killing runtimes

    /// Terminates every running runtime process (both flavors). Each guest
    /// runs inside its runtime process, so this also stops the guests and
    /// releases their `.guest.lock` flocks. Returns the number of processes
    /// signaled.
    static func killAllRuntimes() -> Int {
        var targets = Set<String>()
        for flavor in [RuntimeFlavor.catalyst, RuntimeFlavor.ios] {
            if let bundle = resolveBundle(flavor), let exec = executablePath(of: bundle) {
                targets.insert(realPath(exec))
            }
        }
        guard !targets.isEmpty else { return 0 }

        let signaled = pids(running: targets)
        for pid in signaled {
            NSLog("[launcher] killing runtime pid %d", pid)
            kill(pid, SIGKILL)
        }
        return signaled.count
    }
}
