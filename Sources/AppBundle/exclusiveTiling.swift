import Common
import Darwin
import Foundation

/// Ask the aerospace-responsive daemon how this refresh's moves should land, and apply that in
/// the tree before `layoutWorkspaces` draws. A float that arrives after the draw is what shrinks
/// the tiles for a frame. No daemon, or no answer in time: draw as before.
@MainActor
func judgeExclusiveTilingBeforeDraw() async {
    let moves = takePendingWindowMoves()
    guard !moves.isEmpty else { return }
    var sent = false
    defer {
        if !sent {
            for event in moves { broadcastEvent(event) }
        }
    }
    var seen: Set<UInt64> = []
    var moved: [UInt64] = []
    for event in moves {
        guard let id = event.windowMovedId, seen.insert(id).inserted else { continue }
        moved.append(id)
    }
    let workspaces = Set(moved.compactMap { Window.get(byId: OpaqueWindowId($0))?.nodeWorkspace?.name })
    var census: [[String: Any]] = []
    for window in MacWindow.allWindows {
        let ws = window.nodeWorkspace?.name ?? ""
        let id = window.windowId.rawId
        guard workspaces.contains(ws) || moved.contains(id) else { continue }
        let title = (try? await window.getTitle(.nonCancellable)) ?? ""
        census.append([
            "window-id": Int(id),
            "workspace": ws,
            "app-bundle-id": window.app.rawAppBundleId ?? "",
            "app-name": window.app.name ?? "",
            "window-title": title,
            "window-layout": windowLayoutName(window),
        ])
    }
    if let commands = await exclusiveTilingPreLayout(windows: census, moved: moved) {
        for (kind, id) in commands {
            await applyExclusiveTiling(kind, id)
        }
    }
    sent = true
    for event in moves { broadcastEvent(event) }
}

@MainActor
private func applyExclusiveTiling(_ kind: String, _ id: UInt64) async {
    let layout: LayoutCmdArgs.LayoutDescription? = switch kind {
        case "float": .floating
        case "tile": .tiling
        default: nil
    }
    guard let layout else { return }
    let wid = OpaqueWindowId(id)
    guard Window.get(byId: wid) != nil else { return }
    _ = await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [layout]))
        .run(.defaultEnv.withWindowId(wid), .emptyStdin)
}

private func exclusiveTilingPreLayout(windows: [[String: Any]], moved: [UInt64]) async -> [(String, UInt64)]? {
    let body: [String: Any] = ["verb": "pre-layout", "windows": windows, "moved": moved.map { Int($0) }]
    guard JSONSerialization.isValidJSONObject(body),
          var data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    data.append(0x0A)
    guard let reply = exclusiveTilingSocket(data) else { return nil }
    guard let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
          (obj["exit"] as? NSNumber)?.intValue == 0,
          let cmds = obj["json"] as? [[String: Any]] else { return nil }
    return cmds.compactMap { cmd in
        guard let kind = cmd["kind"] as? String, let id = (cmd["id"] as? NSNumber)?.uint64Value else { return nil }
        return (kind, id)
    }
}

/// Line-delimited JSON, not AeroSpace's length-prefixed socket. 100ms, then the refresh draws
/// unjudged. The worker may be inside `aerospace`, which is waiting on this refresh.
private func exclusiveTilingSocket(_ request: Data) -> Data? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
    let tlen = socklen_t(MemoryLayout<timeval>.size)
    unsafe setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, tlen)
    unsafe setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, tlen)
    let path = "/tmp/aerospace-responsive-\(NSUserName()).sock"
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathCap = MemoryLayout.size(ofValue: addr.sun_path)
    let bound = path.withCString { cstr in
        withUnsafeMutablePointer(to: &addr.sun_path) { dest in
            unsafe dest.withMemoryRebound(to: CChar.self, capacity: pathCap) { unsafe strlcpy($0, cstr, pathCap) }
        }
    }
    guard bound < pathCap else { return nil }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) {
        unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return nil }
    let written = unsafe request.withUnsafeBytes { buf in
        guard let base = buf.baseAddress else { return -1 }
        return unsafe send(fd, base, buf.count, 0)
    }
    guard written == request.count else { return nil }
    var got = Data()
    var buf = [UInt8](repeating: 0, count: 8192)
    while !got.contains(0x0A) && got.count < 1_000_000 {
        let n = unsafe recv(fd, &buf, buf.count, 0)
        if n <= 0 { return nil }
        unsafe got.append(buf, count: n)
    }
    return got
}
