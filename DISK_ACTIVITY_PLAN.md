# Feature Plan: Disk Activity Tracking ("Stock Ticker" for Disk Usage)

Status: PLAN (v2 — lightweight design) — not yet implemented.
Audience: an implementing model/engineer with no prior context. Everything needed is in this document plus the existing source files.

Design goal for v2: **near-zero steady-state cost.** A menu bar utility must not keep the SSD busy on a quiet machine. Consequences of that goal: track only cheap directories, gate scans on actual file-system activity (FSEvents), and attribute everything else via a single computed "System & other" row instead of scanning heavy system locations.

---

## 1. What the app is today (investigation summary)

Porthole is a tiny AppKit menu bar app (Swift Package, no `.xcodeproj`, target macOS 11+, no dependencies, no tests). Five source files under `Sources/PortholeStorageMonitor/`:

| File | Role |
|---|---|
| `main.swift` | Boots `NSApplication` with `.accessory` policy (no Dock icon), installs `AppDelegate`. |
| `AppDelegate.swift` | Creates the `NSStatusItem` (HDD icon + free-space text), a 60-second `Timer` that refreshes the title, and a static `NSMenu` with three info items (Trash+Purgeable, Restart Savings, Downloads) identified by `tag` (1, 2, 3) plus Quit. Menu item text is refreshed in `menuWillOpen(_:)` via `NSMenuDelegate`. |
| `DiskUtils.swift` | `getFreeDiskSpace()` returns free space **as a formatted String** using `.volumeAvailableCapacityForImportantUsageKey` on `/`. Also trash+purgeable estimation and `emptyTrash()` (AppleScript). |
| `DownloadsMonitor.swift` | Singleton pattern used throughout: cached value + `isCalculating` flag + background `DispatchQueue.global(qos: .utility)` scan + `onUpdate: ((String) -> Void)?` callback that the AppDelegate hooks to update the menu item. Also `openDownloadsFolder()` via `NSWorkspace.shared.open`. |
| `RestartSavingsEstimator.swift` | Same singleton/cache/callback pattern; has a private `formatBytes(_:)` (GB/MB) and a reusable `folderSize(atPath:ageFilter:excludePrefixes:)` enumerator. |

Build/run: `swift build` then `.build/debug/PortholeStorageMonitor`, or `bundle.sh` / `install.command` to produce an app bundle.

**Conventions to follow:** singletons with `shared`, background work at `.utility` QoS, results delivered on the main queue via an `onUpdate` closure, menu items located by `tag`, sizes formatted as decimal GB (`bytes / 1_000_000_000`).

**Relevant existing limitations:**
- Free space is only ever handled as a formatted String — the new feature needs the raw byte count, so a small refactor of `DiskUtils` is required (Phase 1).
- The menu is built once in `setupMenu()` and only item *titles* change afterward. The activity list has a variable number of rows, so those rows must be inserted/removed dynamically in `menuWillOpen`.
- No state persists across launches; all caches are in-memory.

---

## 2. Feature overview

Track net disk-usage change over a rolling window and attribute it to directories, so the user can see *at a glance* that something is eating (or freeing) disk, and *on click* which folders are responsible.

### 2.1 Menu bar (glanceable)
- The status item currently shows `[HDD icon] 123.4 GB` (free space).
- **New:** show a colored ticker arrow between the icon and the number — `[HDD icon] ▼ 123.4 GB` — when **both**:
  1. net free space on `/` changed by **≥ 2 GB over the last hour** (free space is measured every 60 s; this costs nothing), **and**
  2. at least one *tracked* directory moved ≥ 100 MB over the same window (the "attribution guard").
- The attribution guard exists because APFS moves free space on its own (purgeable reclamation, Time Machine local-snapshot thinning, iCloud eviction). Those events show nothing in tracked folders, so the guard suppresses them — the arrow only fires when clicking the menu will actually explain something. Without the guard the arrow cries wolf and the user learns to ignore it.
- Below thresholds: no arrow, exactly today's look.

### 2.2 Menu (drill-down)
New section inserted after the existing "Downloads" item and before the Quit separator:

```
Trash + Purgeable: 2.3 GB
Restart Savings — 1.1 GB
Downloads — 5.2 GB
──────────────────────────
Activity — Last Hour            (disabled header)
Downloads — ▲ 2.1 GB            (red arrow/amount: grew)
Movies — ▲ 0.8 GB               (red)
Trash — ▼ 1.4 GB                (green arrow/amount: shrank)
System & other — ▲ 3.2 GB       (disabled, computed remainder — see §3.4)
──────────────────────────
Quit
```

- Tracked-directory rows ranked by absolute delta, descending. Top **5** max. Only directories whose |delta| ≥ **100 MB** appear.
- **Clicking a directory row opens that folder in Finder.** The "System & other" row is informational (disabled, no action).
- Empty states: `Gathering data…` (not enough history yet, e.g. first ~45 min after launch) or `No significant activity` — both disabled items.

### 2.3 Color/arrow semantics (decision — apply consistently)
One rule everywhere: **the arrow shows the direction of the number it sits next to; the color shows whether the disk is filling (red) or freeing (green).**

- Menu bar (number = *free space*): free space **up** → **green ▲**; free space **down** → **red ▼**. (Stock-ticker intuition: your "balance" of free space went up = green.)
- Directory rows (number = *that folder's size delta*): folder **grew** → **red ▲**; folder **shrank** → **green ▼**.

So red always means "space being consumed", green always means "space being reclaimed", and arrows always point the way the adjacent number moved. Implement colors/arrows through one shared helper so the semantics can be flipped in one place.

### 2.4 Interpretation caveats (document in code comments, don't fight them)
- We measure **net** change between two points in time, not gross bytes written. A file created and deleted within the window nets to zero — which is the right signal for "what is hogging disk". Net measurement is also inherently noise-resistant: cache write/evict churn cancels out.
- Resolution is folder-level over an hour, not app-level or moment-level. That's the deliberate v1 scope; per-app attribution would need a completely different mechanism.
- A file moved from `~/Downloads` to Trash correctly shows Downloads green-▼ and Trash red-▲.
- The "System & other" row is an estimate (see §3.4) and can be slightly off while a scan is in flight; that's acceptable.

---

## 3. Design: how attribution works

**Chosen approach: size snapshots of a small, cheap set of tracked directories, diffed over the window, with scans gated by FSEvents so a quiet machine does zero scanning.** Everything outside the tracked set is attributed in aggregate via the computed remainder row.

Rejected alternatives, for the record: per-file FSEvents accounting (deleted files can't be stat'ed after the fact, so deletion sizes are unknowable without a full file index); polling heavy system dirs like `~/Library/Application Support`, `~/Library/Containers`, `/Applications` (hundreds of thousands to millions of files → tens of seconds of metadata syscalls per pass, real battery/thermal cost, and those dirs produce the noisiest, least user-meaningful signal anyway).

### 3.1 Tracked directory set (small and cheap — this is the load-bearing decision)
Built once at startup by `buildTrackedDirectories()`:

1. **Every visible top-level folder in `~`** (enumerate home, keep directories, skip hidden), e.g. Downloads, Documents, Desktop, Movies, Pictures, Music — **excluding `~/Library`**.
2. **`~/Library/Caches`** — the one Library entry worth having (app cache blowups are a common, explainable event, and Caches alone is far cheaper than all of Library).
3. **`~/.Trash`** (display name "Trash") and the user's `/var/folders` tree (display "System Temp") — derive the latter the same way `RestartSavingsEstimator.calculateSystemTemp()` does: `URL(fileURLWithPath: NSTemporaryDirectory()).deletingLastPathComponent()`.

Do **not** track `~/Library/Application Support`, `Containers`, `Group Containers`, `Mobile Documents`, `Developer`, or `/Applications` — that is what the remainder row is for.

Display name = `url.lastPathComponent` unless overridden above. Skip any path that doesn't exist or isn't readable.

### 3.2 Sampling & history
- **Free space:** sampled every 60 s (piggyback on the existing `AppDelegate` timer), stored as `(Date, Int64)` samples. Cost ≈ zero.
- **Directory sizes:** scans run on a serial background queue (`.utility`), **only for directories marked dirty by FSEvents** (§3.3), with a per-directory minimum rescan interval of **5 minutes** (so a chatty folder can't cause constant rescanning). Additionally, one **full pass every 60 minutes** as a safety net against missed events, and one full pass at startup to establish baselines. Skip a pass if the previous one is still running.
- **Retention:** keep 6 hours of samples (future-proofs a "last 6 h" view); prune older on append. Memory is trivial.
- **Delta over window W (= 3600 s):** `latestSample.bytes − baseline.bytes`, where baseline = the newest sample whose `date ≤ now − W`. If no such sample exists (young history), fall back to the oldest sample **only if it is ≥ 0.75 × W old**; otherwise report "insufficient history" (menu bar: no arrow; menu: "Gathering data…").
- Note: with event-gated scanning, a directory with no events keeps its last sample — that is correct (its size didn't change), but when computing a delta, treat the latest sample as valid "now" data even if it's old, **provided** the directory has had no dirty events since. If it has pending dirty events, its delta is stale; still show it (it'll refresh within the 5-min throttle).

### 3.3 FSEvents gating (core mechanism, not an optimization)
- One `FSEventStreamCreate` over the tracked root paths, **directory-level events** (do **not** pass `kFSEventStreamCreateFlagFileEvents`), latency **5 s**, `kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer`, since-now.
- Callback: map each event path to the tracked root it lives under (longest-prefix match against the tracked set) and mark that root dirty with a timestamp. That's all the callback does — no I/O in it.
- A lightweight repeating timer (every 60 s) checks: any root dirty AND past its 5-min rescan throttle → enqueue a scan of just those roots.
- Steady-state on a quiet machine: FSEvents stream idle, no scans, ~one `statfs` per minute. This is the whole point of v2.
- The C API needs an `Unmanaged` context pointer to get `self` into the callback — a known-fiddly ~30 lines; a working shape is sketched in §4.1. Schedule the stream on the main run loop (`FSEventStreamScheduleWithRunLoop` + `FSEventStreamStart`); remember `FSEventStreamStop/Invalidate/Release` on teardown (app quit — can be skipped since the process dies, but write it anyway).
- **Fallback (only if FSEvents proves troublesome):** replace dirty-gating with a fixed full-pass cadence of **10 minutes**. With the small tracked set of §3.1 this is acceptable (a pass is typically a second or two), just not as clean. Everything else in the plan is unchanged. Do not silently choose the fallback — note it in the commit message.

### 3.4 The "System & other" remainder row
Everything not tracked (Application Support, Containers, /Applications, system volumes data, snapshots…) is shown as one aggregate:

```
remainder = (−freeSpaceDelta) − Σ(tracked directory deltas)
```

(Negated because free space falling means usage rising.) Show it as a **disabled** row, last in the section regardless of rank, only when `|remainder| ≥ listThreshold` (100 MB). Same arrow/color rules as directory rows. This gives the user "something outside your visible folders ate 3.2 GB" — most of the insight of scanning heavy dirs, at zero cost. It requires valid history for **both** free space and tracked dirs; omit the row otherwise.

### 3.5 Size-scan rules (differ deliberately from `DownloadsMonitor`)
- **Do include package descendants** (`Photos Library.photoslibrary` in Pictures is exactly what we want to catch) and **do include hidden files**. Enumerator options: `[]`.
- Skip directories themselves; skip symlinks (check the `.isSymbolicLinkKey` resource key — cheaper than `attributesOfItem`).
- Prefer `totalFileAllocatedSize`, then `fileAllocatedSize`, then `fileSize` (allocated size reflects real disk usage, matching what free space measures).
- Swallow per-file errors silently (permission denied is common and must not crash or spam logs).

### 3.6 Performance guard (belt-and-braces)
Per directory scan, measure wall time; if a single directory takes **> 20 s**, flag it `expensive = true` and raise its rescan throttle to 15 min. With the §3.1 tracked set this should rarely trigger (a huge Photos library is the realistic case).

### 3.7 Testability hook
Read env var **`PORTHOLE_FAST_SCAN`**: if `1`, use rescan throttle = 15 s, dirty-check timer = 5 s, full-pass interval = 60 s, free-space sample = 5 s, window = 120 s, min-history fraction unchanged, menu-bar threshold = 500 MB. Manual verification then takes ~2 minutes instead of an hour. Gate all constants through one `Config` struct so the env var is checked in exactly one place.

---

## 4. Code changes

### 4.1 New file: `Sources/PortholeStorageMonitor/DiskActivityTracker.swift`
One singleton owning both histories, the FSEvents stream, and scan scheduling. Skeleton (implementer fills in bodies per §3):

```swift
import Foundation
import CoreServices

final class DiskActivityTracker {
    static let shared = DiskActivityTracker()

    struct Config {
        let window: TimeInterval            // 3600, fast: 120
        let minHistoryFraction: Double      // 0.75
        let retention: TimeInterval         // 6 * 3600
        let rescanThrottle: TimeInterval    // 300, fast: 15
        let dirtyCheckInterval: TimeInterval // 60, fast: 5
        let fullPassInterval: TimeInterval  // 3600, fast: 60
        let menuBarThreshold: Int64         // 2_000_000_000, fast: 500_000_000
        let listThreshold: Int64            // 100_000_000
        let listLimit: Int                  // 5
        static func fromEnvironment() -> Config { ... } // checks PORTHOLE_FAST_SCAN
    }

    struct TrackedDirectory {
        let url: URL; let displayName: String
        var expensive = false
        var dirtySince: Date?               // set by FSEvents callback
        var lastScanStart: Date?
    }
    struct SizeSample: Codable { let date: Date; let bytes: Int64 }
    enum ActivityEntry {
        case directory(url: URL, displayName: String, deltaBytes: Int64)
        case remainder(deltaBytes: Int64)   // "System & other"
    }

    let config = Config.fromEnvironment()
    private var trackedDirs: [TrackedDirectory] = []
    private var dirHistory: [String: [SizeSample]] = [:]   // key: url.path
    private var freeHistory: [SizeSample] = []
    private let queue = DispatchQueue(label: "com.porthole.diskactivity", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var isScanning = false

    var onUpdate: (() -> Void)?    // fired on main queue after each completed scan pass

    func start()                       // build dir list, initial full pass, start FSEvents + timers
    func recordFreeSpace(bytes: Int64) // called by AppDelegate every timer tick
    func freeSpaceDelta() -> Int64?    // nil = insufficient history
    func topMovers() -> [ActivityEntry]?  // nil = insufficient history; [] = nothing significant;
                                          // otherwise ranked dirs then optional .remainder last
    func shouldShowMenuBarArrow() -> Bool // |freeSpaceDelta| >= threshold AND >=1 directory entry (§2.1 guard)
}
```

Implementation notes:
- All mutation of state happens on `queue`; the read methods use `queue.sync { ... }` so the AppDelegate can call them from the main thread safely.
- Timers must live on the main run loop (a `Timer` on a background queue never fires); their handlers hop to `queue` immediately.
- The delta/baseline helper is shared between free-space and per-dir series — write it once: `func delta(in samples: [SizeSample]) -> Int64?` implementing §3.2 exactly.
- The folder-size enumerator: copy the shape of `DownloadsMonitor.calculateSize()` but with the rule changes in §3.5. Do **not** reuse `RestartSavingsEstimator.folderSize` (its age-filter semantics don't fit).
- FSEvents callback shape (adapt, don't copy blindly):

```swift
private func startEventStream() {
    let paths = trackedDirs.map { $0.url.path } as CFArray
    var context = FSEventStreamContext(
        version: 0,
        info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
        retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
        guard let info = info else { return }
        let tracker = Unmanaged<DiskActivityTracker>.fromOpaque(info).takeUnretainedValue()
        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
        tracker.markDirty(paths: Array(paths.prefix(Int(count))))
    }
    eventStream = FSEventStreamCreate(
        nil, callback, &context, paths,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5.0,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
    guard let stream = eventStream else { return }   // fall back gracefully: see §3.3 fallback
    FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    FSEventStreamStart(stream)
}
```

  `markDirty(paths:)` hops to `queue`, longest-prefix-matches each path against `trackedDirs`, sets `dirtySince` if unset. If `FSEventStreamCreate` or `FSEventStreamStart` fails at runtime, log once and switch to the §3.3 fixed-cadence fallback instead of crashing.

### 4.2 Modify `DiskUtils.swift`
- Add `static func getFreeDiskSpaceBytes() -> Int64?` (same resource-key lookup, returns raw bytes).
- Reimplement `getFreeDiskSpace()` as formatting over the bytes function (behavior unchanged).
- Add a shared formatter `static func formatGB(_ bytes: Int64) -> String` → `"%.1f GB"` of the absolute value (direction is carried by arrows, not minus signs).

### 4.3 Modify `AppDelegate.swift`

**Startup** (`applicationDidFinishLaunching`): call `DiskActivityTracker.shared.start()` after `setupMenu()`.

**Menu bar title** — replace the body of `updateDiskSpace()`:

```swift
@objc func updateDiskSpace() {
    guard let bytes = DiskUtils.getFreeDiskSpaceBytes() else { return }
    let tracker = DiskActivityTracker.shared
    tracker.recordFreeSpace(bytes: bytes)
    let delta = tracker.shouldShowMenuBarArrow() ? tracker.freeSpaceDelta() : nil
    let text = DiskUtils.formatGB(bytes)
    DispatchQueue.main.async {
        guard let button = self.statusItem.button else { return }
        button.attributedTitle = Self.tickerTitle(text: text, delta: delta)
    }
}
```

`tickerTitle` builds an `NSAttributedString`: if `delta != nil`, prefix `"▲ "` (delta > 0, `.systemGreen`) or `"▼ "` (delta < 0, `.systemRed`), then the plain text. Set an explicit font on the whole string — `NSFont.menuBarFont(ofSize: 0)` — otherwise attributed titles render at the wrong size. Always use `attributedTitle` (with or without arrow) so layout doesn't jiggle when the arrow appears. **Verify visually.**

**Menu section** — in `menuWillOpen(_:)`, after the existing three update calls, call `rebuildActivityItems()`. Tag scheme: separator = 90, header = 91, placeholder/remainder = 92–93, directory rows = 100…104.

```swift
func rebuildActivityItems() {
    guard let menu = statusItem.menu else { return }
    for item in menu.items where (90...110).contains(item.tag) { menu.removeItem(item) }
    guard let anchor = menu.items.firstIndex(where: { $0.tag == 3 }) else { return }
    var idx = anchor + 1

    let sep = NSMenuItem.separator(); sep.tag = 90
    menu.insertItem(sep, at: idx); idx += 1
    let header = NSMenuItem(title: "Activity — Last Hour", action: nil, keyEquivalent: "")
    header.tag = 91; header.isEnabled = false
    menu.insertItem(header, at: idx); idx += 1

    switch DiskActivityTracker.shared.topMovers() {
    case nil:
        insertPlaceholder("Gathering data…", tag: 92, into: menu, at: idx)
    case let entries? where entries.isEmpty:
        insertPlaceholder("No significant activity", tag: 92, into: menu, at: idx)
    case let entries?:
        var tag = 100
        for entry in entries {
            switch entry {
            case .directory(let url, let name, let delta):
                let item = NSMenuItem(title: "", action: #selector(openActivityDirectory(_:)), keyEquivalent: "")
                item.tag = tag; tag += 1
                item.target = self                  // explicit target; don't rely on responder chain
                item.representedObject = url
                item.attributedTitle = Self.activityRowTitle(name: name, deltaBytes: delta)
                menu.insertItem(item, at: idx); idx += 1
            case .remainder(let delta):
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.tag = 93; item.isEnabled = false
                item.attributedTitle = Self.activityRowTitle(name: "System & other", deltaBytes: delta)
                menu.insertItem(item, at: idx); idx += 1
            }
        }
    }
}

@objc func openActivityDirectory(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    NSWorkspace.shared.open(url)
}
```

`activityRowTitle(name:deltaBytes:)` returns e.g. **"Downloads — ▲ 2.1 GB"**: name and " — " in `.labelColor`, arrow+amount in `.systemRed` (grew) / `.systemGreen` (shrank), font `NSFont.menuFont(ofSize: 0)`. This matches the existing "Name — value" menu style, so no custom views or tab stops are needed. (Right-aligned amounts via `NSTextTab`, or macOS 14's `NSMenuItem.badge`, are later polish — not in v1; deploy target is macOS 11.)

Live refresh while the menu is open is **not required** (the list rebuilds on every open); if implementing it via `onUpdate`, only rebuild when the menu is actually open.

### 4.4 Unchanged
`main.swift`, `DownloadsMonitor.swift`, `RestartSavingsEstimator.swift`, `Package.swift` (FSEvents lives in CoreServices — no manifest change).

---

## 5. Implementation phases

Do them in order; each phase builds and is verifiable on its own.

**Phase 1 — Refactor (small).** `DiskUtils.getFreeDiskSpaceBytes()`, `formatGB`, rewire `getFreeDiskSpace()`. ✅ `swift build` passes; app behaves identically.

**Phase 2 — Tracker core + menu bar arrow.** New `DiskActivityTracker.swift` with `Config`, free-space history, `recordFreeSpace`, `freeSpaceDelta`, the shared `delta(in:)` helper, and `tickerTitle` in AppDelegate. Directory scanning stubbed; `shouldShowMenuBarArrow()` temporarily returns `freeSpaceDelta() != nil && abs(...) >= threshold` (guard completed in Phase 3). ✅ With `PORTHOLE_FAST_SCAN=1`, create a 2 GB file (`mkfile -n 2g ~/Downloads/porthole-test.bin`), wait ~2 min → red ▼; delete + empty trash → green ▲.

**Phase 3 — Directory scanning + menu section.** `buildTrackedDirectories()` (§3.1), the size enumerator (§3.5), per-dir history, startup full pass + hourly full pass (timer-driven; FSEvents comes next phase, so in this phase also run a temporary 60 s "scan all" cadence under `PORTHOLE_FAST_SCAN` so it's testable), `topMovers()` with the remainder row (§3.4), the completed arrow guard (§2.1), `rebuildActivityItems()`, click-to-open, placeholders, performance guard (§3.6). ✅ Fast-scan test: "Downloads — ▲ 2.1 GB" appears ranked; clicking opens Downloads; deleting flips it green and Trash red; "System & other" appears when you grow something untracked (e.g. `mkfile -n 1g ~/Library/Application\ Support/porthole-test.bin` — remember to delete it); quiet machine → "No significant activity"; right after launch → "Gathering data…".

**Phase 4 — FSEvents gating (core to the design — do not skip lightly).** `startEventStream()` (§4.1 sketch), `markDirty`, dirty-check timer, per-dir rescan throttle; remove Phase 3's temporary cadence (keep the hourly safety-net full pass). If FSEvents fails at runtime, fall back to a 10-min full-pass cadence (§3.3) with a single log line. ✅ Quiet machine: watch with Activity Monitor / `fs_usage -f filesys` — no enumeration between hourly passes. Touch a file in `~/Downloads` → only Downloads rescans within the throttle window.

**Phase 5 — Persistence (recommended).** Serialize `dirHistory` + `freeHistory` (`Codable`) to `~/Library/Application Support/Porthole/activity-history.json` after each scan pass; load in `start()`, pruning samples older than retention. Makes the feature useful right after a relaunch instead of blind for 45 minutes. ✅ Quit + relaunch inside the window → arrow/list state survives.

**Out of scope for v1** (listed so the implementer doesn't drift): configurable thresholds/window UI, "last 6 hours" toggle, per-app or per-moment attribution, notifications on large changes, tracking non-root volumes, scanning `~/Library/Application Support` / `Containers` / `/Applications` (deliberately excluded — see §3, that's what the remainder row is for).

---

## 6. Verification checklist (run after Phase 4)

1. `swift build` — clean.
2. `PORTHOLE_FAST_SCAN=1 .build/debug/PortholeStorageMonitor` — icon appears, no arrow initially, menu shows "Gathering data…".
3. Create 2 GB file in `~/Downloads` → within ~1 min: red ▼ in menu bar; menu row "Downloads — ▲ 2.1 GB" in red.
4. Click the row → Finder opens `~/Downloads`.
5. Delete the file (to Trash) → Downloads goes green ▼, Trash red ▲; empty Trash → menu-bar arrow goes green ▲.
6. Grow an untracked location (1 GB file in `~/Library/Application Support`) → "System & other — ▲ 1.0 GB" appears, disabled; **no** menu-bar arrow unless a tracked dir also moved (the guard). Clean the test file up.
7. Let the fast window (120 s) elapse with no activity → arrow disappears, list shows "No significant activity".
8. Run without the env var: on an idle machine, verify no directory enumeration occurs between hourly passes (Activity Monitor disk I/O ≈ 0 for the process) and CPU stays at zero.
9. Check Console for permission-error spam — there should be none (errors swallowed).
