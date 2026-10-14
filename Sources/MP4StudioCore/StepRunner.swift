import Foundation

/// Runs one JobStep, streaming its output to a log and reporting progress.
public final class StepRunner: @unchecked Sendable {
    public let step: JobStep
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var stderrTail = ""
    private var log: FileHandle?

    public init(step: JobStep, logURL: URL?) {
        self.step = step
        if let logURL {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            log = try? FileHandle(forWritingTo: logURL)
            _ = try? log?.seekToEnd()
        }
    }

    deinit { try? log?.close() }

    /// Runs to completion. Throws on a non-zero exit (unless cancelled, which throws CancellationError).
    public func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        writeLog("\n$ \(step.commandLine)\n")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.executableURL = step.executable
            process.arguments = step.arguments
            process.environment = ProcessRunner.toolEnvironment()
            process.currentDirectoryURL = step.workingDirectory
            process.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err

            let group = DispatchGroup()
            let kind = step.progress
            group.enter()
            group.enter()
            stream(out.fileHandleForReading, isError: false, kind: kind, progress: progress) { group.leave() }
            stream(err.fileHandleForReading, isError: true, kind: kind, progress: progress) { group.leave() }

            process.terminationHandler = { [weak self] proc in
                group.notify(queue: .global()) {
                    guard let self else { return }
                    self.writeLog("[exit \(proc.terminationStatus)]\n")
                    if self.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if proc.terminationStatus == 0 {
                        progress(1)
                        continuation.resume()
                    } else {
                        let message = self.lock.withLock { self.stderrTail }
                        continuation.resume(throwing: ToolError.failed(tool: self.step.tool.rawValue, status: proc.terminationStatus,
                                                                       message: Self.lastLines(message, 4)))
                    }
                }
            }
            do {
                try process.run()
            } catch {
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        lock.withLock { cancelled = true }
        guard process.isRunning else { return }
        process.resume()          // a suspended process can't handle SIGTERM
        process.terminate()
    }

    public func pause() { if process.isRunning { _ = process.suspend() } }
    public func resume() { if process.isRunning { _ = process.resume() } }

    /// Reads a pipe on a background queue, splitting on newlines and carriage returns (MP4Box redraws with \r).
    private func stream(_ handle: FileHandle, isError: Bool, kind: ProgressKind,
                        progress: @escaping @Sendable (Double) -> Void, done: @escaping () -> Void) {
        DispatchQueue.global().async { [weak self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineData = buffer[buffer.startIndex..<idx]
                    buffer.removeSubrange(buffer.startIndex...idx)
                    let line = Self.stripANSI(String(decoding: lineData, as: UTF8.self))
                    self?.handle(line: line, isError: isError, kind: kind, progress: progress)
                }
            }
            if !buffer.isEmpty {
                self?.handle(line: Self.stripANSI(String(decoding: buffer, as: UTF8.self)), isError: isError, kind: kind, progress: progress)
            }
            done()
        }
    }

    private func handle(line: String, isError: Bool, kind: ProgressKind, progress: @Sendable (Double) -> Void) {
        if let f = ProgressParser.fraction(from: Substring(line), kind: kind) {
            progress(f)
            return
        }
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // ffmpeg's -progress block is noise in logs.
        if case .ffmpeg = kind, !isError, line.contains("=") { return }
        if isError || kind == .mkvtoolnix {
            lock.withLock {
                stderrTail += line + "\n"
                if stderrTail.count > 8000 { stderrTail = String(stderrTail.suffix(4000)) }
            }
        }
        writeLog(line + "\n")
    }

    private func writeLog(_ text: String) {
        lock.withLock { log?.write(Data(text.utf8)) }
    }

    /// MP4Box colors its output even when it isn't a terminal.
    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    static func lastLines(_ text: String, _ n: Int) -> String {
        text.split(separator: "\n").filter { !$0.hasPrefix("#GUI#progress") }.suffix(n).joined(separator: "\n")
    }
}
