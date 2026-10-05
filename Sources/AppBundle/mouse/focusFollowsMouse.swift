import AppKit

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsTask: Task<(), any Error>? = nil

@MainActor func syncFocusFollowsMouse() {
    if config.focusFollowsMouse.enabled == (focusFollowsMouseMonitor != nil) {
        return
    }

    if !config.focusFollowsMouse.enabled {
        NSEvent.removeMonitor(focusFollowsMouseMonitor.orDie())
        focusFollowsMouseMonitor = nil
        focusFollowsTask?.cancel()
        focusFollowsTask = nil
        return
    }

    // Interestingly, this callback seems to not fire when the mouse is down which is good,
    // because this is how I want it to work for windows/tabs/files dragging
    focusFollowsMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { @MainActor event in
        let location = event.locationInWindow.withYAxisFlipped
        focusFollowsTask?.cancel()
        focusFollowsTask = Task.startUnstructured { @MainActor in
            // The next mouse move cancels this task, so focus only moves once the mouse rests for delayMs.
            // A focus change made meanwhile (a keyboard command, a click) wins over the mouse
            let delayMs = config.focusFollowsMouse.delayMs
            if delayMs > 0 {
                let focusedBefore = focus.windowOrNil
                try await Task.sleep(for: .milliseconds(delayMs))
                if focus.windowOrNil != focusedBefore { return }
            }
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try checkCancellation()
            // Hit-test, so the window macOS draws on top wins, regardless of floating/tiling/sticky.
            // Menubar dropdowns and menu-like fake windows resolve to no managed window and are ignored.
            // Accessibility goes first, because it skips click-through overlays. When it doesn't resolve to a managed
            // window (it fails on some web content in WKWebView-based apps), the window server's z-order is the fallback
            let axWindowId = await axWindowIdUnderMouse(location)
            try checkCancellation()
            guard let window = axWindowId.flatMap(Window.get(byId:)) ?? cgWindowIdUnderMouse(location).flatMap(Window.get(byId:))
            else { return }
            if let focused = focus.windowOrNil, focused != window, focused.nodeWorkspace == window.nodeWorkspace,
               try await isCoveringFloatingWindow(focused, location, percent: config.focusFollowsMouse.floatingCoverPercent)
            {
                return
            }
            if try await !isPastEdgeInset(window, location, inset: config.focusFollowsMouse.edgeInset) { return }
            try checkCancellation()
            // Hidden workspaces park their windows in a monitor corner, so they can still be hit-tested.
            // Checked after the awaits above, because a workspace switch may have happened meanwhile
            guard window.nodeWorkspace == location.monitorApproximation.activeWorkspace else { return }
            try await runLightSession(.focusFollowsMouse, token) {
                _ = window.focusWindow()
                window.nativeFocus()
            }
        }
    }
}

@concurrent
private nonisolated func axWindowIdUnderMouse(_ location: CGPoint) async -> CGWindowID? {
    let systemwide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    if unsafe AXUIElementCopyElementAtPosition(systemwide, Float(location.x), Float(location.y), &element) != .success {
        return nil
    }
    guard let element else { return nil }
    // Some elements (Electron, Qt, web content) lack kAXWindowAttribute; the private API resolves them directly
    return (element.get(Ax.parentWindowRecursive) ?? element).containingWindowId()
}

/// The frontmost on-screen window containing the location, in window server z-order
private func cgWindowIdUnderMouse(_ location: CGPoint) -> CGWindowID? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
    for window in windows {
        guard let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              bounds.contains(location),
              (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 // Fully transparent windows aren't seen
        else { continue }
        return window[kCGWindowNumber as String] as? CGWindowID
    }
    return nil
}

@MainActor
private func isPastEdgeInset(_ window: Window, _ point: CGPoint, inset: Int) async throws -> Bool {
    // An unknown frame can't prove the mouse is near the edge, so it doesn't block focus
    guard inset > 0, let rect = try await window.getAxRect(.cancellable) else { return true }
    // Cap the inset, so the middle half of a small window still takes focus
    let dx = min(CGFloat(inset), rect.width / 4)
    let dy = min(CGFloat(inset), rect.height / 4)
    return Rect(topLeftX: rect.minX + dx, topLeftY: rect.minY + dy, width: rect.width - 2 * dx, height: rect.height - 2 * dy)
        .contains(point)
}

@MainActor
private func isCoveringFloatingWindow(_ window: Window, _ point: CGPoint, percent: Int) async throws -> Bool {
    guard percent > 0, window.isFloating, let monitor = window.nodeMonitor else { return false }
    // Inside its frame, the mouse is over a window drawn on top of it (a dialog, a palette), which may take focus
    guard let rect = try await window.getAxRect(.cancellable), !rect.contains(point) else { return false }
    // Only the part of the window that lies on its monitor counts
    let visible = monitor.visibleRect
    let coveredWidth = min(rect.maxX, visible.maxX) - max(rect.minX, visible.minX)
    let coveredHeight = min(rect.maxY, visible.maxY) - max(rect.minY, visible.minY)
    let ratio = CGFloat(percent) / 100
    return coveredWidth >= visible.width * ratio && coveredHeight >= visible.height * ratio
}
