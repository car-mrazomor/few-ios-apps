import Foundation

/// Receives Python's output and input requests on the main thread.
@MainActor
protocol PythonConsole: AnyObject {
    func pythonWrote(_ text: String, isError: Bool)
    /// Python is blocked in input()/readline until `request.complete(...)` is called.
    func pythonWantsLine(_ request: LineRequest)
    func pythonEvent(_ name: String, payload: String)
}

/// A pending input() call. Completed exactly once from the main thread.
final class LineRequest: @unchecked Sendable {
    fileprivate let semaphore = DispatchSemaphore(value: 0)
    fileprivate var line: String?
    fileprivate var interrupted = false

    func complete(line: String?) {
        self.line = line
        semaphore.signal()
    }

    func interrupt() {
        interrupted = true
        semaphore.signal()
    }
}

/// Owns the single embedded CPython interpreter. Python only ever runs on `thread`,
/// which makes it Python's main thread (so Ctrl-C / KeyboardInterrupt work).
final class PythonEngine: @unchecked Sendable {
    static let shared = PythonEngine()

    @MainActor weak var console: PythonConsole?
    @MainActor private(set) var isBusy = false
    private(set) var startupError: String?

    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private var thread: Thread?

    // Output is batched: Python can print thousands of lines a second.
    private let outputLock = NSLock()
    private var pendingOutput: [(String, Bool)] = []
    private var flushScheduled = false

    // MARK: Lifecycle

    func start() {
        guard thread == nil else { return }
        let thread = Thread { [unowned self] in runLoop() }
        thread.name = "Python"
        thread.stackSize = 16 << 20  // Python needs far more than the 512 KB default for secondary threads.
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()

        enqueue { [unowned self] in
            let bundle = Bundle.main.bundlePath
            let documents = URL.documentsDirectory.path
            let support = URL.applicationSupportDirectory.appending(path: "PocketCode").path
            try? FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
            if let error = pc_initialize(bundle, documents, support, writeCallback, readlineCallback, eventCallback) {
                startupError = String(cString: error)
                free(error)
            }
        }
    }

    private func runLoop() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }

    private func enqueue(_ job: @escaping () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    // MARK: Running code

    /// Runs one shell line; returns its exit status.
    @MainActor
    func run(_ line: String) async -> Int32 {
        isBusy = true
        defer { isBusy = false }
        let status: Int32 = await withCheckedContinuation { continuation in
            enqueue { [unowned self] in
                guard startupError == nil else { return continuation.resume(returning: 1) }
                let status = pc_run_line(line)
                flushOutput()
                continuation.resume(returning: status)
            }
        }
        await drainOutput()
        return status
    }

    /// Calls a helper in pocketcode.shell (prompt, complete, set_size...). Only while idle.
    func call(_ function: String, _ argument: String = "") async -> String? {
        await withCheckedContinuation { continuation in
            enqueue { [unowned self] in
                guard startupError == nil, let result = pc_call(function, argument) else {
                    return continuation.resume(returning: nil)
                }
                defer { free(result) }
                flushOutput()
                continuation.resume(returning: String(cString: result))
            }
        }
    }

    func interrupt() {
        pc_interrupt()
    }

    // MARK: Callbacks from Python (on the Python thread)

    fileprivate func write(_ text: String, isError: Bool) {
        outputLock.lock()
        pendingOutput.append((text, isError))
        let schedule = !flushScheduled
        flushScheduled = true
        outputLock.unlock()
        if schedule {
            DispatchQueue.main.async { [unowned self] in deliverOutput() }
        }
    }

    private func flushOutput() {
        DispatchQueue.main.sync { [unowned self] in deliverOutput() }
    }

    @MainActor
    private func drainOutput() async {
        deliverOutput()
    }

    @MainActor
    private func deliverOutput() {
        outputLock.lock()
        let batch = pendingOutput
        pendingOutput = []
        flushScheduled = false
        outputLock.unlock()

        // Merge consecutive chunks from the same stream before handing them over.
        var merged: [(String, Bool)] = []
        for (text, isError) in batch {
            if let last = merged.last, last.1 == isError {
                merged[merged.count - 1].0 += text
            } else {
                merged.append((text, isError))
            }
        }
        for (text, isError) in merged {
            console?.pythonWrote(text, isError: isError)
        }
    }

    fileprivate func readLine() -> (String?, Bool) {
        flushOutput()  // The prompt must be on screen before we wait.
        let request = LineRequest()
        DispatchQueue.main.async { [unowned self] in
            if let console {
                console.pythonWantsLine(request)
            } else {
                request.complete(line: nil)
            }
        }
        request.semaphore.wait()
        return (request.line, request.interrupted)
    }

    fileprivate func event(_ name: String, _ payload: String) {
        DispatchQueue.main.async { [unowned self] in console?.pythonEvent(name, payload: payload) }
    }
}

// MARK: - C function pointers

private let writeCallback: pc_write_fn = { stream, text, length in
    guard let text else { return }
    let data = Data(bytes: text, count: Int(length))
    PythonEngine.shared.write(String(decoding: data, as: UTF8.self), isError: stream == 2)
}

private let readlineCallback: pc_readline_fn = { _, interrupted in
    let (line, wasInterrupted) = PythonEngine.shared.readLine()
    interrupted?.pointee = wasInterrupted
    guard let line else { return nil }
    return strdup(line)
}

private let eventCallback: pc_event_fn = { name, payload in
    guard let name else { return }
    PythonEngine.shared.event(String(cString: name), payload.map { String(cString: $0) } ?? "")
}
