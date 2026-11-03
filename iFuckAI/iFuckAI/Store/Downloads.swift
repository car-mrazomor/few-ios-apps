import Foundation
import QuartzCore

struct DownloadJob: Codable, Identifiable, Hashable {
    struct Item: Codable, Hashable {
        let path: String
        let size: Int64
        let relative: String
        var done: Bool
    }

    let id: String
    let repo: String
    let name: String
    let quant: String
    var items: [Item]
    let projectorPath: String?
    let info: GGUFInfo?
    var error: String?

    var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

final class Downloads: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = Downloads()
    static let sessionID = "io.ubiship.PocketLM.downloads"

    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var progress: [String: Double] = [:]

    var onComplete: ((LocalModel) -> Void)?
    var backgroundCompletion: (() -> Void)?
    var token: () -> String? = { nil }

    private var written: [String: Int64] = [:]
    private var resumeData: [String: Data] = [:]
    private var lastPublish: [String: CFTimeInterval] = [:]
    private let store = Paths.root.appendingPathComponent("downloads.json")

    private lazy var session: URLSession = {
        #if targetEnvironment(simulator)
        let config = URLSessionConfiguration.default
        #else
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        #endif
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private var attempts: [String: Int] = [:]
    private var active: Set<String> = []
    private let maxAttempts = 3

    override init() {
        super.init()
        if let data = try? Data(contentsOf: store), let saved = try? JSONDecoder().decode([DownloadJob].self, from: data) {
            jobs = saved
        }
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                self.active = Set(tasks.compactMap(\.taskDescription))
                let active = Set(tasks.compactMap { $0.taskDescription.flatMap(Self.parse)?.job })
                for i in self.jobs.indices where !active.contains(self.jobs[i].id) && self.jobs[i].error == nil {
                    if self.jobs[i].items.allSatisfy(\.done) {
                        self.finish(self.jobs[i].id)
                    } else {
                        self.jobs[i].error = "Interrupted"
                    }
                }
                self.save()
            }
        }
    }

    func job(_ id: String) -> DownloadJob? { jobs.first { $0.id == id } }

    func start(repo: String, variant: GGUFVariant, projector: GGUFVariant?, info: GGUFInfo?) throws {
        let id = "\(repo)/\(variant.id)"
        guard job(id) == nil else { return }
        let folder = Paths.repoFolder(repo)
        let files = variant.files + (projector?.files ?? [])
        let needed = files.reduce(Int64(0)) { $0 + $1.size }
        let free = Paths.freeDiskBytes
        if free > 0 && needed > free {
            throw DownloadError.noSpace(needed: needed, free: free)
        }
        var job = DownloadJob(
            id: id, repo: repo, name: variant.id, quant: variant.quant,
            items: files.map { .init(path: $0.path, size: $0.size, relative: "\(folder)/\($0.path)", done: false) },
            projectorPath: projector.map { "\(folder)/\($0.primary.path)" }, info: info
        )
        for i in job.items.indices where FileManager.default.fileExists(atPath: Paths.models.appendingPathComponent(job.items[i].relative).path) {
            job.items[i].done = true
        }
        jobs.append(job)
        progress[id] = fraction(job)
        save()
        if job.items.allSatisfy(\.done) {
            finish(id)
        } else {
            resume(job)
        }
    }

    func retry(_ id: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].error = nil
        save()
        resume(jobs[i])
    }

    func cancel(_ id: String) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription.flatMap(Self.parse)?.job == id }.forEach { $0.cancel() }
        }
        if let job = job(id) {
            for item in job.items where item.done {
                try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(item.relative))
            }
            for item in job.items {
                resumeData[key(id, item.path)] = nil
                active.remove(key(id, item.path))
            }
        }
        jobs.removeAll { $0.id == id }
        progress[id] = nil
        save()
    }

    private func resume(_ job: DownloadJob) {
        for item in job.items where !item.done {
            attempts[key(job.id, item.path)] = 0
            start(item, of: job)
        }
    }

    private func start(_ item: DownloadJob.Item, of job: DownloadJob) {
        let k = key(job.id, item.path)
        guard !active.contains(k) else { return }
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: k) {
            task = session.downloadTask(withResumeData: data)
        } else {
            let client = HFClient(token: token())
            task = session.downloadTask(with: client.request(client.downloadURL(repo: job.repo, path: item.path)))
        }
        task.taskDescription = k
        active.insert(k)
        task.resume()
    }

    private func key(_ job: String, _ path: String) -> String { "\(job)\n\(path)" }

    private static func parse(_ description: String) -> (job: String, path: String)? {
        let parts = description.split(separator: "\n", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    private func fraction(_ job: DownloadJob) -> Double {
        let done = job.items.reduce(Int64(0)) { $0 + ($1.done ? $1.size : written[key(job.id, $1.path)] ?? 0) }
        return job.total > 0 ? min(1, Double(done) / Double(job.total)) : 0
    }

    private func finish(_ id: String) {
        guard let job = job(id) else { return }
        let projector = job.projectorPath
        let modelItems = job.items.filter { $0.relative != projector }
        let model = LocalModel(
            id: job.id, repo: job.repo, name: job.name, quant: job.quant,
            files: modelItems.map(\.relative), projector: projector,
            sizeBytes: modelItems.reduce(0) { $0 + $1.size },
            projectorBytes: job.items.filter { $0.relative == projector }.reduce(0) { $0 + $1.size },
            info: job.info, addedAt: Date()
        )
        jobs.removeAll { $0.id == id }
        progress[id] = nil
        save()
        onComplete?(model)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(jobs) { try? data.write(to: store, options: .atomic) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let description = downloadTask.taskDescription, let (jobID, _) = Self.parse(description), let job = job(jobID) else { return }
        written[description] = totalBytesWritten
        let now = CACurrentMediaTime()
        if now - (lastPublish[jobID] ?? 0) > 0.25 {
            lastPublish[jobID] = now
            progress[jobID] = fraction(job)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let description = downloadTask.taskDescription { active.remove(description) }
        guard let description = downloadTask.taskDescription, let (jobID, path) = Self.parse(description),
              let i = jobs.firstIndex(where: { $0.id == jobID }),
              let j = jobs[i].items.firstIndex(where: { $0.path == path }) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            jobs[i].error = status == 401 || status == 403 ? HFError.unauthorized.localizedDescription : "HTTP \(status)"
            save()
            return
        }
        let dest = Paths.models.appendingPathComponent(jobs[i].items[j].relative)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            jobs[i].items[j].done = true
            written[description] = nil
            progress[jobID] = fraction(jobs[i])
            save()
            if jobs[i].items.allSatisfy(\.done) { finish(jobID) }
        } catch {
            jobs[i].error = error.localizedDescription
            save()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let description = task.taskDescription, let (jobID, _) = Self.parse(description),
              let i = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let ns = error as NSError
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeData[description] = data
        }
        active.remove(description)
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled && resumeData[description] == nil { return }
        let attempt = (attempts[description] ?? 0) + 1
        if attempt <= maxAttempts, let item = jobs[i].items.first(where: { $0.path == Self.parse(description)?.path }) {
            attempts[description] = attempt
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt * 2)) { [weak self] in
                guard let self, let job = self.job(jobID), job.error == nil else { return }
                self.start(item, of: job)
            }
            return
        }
        jobs[i].error = error.localizedDescription
        save()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundCompletion?()
        backgroundCompletion = nil
    }
}

enum DownloadError: LocalizedError {
    case noSpace(needed: Int64, free: Int64)

    var errorDescription: String? {
        switch self {
        case let .noSpace(needed, free):
            "Not enough storage. This download needs \(Format.bytes(needed)) but only \(Format.bytes(free)) is free."
        }
    }
}
