import Foundation
import Observation
import UserNotifications

/// The app's handle on the progress photo folder. Views read through it so they refresh after a save or delete.
@MainActor @Observable
final class ProgressLibrary {
    let store: ProgressStore
    let checkups: CheckupModel
    private(set) var tick = 0

    init(root: URL = ProgressStore.defaultRoot()) { store = ProgressStore(root: root); checkups = CheckupModel(root: root) }

    func entries(_ s: PhotoSeries) -> [ProgressEntry] { _ = tick; return store.entries(s) }
    func lastDate(_ s: PhotoSeries) -> Date? { _ = tick; return store.lastDate(s) }
    func touch() { tick += 1 }

    @discardableResult
    func save(jpeg: Data, entry: ProgressEntry, mattes: [String: Data] = [:], backup: Bool) -> ProgressEntry? {
        let saved = try? store.save(jpeg: jpeg, entry: entry, mattes: mattes, excludeFromBackup: !backup)
        touch()
        return saved
    }
    func update(_ e: ProgressEntry) { try? store.write(e); touch() }
    func delete(_ e: ProgressEntry) { store.delete(e); touch() }
    func deleteAll() { store.deleteAll(); checkups.reload(); touch() }

    #if os(iOS)
    private var analyzing: Set<UUID> = []

    /// Measures a photo in the background (Vision + the metric math) and stores the numbers in its JSON. Skips photos already being measured.
    func analyze(_ e: ProgressEntry, force: Bool = false) {
        guard force || e.metrics == nil, !analyzing.contains(e.id) else { return }
        analyzing.insert(e.id)
        let store = self.store
        Task.detached(priority: .utility) {
            let metrics = PhotoAnalyzer.analyze(photo: store.photoURL(e), series: e.series,
                                                hairMatte: store.hasMatte(e, "hair") ? store.matteURL(e, "hair") : nil,
                                                skinMatte: store.hasMatte(e, "skin") ? store.matteURL(e, "skin") : nil)
            await MainActor.run {
                self.analyzing.remove(e.id)
                // re-read the entry so a note or rating changed meanwhile is kept
                guard let metrics, var cur = store.entries(e.series).first(where: { $0.id == e.id }) else { return }
                cur.metrics = metrics
                self.update(cur)
            }
        }
    }
    func isAnalyzing(_ id: UUID) -> Bool { _ = tick; return analyzing.contains(id) }
    #endif

    func dueSeries(_ user: UserStore, now: Date = Date()) -> [PhotoSeries] {
        PhotoSchedules.dueSeries(user.data.photoSchedules, lastPhoto: { self.lastDate($0) }, now: now)
    }

    /// One local notification per enabled series, at the chosen time of its next due day. Re-armed on launch, after each photo and when a schedule changes.
    func rearmReminders(_ user: UserStore) async {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("progress-") }
        center.removePendingNotificationRequests(withIdentifiers: old)
        let active = PhotoSeries.allCases.filter { user.data.photoSchedules[$0.rawValue]?.enabled == true }
        guard !active.isEmpty, await Notifier.requestIfNeeded(user) else { return }
        for s in active {
            guard let sched = user.data.photoSchedules[s.rawValue] else { continue }
            let at = PhotoSchedules.nextReminder(last: lastDate(s), schedule: sched, now: Date())
            let content = UNMutableNotificationContent()
            content.title = "Progress photo"
            content.body = "Time for your \(s.title.lowercased()) photo."
            content.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "progress-\(s.rawValue)", content: content, trigger: trigger))
        }
    }
}
