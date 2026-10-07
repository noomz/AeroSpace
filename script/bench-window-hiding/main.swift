// Measures workspace switches of a running AeroSpace from outside, using window server truth.
// Usage: bench-window-hiding --cli <aerospace> --server-pid <pid> --ws-a A --ws-b B --cycles N --label L --out <file.tsv>
// Each row is one switch. `shown`: every window of the target workspace is on screen at its steady frame.
// `hidden`: no window of the source workspace shows more than a 2 px sliver on any display.
import AppKit
import Darwin

func arg(_ name: String) -> String {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else {
        fatalError("missing \(name)")
    }
    return CommandLine.arguments[i + 1]
}

// `--on-screen <id,id,...>` prints how many of the windows are on screen and exits. Used by crash-recovery.sh
if let i = CommandLine.arguments.firstIndex(of: "--on-screen") {
    let ids = CommandLine.arguments[i + 1].split(separator: ",").compactMap { UInt32($0) }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    let onScreen = Set(list.compactMap { $0[kCGWindowNumber as String] as? UInt32 })
    print(ids.filter(onScreen.contains).count)
    exit(0)
}

let cli = arg("--cli")
let serverPid = pid_t(arg("--server-pid"))!
let wsA = arg("--ws-a")
let wsB = arg("--ws-b")
let cycles = Int(arg("--cycles"))!
let label = arg("--label")
let outUrl = URL(fileURLWithPath: arg("--out"))
let pollTimeout = 3.0
let stableFor = 0.15

@discardableResult
func aerospace(_ args: String...) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    try! p.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    precondition(p.terminationStatus == 0, "aerospace \(args) failed")
    return out
}

struct Win { let id: UInt32; let pid: pid_t }

func windows(_ ws: String) -> [Win] {
    aerospace("list-windows", "--workspace", ws, "--format", "%{window-id} %{app-pid}")
        .split(separator: "\n").map { $0.split(separator: " ") }
        .map { Win(id: UInt32($0[0])!, pid: pid_t($0[1])!) }
}

func onScreenFrames() -> [UInt32: CGRect] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
    var result: [UInt32: CGRect] = [:]
    for w in list {
        guard let id = w[kCGWindowNumber as String] as? UInt32,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b) else { continue }
        result[id] = r
    }
    return result
}

let displays: [CGRect] = {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).map { CGDisplayBounds($0) }
}()

func visibleArea(_ r: CGRect) -> Double {
    displays.reduce(0) { acc, d in
        let i = d.intersection(r)
        return acc + (i.isNull ? 0 : Double(i.width * i.height))
    }
}

func isSliverOrGone(_ id: UInt32, _ frames: [UInt32: CGRect]) -> Bool {
    guard let r = frames[id] else { return true }
    return visibleArea(r) <= 2 * Double(max(r.width, r.height))
}

func isAt(_ id: UInt32, _ frame: CGRect, _ frames: [UInt32: CGRect]) -> Bool {
    guard let r = frames[id] else { return false }
    return abs(r.minX - frame.minX) <= 1 && abs(r.minY - frame.minY) <= 1 && abs(r.width - frame.width) <= 1 && abs(r.height - frame.height) <= 1
}

let timebase: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom)
}()

func cpuMs(_ pid: pid_t) -> Double {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return rc == 0 ? Double(info.ri_user_time + info.ri_system_time) * timebase / 1e6 : .nan
}

func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

/// Switches and waits until every target window holds the same frame for `stableFor`
func switchAndRecordSteadyFrames(_ ws: String, _ wins: [Win]) -> [UInt32: CGRect] {
    aerospace("workspace", ws)
    var last: [UInt32: CGRect] = [:]
    var since = now()
    let deadline = now() + pollTimeout
    while now() < deadline {
        let frames = onScreenFrames()
        let current = Dictionary(uniqueKeysWithValues: wins.compactMap { w in frames[w.id].map { (w.id, $0) } })
        if current != last { last = current; since = now() }
        if current.count == wins.count && now() - since >= stableFor { return current }
        usleep(2000)
    }
    fatalError("workspace \(ws) never settled: \(last.count)/\(wins.count) windows on screen")
}

let winsA = windows(wsA)
let winsB = windows(wsB)
precondition(!winsA.isEmpty && !winsB.isEmpty, "both workspaces need windows")
let appPids = Set((winsA + winsB).map(\.pid))

// Warm-up twice so lazily created state (the private Space, AX observers) is not in the first sample
var steady: [String: [UInt32: CGRect]] = [:]
for _ in 0 ..< 2 {
    steady[wsA] = switchAndRecordSteadyFrames(wsA, winsA)
    steady[wsB] = switchAndRecordSteadyFrames(wsB, winsB)
}

let header = "label\tcycle\ttarget\twindows\tcmd_ms\tshown_ms\thidden_ms\tsettled_ms\tapp_cpu_ms\tserver_cpu_ms\tleaked_windows\tleaked_px\ttimed_out\n"
var tsv = header
for cycle in 1 ... cycles {
    let (target, targetWins, sourceWins) = cycle % 2 == 1 ? (wsA, winsA, winsB) : (wsB, winsB, winsA)
    let targetFrames = steady[target]!
    usleep(300_000)
    let appCpu0 = appPids.map(cpuMs).reduce(0, +)
    let serverCpu0 = cpuMs(serverPid)
    let t0 = now()
    aerospace("workspace", target)
    let tCmd = now()
    var tShown: Double? = nil
    var tHidden: Double? = nil
    var frames: [UInt32: CGRect] = [:]
    while now() - t0 < pollTimeout, tShown == nil || tHidden == nil {
        frames = onScreenFrames()
        let t = now()
        if tShown == nil, targetWins.allSatisfy({ isAt($0.id, targetFrames[$0.id]!, frames) }) { tShown = t }
        if tHidden == nil, sourceWins.allSatisfy({ isSliverOrGone($0.id, frames) }) { tHidden = t }
        usleep(1000)
    }
    usleep(300_000) // Let the apps finish redrawing before reading CPU
    let appCpu = appPids.map(cpuMs).reduce(0, +) - appCpu0
    let serverCpu = cpuMs(serverPid) - serverCpu0
    frames = onScreenFrames()
    let leaked = sourceWins.filter { frames[$0.id] != nil }
    let leakedPx = leaked.reduce(0) { $0 + visibleArea(frames[$1.id]!) }
    func ms(_ t: Double?) -> String { t.map { String(format: "%.2f", ($0 - t0) * 1000) } ?? "NA" }
    let settled = tShown.flatMap { s in tHidden.map { max(s, $0) } }
    tsv += [label, "\(cycle)", target, "\(targetWins.count + sourceWins.count)", ms(tCmd), ms(tShown), ms(tHidden), ms(settled),
            String(format: "%.2f", appCpu), String(format: "%.2f", serverCpu), "\(leaked.count)", String(format: "%.0f", leakedPx),
            settled == nil ? "1" : "0"].joined(separator: "\t") + "\n"
}
try! tsv.write(to: outUrl, atomically: true, encoding: .utf8)
print(tsv, terminator: "")
