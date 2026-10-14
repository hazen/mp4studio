import AppKit
import MP4StudioCore
import Observation

@MainActor
@Observable
final class Job: Identifiable {
    enum Status: Equatable {
        case queued, running, paused, done, failed(String), cancelled

        var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let plan: JobPlan
    let logURL: URL
    var status: Status = .queued
    var stepIndex = 0
    var stepFraction = 0.0
    var startedAt: Date?
    var finishedAt: Date?

    init(plan: JobPlan, logURL: URL) {
        self.plan = plan
        self.logURL = logURL
    }

    var progress: Double {
        guard !plan.steps.isEmpty else { return 0 }
        if status == .done { return 1 }
        return (Double(stepIndex) + stepFraction) / Double(plan.steps.count)
    }

    var currentStepLabel: String {
        plan.steps.indices.contains(stepIndex) ? plan.steps[stepIndex].label : ""
    }

    var hasDeterminateProgress: Bool {
        guard plan.steps.indices.contains(stepIndex) else { return true }
        return plan.steps[stepIndex].progress != .indeterminate
    }

    /// Estimated time left, once enough progress has been made to judge.
    var remaining: TimeInterval? {
        guard status == .running, let startedAt, progress > 0.02 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        return elapsed / progress * (1 - progress)
    }
}

@MainActor
@Observable
final class JobQueue {
    var jobs: [Job] = []
    private(set) var current: Job?
    private var runner: StepRunner?
    private var activity: NSObjectProtocol?
    let logsDirectory: URL
    var keepLogs: () -> Bool = { true }

    init(logsDirectory: URL) {
        self.logsDirectory = logsDirectory
    }

    var pendingCount: Int { jobs.filter { !$0.status.isFinished }.count }

    @discardableResult
    func add(_ plan: JobPlan) -> Job {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeTitle = plan.title.replacingOccurrences(of: "/", with: "-").prefix(80)
        let job = Job(plan: plan, logURL: logsDirectory.appendingPathComponent("\(stamp) \(safeTitle).log"))
        jobs.append(job)
        updateBadge()
        startNextIfIdle()
        return job
    }

    func pause(_ job: Job) {
        guard job === current, job.status == .running else { return }
        runner?.pause()
        job.status = .paused
    }

    func resume(_ job: Job) {
        guard job === current, job.status == .paused else { return }
        runner?.resume()
        job.status = .running
    }

    func cancel(_ job: Job) {
        if job === current {
            runner?.cancel()
        } else if !job.status.isFinished {
            job.status = .cancelled
            job.finishedAt = Date()
            updateBadge()
        }
    }

    func remove(_ job: Job) {
        guard job.status.isFinished else { return }
        jobs.removeAll { $0 === job }
    }

    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
    }

    func retry(_ job: Job) {
        guard job.status.isFinished, job.status != .done else { return }
        jobs.removeAll { $0 === job }
        add(job.plan)
    }

    private func startNextIfIdle() {
        guard current == nil, let next = jobs.first(where: { $0.status == .queued }) else {
            if current == nil { endActivity() }
            return
        }
        current = next
        beginActivity()
        Task { await run(next) }
    }

    private func run(_ job: Job) async {
        job.status = .running
        job.startedAt = Date()
        var log = "\(job.plan.title)\nStarted \(Date())\n"
        for warning in job.plan.warnings { log += "Warning: \(warning)\n" }
        try? log.write(to: job.logURL, atomically: true, encoding: .utf8)

        var failure: Error?
        for (index, step) in job.plan.steps.enumerated() {
            job.stepIndex = index
            job.stepFraction = 0
            let stepRunner = StepRunner(step: step, logURL: job.logURL)
            runner = stepRunner
            do {
                try await stepRunner.run { fraction in
                    Task { @MainActor in
                        if job.stepIndex == index { job.stepFraction = fraction }
                    }
                }
            } catch {
                failure = error
                break
            }
        }
        runner = nil

        let fm = FileManager.default
        for url in job.plan.temporaryFiles { try? fm.removeItem(at: url) }
        switch failure {
        case nil:
            job.status = .done
            job.stepFraction = 1
            if !keepLogs() { try? fm.removeItem(at: job.logURL) }
        case is CancellationError:
            job.status = .cancelled
            removePartialOutputs(job)
        case let error?:
            job.status = .failed(error.localizedDescription)
            removePartialOutputs(job)
            NSApp.requestUserAttention(.informationalRequest)
        }
        job.finishedAt = Date()
        current = nil
        updateBadge()
        startNextIfIdle()
    }

    private func removePartialOutputs(_ job: Job) {
        for url in job.plan.outputs { try? FileManager.default.removeItem(at: url) }
    }

    private func updateBadge() {
        let n = pendingCount
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    /// Keeps the Mac awake while jobs run.
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Processing video files")
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
