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
        let space = PrivateSpace(PrivateSpaceJournal(session: bootAndLoginSessionId(), spaceId: spaceId, windowIds: []))
        space.journal.write()
        current = space
        return space
    }

    func stash(_ windows: [MacWindow], monitorRect: Rect) {
        guard let skyLight, !windows.isEmpty else { return }
        let windowIds = windows.map(\.windowId)
        journal.windowIds.formUnion(windowIds)
        journal.write()
        skyLight.moveWindows(windowIds, toSpace: journal.spaceId)
        windows.forEach { $0.markHiddenInPrivateSpace(monitorRect: monitorRect) }
    }

    func unstash(_ windowIds: [UInt32], toDisplayAt point: CGPoint) {
        guard let skyLight, !windowIds.isEmpty else { return }
        skyLight.moveWindows(windowIds, toSpace: skyLight.desktopSpace(ofDisplayAt: point))
        journal.windowIds.subtract(windowIds)
        journal.write()
    }

    func restoreWindowsAndDestroy() {
        PrivateSpace.restore(PrivateSpaceRecovery(windowIdsToRestore: journal.windowIds.sorted(), spaceIdToDestroy: journal.spaceId))
        PrivateSpaceJournal.delete()
        PrivateSpace.current = nil
    }

    static func recoverFromJournal() {
        guard let journal = PrivateSpaceJournal.read() else { return }
        restore(PrivateSpaceRecovery(journal, session: bootAndLoginSessionId(), userVisibleSpaceIds: skyLight?.userVisibleSpaceIds() ?? []))
        PrivateSpaceJournal.delete()
    }

    private static func restore(_ recovery: PrivateSpaceRecovery) {
        guard let skyLight else { return }
        Dictionary(grouping: recovery.windowIdsToRestore) { skyLight.desktopSpace(ofDisplayAt: windowCenter($0) ?? .zero) }
            .forEach { space, windowIds in skyLight.moveWindows(windowIds, toSpace: space) }
        if let spaceId = recovery.spaceIdToDestroy {
            skyLight.destroySpace(spaceId)
        }
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

    func write() {
        do {
            try JSONEncoder().encode(self).write(to: PrivateSpaceJournal.url, options: .atomic)
        } catch {
            eprint("Can't write the private Space journal: \(error)")
        }
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
    private let createOperation: AnyClass
    private let moveOperation: AnyClass
    private let destroyOperation: AnyClass

    init?() {
        guard let handle = unsafe dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let mainConnectionId = unsafe dlsym(handle, "SLSMainConnectionID"),
              let copySpaces = unsafe dlsym(handle, "SLSCopyManagedDisplaySpaces"),
              let create = NSClassFromString("SLSBridgedSpaceCreateOperation"),
              let move = NSClassFromString("SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation"),
              let destroy = NSClassFromString("SLSBridgedSpaceDestroyOperation")
        else { return nil }
        connection = unsafe unsafeBitCast(mainConnectionId, to: (@convention(c) () -> Int32).self)()
        unsafe copyManagedDisplaySpaces = unsafeBitCast(copySpaces, to: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)
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
