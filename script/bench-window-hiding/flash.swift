// Usage: flash-check <x> <y> <w> <h> <aerospace-cli> <args...>
// Records the main display while the command runs and labels each frame inside the rect of the window being shown:
// old content (A) or new (B), title as in the first/last frame (*) or not (-). Exits 1 when the new window's title
// changes more than once, 3 when only the old content comes back for a moment after the new one showed.
// Exits 2 when the run proves nothing: the rect is off the main display, the command failed, or nothing switched.
// Needs Screen Recording for the calling process.
import CoreMedia
import ScreenCaptureKit

func invalid(_ reason: String) -> Never {
    print(reason)
    exit(2)
}

let rect = CommandLine.arguments.dropFirst().prefix(4).compactMap { Int($0) }
guard CommandLine.arguments.count > 5, rect.count == 4 else { invalid("usage: flash-check <x> <y> <w> <h> <cli> <args...>") }
let command = Array(CommandLine.arguments[5...])
let titleHeight = 52

struct Frame { let ms: Double; let pixels: [UInt8] } // RGB of the rect, every 2nd pixel

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    let lock = NSLock()
    var start: CMTime? = nil
    var frames: [Frame] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = info.first?[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
              let pb = sb.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var pixels: [UInt8] = []
        for y in stride(from: rect[1], to: min(rect[1] + rect[3], CVPixelBufferGetHeight(pb)), by: 2) {
            for x in stride(from: rect[0], to: min(rect[0] + rect[2], CVPixelBufferGetWidth(pb)), by: 2) {
                let p = base + y * bpr + x * 4 // BGRA
                pixels += [p[2], p[1], p[0]]
            }
        }
        lock.withLock {
            let ms = start.map { (CMSampleBufferGetPresentationTimeStamp(sb) - $0).seconds * 1000 } ?? -1
            frames.append(Frame(ms: ms, pixels: pixels))
        }
    }
}

/// Mean luminance of the per-channel difference, over rows [fromRow, toRow) of the sampled rect
func diff(_ a: Frame, _ b: Frame, rows: Range<Int>) -> Double {
    let width = (rect[2] + 1) / 2
    var sum = 0.0
    var n = 0
    for row in rows {
        for col in 0 ..< width {
            let i = (row * width + col) * 3
            guard i + 2 < min(a.pixels.count, b.pixels.count) else { continue }
            let d = { (k: Int) in Double(abs(Int(a.pixels[i + k]) - Int(b.pixels[i + k]))) }
            sum += 0.299 * d(0) + 0.587 * d(1) + 0.114 * d(2)
            n += 1
        }
    }
    return n == 0 ? 0 : sum / Double(n)
}

guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
      let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
else { invalid("can't capture the screen (Screen Recording permission?)") }
guard rect[0] >= 0, rect[1] >= 0, rect[2] > 0, rect[3] > 0, rect[0] + rect[2] <= display.width, rect[1] + rect[3] <= display.height else {
    invalid("rect \(rect) is not inside the main display \(display.width)x\(display.height)")
}
let config = SCStreamConfiguration()
config.width = display.width
config.height = display.height
config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
config.pixelFormat = kCVPixelFormatType_32BGRA
config.showsCursor = false
let recorder = Recorder()
let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "flash-check"))
try await stream.startCapture()
try await Task.sleep(for: .milliseconds(300)) // a first frame of the old state
let process = Process()
process.executableURL = URL(fileURLWithPath: command[0])
process.arguments = Array(command.dropFirst())
recorder.lock.withLock { recorder.start = CMClockGetTime(CMClockGetHostTimeClock()) }
try process.run()
try await Task.sleep(for: .milliseconds(1500))
try await stream.stopCapture()
process.waitUntilExit()
guard process.terminationStatus == 0 else { invalid("\(command.joined(separator: " ")) exited with \(process.terminationStatus)") }

let frames = recorder.lock.withLock { recorder.frames.sorted { $0.ms < $1.ms } }
guard let old = frames.first, let new = frames.last, frames.count > 2, !old.pixels.isEmpty else {
    invalid("no frames recorded")
}
let rows = (rect[3] + 1) / 2
let titleRows = 0 ..< titleHeight / 2
let contentRows = min(titleHeight + 8, rows) ..< rows
guard diff(old, new, rows: contentRows) > 10 else {
    invalid("the rect shows the same content before (\(Int(old.ms)) ms) and after (\(Int(new.ms)) ms) the command, diff \(diff(old, new, rows: contentRows))")
}
var path: [(ms: Double, label: String)] = []
for frame in frames {
    let isNew = diff(frame, new, rows: contentRows) < diff(frame, old, rows: contentRows)
    let label = (isNew ? "B" : "A") + (diff(frame, isNew ? new : old, rows: titleRows) < 4 ? "*" : "-")
    if path.last?.label != label { path.append((frame.ms, label)) }
}
let labels = path.map(\.label)
let reverted = labels.indices.contains { i in labels[i].hasPrefix("B") && labels[(i + 1)...].contains { $0.hasPrefix("A") } }
let titles = labels.filter { $0.hasPrefix("B") }.map(\.last!)
let toggles = zip(titles, titles.dropFirst()).count(where: { $0 != $1 })
print(path.map { "\($0.label)@\(Int($0.ms))" }.joined(separator: " "))
exit(toggles > (titles.first == "*" ? 0 : 1) ? 1 : reverted ? 3 : 0)
