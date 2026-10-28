import Foundation
import Observation

/// Saved AI check-ups (a JSON file in the progress folder).
@MainActor @Observable
final class CheckupModel {
    private(set) var records: [CheckupRecord] = []
    private let history: CheckupHistory

    init(root: URL) { history = CheckupHistory(root: root); records = history.load() }

    func reload() { records = history.load() }
    func add(_ r: CheckupRecord) { records.append(r); records.sort { $0.date < $1.date }; try? history.save(records) }
    func delete(_ id: UUID) { records.removeAll { $0.id == id }; try? history.save(records) }
    /// The check-up before `r`, for "Compare with last check-up".
    func previous(before r: CheckupRecord) -> CheckupRecord? { records.last { $0.date < r.date && $0.id != r.id } }
}

/// Where the key and the network come from. Screenshot mode (DEBUG) gets a throw-away key and canned answers, so it never touches the network.
@MainActor
enum CheckupEnvironment {
    static var isFixtureMode: Bool {
        #if DEBUG
        return ScreenshotMode.isActive
        #else
        return false
        #endif
    }
    private static let fixtureKeys: MemorySecretStore = {
        let m = MemorySecretStore(); _ = m.write("sk-ant-api03-fixture-0000", service: "fixture", account: "fixture"); return m
    }()
    static func keys() -> APIKeyStore { isFixtureMode ? APIKeyStore(store: fixtureKeys, service: "fixture", account: "fixture") : APIKeyStore() }
    static func client() -> CheckupClient { isFixtureMode ? CheckupClient(transport: FixtureTransport()) : CheckupClient() }
}

struct FixtureTransport: CheckupTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try? await Task.sleep(for: .milliseconds(400))
        return (CheckupFixtures.responseData(), HTTPURLResponse(url: request.url ?? CheckupRequest.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// Runs one check-up: prepares the images off the main thread, calls the client, saves the record.
@MainActor @Observable
final class CheckupRunner {
    enum State { case idle, preparing, waiting, done(CheckupRecord), failed(CheckupError) }
    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    var isBusy: Bool { if case .preparing = state { return true }; if case .waiting = state { return true }; return false }

    func reset() { task?.cancel(); state = .idle }
    func cancel() { task?.cancel(); state = .idle }

    func start(scope: String, entries: [ProgressEntry], lib: ProgressLibrary, user: UserStore, content: (SkincareContent?, HaircareContent?)) {
        let keys = CheckupEnvironment.keys()
        guard let key = keys.key else { state = .failed(.noKey); return }
        state = .preparing
        let previous = lib.checkups.records.last
        let context = CheckupContext.json(scope: scope, user: user.data, skincare: content.0, haircare: content.1, previous: previous)
        let sources = entries.enumerated().map { (i, e) in (CheckupPhotos.label(i, e), lib.store.jpeg(e)) }
        let refs = entries.map { CheckupPhotoRef(entryId: $0.id, series: $0.series, date: $0.date) }
        let client = CheckupEnvironment.client()
        task = Task {
            let prepared: [PreparedPhoto]? = await Task.detached { () -> [PreparedPhoto]? in
                var out: [PreparedPhoto] = []
                for (label, data) in sources {
                    guard let data, let jpeg = ImagePrep.prepare(data) else { return nil }
                    out.append(PreparedPhoto(label: label, jpeg: jpeg))
                }
                return out
            }.value
            guard let prepared, !Task.isCancelled else { if !Task.isCancelled { state = .failed(.photoUnreadable) }; return }
            state = .waiting
            do {
                let outcome = try await client.run(key: key, photos: prepared, contextJSON: context)
                guard !Task.isCancelled else { return }
                let rec = CheckupRecord(date: Date(), scope: scope, result: outcome.result, photos: refs, usage: outcome.usage, cost: outcome.cost, effort: outcome.effort)
                lib.checkups.add(rec)
                state = .done(rec)
            } catch let e as CheckupError {
                if !Task.isCancelled { state = .failed(e) }
            } catch {
                if !Task.isCancelled { state = .failed(.network("error")) }
            }
        }
    }
}
