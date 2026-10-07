import AppKit
import Common

@MainActor
final class PrivateSpace {
    @MainActor static private(set) var current: PrivateSpace? = nil
    @MainActor private static var isUnsupported = false

    private var journal: PrivateSpaceJournal

    private init(_ journal: PrivateSpaceJournal) {
        self.journal = journal
    }

    static func getOrCreate() -> PrivateSpace? {
        if let current { return current }
        if isUnsupported { return nil }
        guard let skyLight, let spaceId = skyLight.createSpace() else {
            isUnsupported = true
            eprint("Can't create a private Space. Falling back to hiding windows in the screen corner")
            return nil
        }
        let journal = PrivateSpaceJournal(session: bootAndLoginSessionId(), spaceId: spaceId, windowIds: [])
        guard journal.write() else {
            skyLight.destroySpace(spaceId)
            isUnsupported = true
            eprint("Falling back to hiding windows in the screen corner")
            return nil
        }
        current = PrivateSpace(journal)
        return current
    }

    /// Returns false when the windows weren't stashed, because a crash would strand windows the journal doesn't name
    func stash(_ windows: [MacWindow], monitorRect: Rect) -> Bool {
        guard let skyLight else { return false }
        if windows.isEmpty { return true }
        let windowIds = windows.map(\.windowId)
        var updated = journal
        updated.windowIds.formUnion(windowIds)
        guard updated.write() else { return false }
        journal = updated
        skyLight.moveWindows(windowIds, toSpace: journal.spaceId)
        windows.forEach { $0.markHiddenInPrivateSpace(monitorRect: monitorRect) }
        return true
    }

    func unstash(_ windowIds: [UInt32], toDisplayAt point: CGPoint) {
        guard let skyLight, !windowIds.isEmpty else { return }
        skyLight.moveWindows(windowIds, toSpace: skyLight.desktopSpace(ofDisplayAt: point))
        journal.windowIds.subtract(windowIds)
        _ = journal.write() // A stale entry only names a window that is already back
    }

    func restoreWindowsAndDestroy() {
        PrivateSpace.restore(journal, PrivateSpaceRecovery(windowIdsToRestore: journal.windowIds.sorted(), spaceIdToDestroy: journal.spaceId))
        PrivateSpace.current = nil
    }

    static func recoverFromJournal() {
        guard let journal = PrivateSpaceJournal.read() else { return }
        restore(journal, PrivateSpaceRecovery(journal, session: bootAndLoginSessionId(), userVisibleSpaceIds: skyLight?.userVisibleSpaceIds() ?? []))
    }

    private static func restore(_ journal: PrivateSpaceJournal, _ recovery: PrivateSpaceRecovery) {
        guard let skyLight else { return }
        Dictionary(grouping: recovery.windowIdsToRestore) { skyLight.desktopSpace(ofDisplayAt: windowCenter($0) ?? .zero) }
            .forEach { space, windowIds in skyLight.moveWindows(windowIds, toSpace: space) }
        // Other connections can't see the private Space, so a stranded window may report no Space at all.
        // A window that no longer exists can't be brought back and doesn't count
        let userSpaceIds = skyLight.userVisibleSpaceIds()
        let stranded = recovery.windowIdsToRestore.filter { windowCenter($0) != nil && skyLight.spaceIds(ofWindow: $0).isDisjoint(with: userSpaceIds) }
        if let left = journal.afterRestore(stranded: stranded.toSet()) {
            eprint("\(left.windowIds.count) windows are still in the private Space. AeroSpace retries on the next launch")
            _ = left.write()
            return
        }
        if let spaceId = recovery.spaceIdToDestroy {
            skyLight.destroySpace(spaceId)
        }
        PrivateSpaceJournal.delete()
    }
}

struct PrivateSpaceJournal: Codable, Equatable {
    let session: String
    let spaceId: UInt64
    var windowIds: Set<UInt32>

    private static var url: URL {
        darwinUserTempDir().appending(component: "\(aeroSpaceAppId).private-space.json")
    }

    static func read() -> PrivateSpaceJournal? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PrivateSpaceJournal.self, from: $0) }
    }

    func write() -> Bool {
        do {
            try JSONEncoder().encode(self).write(to: PrivateSpaceJournal.url, options: .atomic)
            return true
        } catch {
            eprint("Can't write the private Space journal: \(error)")
            return false
        }
    }

    /// The journal to keep after a restore: the windows that are still stranded, or nil once every window is back
    func afterRestore(stranded: Set<UInt32>) -> PrivateSpaceJournal? {
        let left = windowIds.intersection(stranded)
        return left.isEmpty ? nil : PrivateSpaceJournal(session: session, spaceId: spaceId, windowIds: left)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

struct PrivateSpaceRecovery: Equatable {
    let windowIdsToRestore: [UInt32]
    let spaceIdToDestroy: UInt64?

    init(windowIdsToRestore: [UInt32], spaceIdToDestroy: UInt64?) {
        self.windowIdsToRestore = windowIdsToRestore
        self.spaceIdToDestroy = spaceIdToDestroy
    }

    init(_ journal: PrivateSpaceJournal, session: String, userVisibleSpaceIds: Set<UInt64>) {
        // Window and Space ids restart with WindowServer (reboot, logout).
        // A journal from another session names someone else's windows and Spaces
        let isSameSession = journal.session == session
        windowIdsToRestore = isSameSession ? journal.windowIds.sorted() : []
        spaceIdToDestroy = isSameSession && !userVisibleSpaceIds.contains(journal.spaceId) ? journal.spaceId : nil
    }
}

private func bootAndLoginSessionId() -> String {
    var boot = [CChar](repeating: 0, count: 64)
    var size = boot.count
    _ = unsafe sysctlbyname("kern.bootsessionuuid", &boot, &size, nil, 0)
    let login = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionUniqueSessionUUID"] as? String ?? ""
    return string(boot) + "/" + login
}

/// Not $TMPDIR, which differs between AeroSpace launched from a shell and from Finder
private func darwinUserTempDir() -> URL {
    var dir = [CChar](repeating: 0, count: Int(PATH_MAX))
    _ = unsafe confstr(_CS_DARWIN_USER_TEMP_DIR, &dir, dir.count)
    return URL(fileURLWithPath: string(dir))
}

private func string(_ nullTerminated: [CChar]) -> String {
    String(decoding: nullTerminated.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func windowCenter(_ windowId: UInt32) -> CGPoint? {
    let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowId) as? [[String: Any]]
    guard let bounds = info?.first?[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
    return CGPoint(x: rect.midX, y: rect.midY)
}

@MainActor private let skyLight: SkyLight? = SkyLight()

@safe private struct SkyLight {
    private typealias InitWithOptions = @convention(c) (AnyObject, Selector, UInt32, AnyObject?) -> Unmanaged<AnyObject>?
    private typealias InitWithSpaceId = @convention(c) (AnyObject, Selector, UInt64) -> Unmanaged<AnyObject>?
    private typealias InitWithSpaceIdWindowsOptions =
        @convention(c) (AnyObject, Selector, UInt64, NSArray, UInt32) -> Unmanaged<AnyObject>?

    private static let addToSpaceAndRemoveFromOthers: UInt32 = 7

    private let connection: Int32
    private let copyManagedDisplaySpaces: @convention(c) (Int32) -> Unmanaged<CFArray>?
    private let copySpacesForWindows: @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private let createOperation: AnyClass
    private let moveOperation: AnyClass
    private let destroyOperation: AnyClass

    init?() {
        guard let handle = unsafe dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let mainConnectionId = unsafe dlsym(handle, "SLSMainConnectionID"),
              let copySpaces = unsafe dlsym(handle, "SLSCopyManagedDisplaySpaces"),
              let copyWindowSpaces = unsafe dlsym(handle, "SLSCopySpacesForWindows"),
              let create = NSClassFromString("SLSBridgedSpaceCreateOperation"),
              let move = NSClassFromString("SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation"),
              let destroy = NSClassFromString("SLSBridgedSpaceDestroyOperation")
        else { return nil }
        connection = unsafe unsafeBitCast(mainConnectionId, to: (@convention(c) () -> Int32).self)()
        unsafe copyManagedDisplaySpaces = unsafeBitCast(copySpaces, to: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)
        unsafe copySpacesForWindows = unsafeBitCast(copyWindowSpaces, to: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self)
        createOperation = create
        moveOperation = move
        destroyOperation = destroy
    }

    func createSpace() -> UInt64? {
        let selector = NSSelectorFromString("initWithOptions:values:")
        let op = unsafe initialize(createOperation, selector, as: InitWithOptions.self) { unsafe $0($1, selector, 1, nil) }
        let result = unsafe op?.perform(performSelector)?.takeUnretainedValue()
        let spaceId = (result?.value(forKey: "spaceID") as? NSNumber)?.uint64Value ?? 0
        return spaceId == 0 ? nil : spaceId
    }

    func moveWindows(_ windowIds: [UInt32], toSpace spaceId: UInt64) {
        let selector = NSSelectorFromString("initWithSpaceID:windows:options:")
        let windows = windowIds.map { NSNumber(value: $0) } as NSArray
        unsafe performReturningVoid(initialize(moveOperation, selector, as: InitWithSpaceIdWindowsOptions.self) {
            unsafe $0($1, selector, spaceId, windows, SkyLight.addToSpaceAndRemoveFromOthers)
        })
    }

    func destroySpace(_ spaceId: UInt64) {
        let selector = NSSelectorFromString("initWithSpaceID:")
        unsafe performReturningVoid(initialize(destroyOperation, selector, as: InitWithSpaceId.self) { unsafe $0($1, selector, spaceId) })
    }

    func desktopSpace(ofDisplayAt point: CGPoint) -> UInt64 {
        var displayId: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if unsafe CGGetDisplaysWithPoint(point, 1, &displayId, &count) != .success || count == 0 {
            displayId = CGMainDisplayID()
        }
        let uuid = unsafe CGDisplayCreateUUIDFromDisplayID(displayId).flatMap { unsafe CFUUIDCreateString(nil, $0.takeRetainedValue()) as String? }
        let displays = managedDisplaySpaces()
        // "Main" is the only entry when "Displays have separate Spaces" is off
        guard let display = displays.first(where: { $0["Display Identifier"] as? String == uuid }) ?? displays.first else { return 0 }
        let isDesktop = { (space: [String: Any]) in (space["type"] as? NSNumber)?.intValue == 0 }
        if let current = display["Current Space"] as? [String: Any], isDesktop(current) {
            return spaceId(current)
        }
        return (display["Spaces"] as? [[String: Any]] ?? []).first(where: isDesktop).map(spaceId) ?? 0
    }

    func spaceIds(ofWindow windowId: UInt32) -> Set<UInt64> {
        let allSpaces: Int32 = 7
        let ids = unsafe copySpacesForWindows(connection, allSpaces, [NSNumber(value: windowId)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        return (ids ?? []).map(\.uint64Value).toSet()
    }

    func userVisibleSpaceIds() -> Set<UInt64> {
        managedDisplaySpaces().flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }.map(spaceId).filter { $0 != 0 }.toSet()
    }

    private func managedDisplaySpaces() -> [[String: Any]] {
        unsafe copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
    }

    private func spaceId(_ space: [String: Any]) -> UInt64 {
        (space["id64"] as? NSNumber)?.uint64Value ?? 0
    }

    private func initialize<F>(_ cls: AnyClass, _ selector: Selector, as _: F.Type, _ call: (F, AnyObject) -> Unmanaged<AnyObject>?) -> AnyObject? {
        // Unretained: `init…` consumes the +1 that `alloc` returns
        guard let allocated = unsafe (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        return unsafe call(unsafeBitCast(allocated.method(for: selector), to: F.self), allocated)?.takeRetainedValue()
    }

    private func performReturningVoid(_ op: AnyObject?) {
        _ = unsafe op?.perform(performSelector)
    }

    private var performSelector: Selector { NSSelectorFromString("performWithWMBridgeDelegate") }
}
