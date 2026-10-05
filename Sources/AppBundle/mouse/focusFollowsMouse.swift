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
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            // The next mouse move cancels this task, so focus only moves once the mouse rests for delayMs
            let delayMs = config.focusFollowsMouse.delayMs
            if delayMs > 0 { try await Task.sleep(for: .milliseconds(delayMs)) }
            try checkCancellation()
            // Hit-test via accessibility, so the window macOS draws on top wins, regardless of floating/tiling/sticky.
            // Menubar dropdowns and menu-like fake windows resolve to no managed window and are ignored.
            guard let windowId = await axWindowIdUnderMouse(location) else { return }
            try checkCancellation()
            guard let window = Window.get(byId: windowId) else { return }
            if let focused = focus.windowOrNil, focused != window, focused.nodeWorkspace == window.nodeWorkspace,
               try await isCoveringFloatingWindow(focused, percent: config.focusFollowsMouse.floatingCoverPercent)
            {
                return
            }
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

@MainActor
private func isCoveringFloatingWindow(_ window: Window, percent: Int) async throws -> Bool {
    guard percent > 0, window.isFloating, let monitor = window.nodeMonitor else { return false }
    guard let rect = try await window.getAxRect(.cancellable) else { return false }
    // Only the part of the window that lies on its monitor counts
    let visible = monitor.visibleRect
    let coveredWidth = min(rect.maxX, visible.maxX) - max(rect.minX, visible.minX)
    let coveredHeight = min(rect.maxY, visible.maxY) - max(rect.minY, visible.minY)
    let ratio = CGFloat(percent) / 100
    return coveredWidth >= visible.width * ratio && coveredHeight >= visible.height * ratio
}
