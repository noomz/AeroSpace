import AppKit
import Common

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws { // todo revisit API
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitorInfo.visibleRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        try await layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, LayoutContext(self))
    }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
            case .monitor(let it):
                try await it.getWorkspacesContainerOrCreate().getVisibleWorkspaceOrCreate(parent: it)
                    .layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .workspacesContainer: die()
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                try await workspace.rootTilingContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
                try await workspace.floatingWindowsContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .floatingWindowsContainer(let container):
                let windows = container.children.filterIsInstance(of: Window.self)
                // todo make it parallel among different workspaces. Get rid of 'try await'
                let rects = try await windows.mapConcurrently { try await $0.getAxRect(.cancellable) } // Probably not idempotent
                for (window, windowRect) in zip(windows, rects) {
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    window.layoutFloatingWindow(context, windowRect)
                }
            case .window(let window):
                if window.windowId != currentlyManipulatedWithMouseWindowId {
                    lastAppliedLayoutVirtualRect = virtual
                    if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                        lastAppliedLayoutPhysicalRect = nil
                        window.layoutFullscreen(context)
                    } else {
                        lastAppliedLayoutPhysicalRect = physicalRect
                        window.isFullscreen = false
                        window.setAxFrame(point, CGSize(width: width, height: height))
                    }
                }
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                switch container.layout {
                    case .tiles:
                        try await container.layoutTiles(point, width: width, height: height, virtual: virtual, context)
                    case .accordion:
                        try await container.layoutAccordion(point, width: width, height: height, virtual: virtual, context)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }
}

private struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps

    @MainActor
    init(_ workspace: Workspace) {
        self.workspace = workspace
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitorInfo)
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext, _ windowRect: Rect?) {
        let monitor = context.workspace.workspaceMonitorInfo
        var target = windowRect.map {
            $0.movedToMonitor(from: $0.center.monitorApproximation.visibleRect, to: monitor.visibleRect)
        }
        if isFullscreen {
            target = fullscreenRect(context)
            isFullscreen = false
        }
        guard var target else { return }
        // The wall waits for the drop. During a drag it would fight the mouse and block crossing to another monitor
        if !isLeftMouseButtonDown {
            target = target.clamped(in: monitor.safeAreaRect)
        }
        let resized = windowRect.map { !$0.size.isClose(to: target.size) } ?? true
        let moved = windowRect.map { !$0.topLeftCorner.isClose(to: target.topLeftCorner) } ?? true
        if moved || resized {
            setAxFrame(target.topLeftCorner, resized ? target.size : nil)
        }
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let rect = fullscreenRect(context)
        setAxFrame(rect.topLeftCorner, rect.size)
    }

    @MainActor
    private func fullscreenRect(_ context: LayoutContext) -> Rect {
        noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitorInfo.visibleRect
            : context.workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps
    }
}

extension Rect {
    /// A floating window that sits on monitor `from` but belongs to monitor `to` moves to the same relative spot on `to`.
    /// The window counts as already on `to` when its top-left is there, even if its center is not. A window bigger
    /// than its monitor has its top-left pinned by the safe area, and its center can land on a neighbor monitor
    func movedToMonitor(from: Rect, to: Rect) -> Rect {
        if from == to || to.contains(topLeftCorner) { return self }
        return Rect(
            topLeftX: to.topLeftX + (topLeftX - from.topLeftX) / from.width * to.width,
            topLeftY: to.topLeftY + (topLeftY - from.topLeftY) / from.height * to.height,
            width: width,
            height: height,
        )
    }
}

extension CGPoint {
    fileprivate func isClose(to other: CGPoint) -> Bool { abs(x - other.x) <= 1 && abs(y - other.y) <= 1 }
}

extension CGSize {
    fileprivate func isClose(to other: CGSize) -> Bool { abs(width - other.width) <= 1 && abs(height - other.height) <= 1 }
}

extension TilingContainer {
    @MainActor
    fileprivate func layoutTiles(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        var point = point
        var virtualPoint = virtual.topLeftCorner

        let inhabitedChildren = inhabitedChildren

        guard let delta = ((orientation == .h ? width : height) - CGFloat(inhabitedChildren.sumOfDouble { $0.getWeight(orientation) }))
            .div(inhabitedChildren.count) else { return }

        let lastIndex = inhabitedChildren.indices.last
        for (i, child) in inhabitedChildren.enumerated() {
            child.setWeight(orientation, child.getWeight(orientation) + delta)
            let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
            // Gaps. Consider 4 cases:
            // 1. Multiple children. Layout first child
            // 2. Multiple children. Layout last child
            // 3. Multiple children. Layout child in the middle
            // 4. Single child   let rawGap = gaps.inner.get(orientation).toDouble()
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            try await child.layoutRecursive(
                i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? child.hWeight - gap : width,
                height: orientation == .v ? child.vWeight - gap : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? child.hWeight : width,
                    height: orientation == .v ? child.vWeight : height,
                ),
                context,
            )
            virtualPoint = orientation == .h ? virtualPoint.addingXOffset(child.hWeight) : virtualPoint.addingYOffset(child.vWeight)
            point = orientation == .h ? point.addingXOffset(child.hWeight) : point.addingYOffset(child.vWeight)
        }
    }

    @MainActor
    fileprivate func layoutAccordion(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let inhabitedChildren = inhabitedChildren

        guard let mruIndex: Int = mostRecentInhabitedChild?.ownIndex(in: .inhabitedOnly) else { return }
        for (index, child) in inhabitedChildren.enumerated() {
            let padding = CGFloat(config.accordionPadding)
            let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                case 0 where inhabitedChildren.count == 1: (0, 0)
                case 0:                                (0, padding)
                case inhabitedChildren.indices.last:   (padding, 0)
                case mruIndex - 1:                     (0, 2 * padding)
                case mruIndex + 1:                     (2 * padding, 0)
                default:                               (padding, padding)
            }
            switch orientation {
                case .h:
                    try await child.layoutRecursive(
                        point + CGPoint(x: lPadding, y: 0),
                        width: width - rPadding - lPadding,
                        height: height,
                        virtual: virtual,
                        context,
                    )
                case .v:
                    try await child.layoutRecursive(
                        point + CGPoint(x: 0, y: lPadding),
                        width: width,
                        height: height - lPadding - rPadding,
                        virtual: virtual,
                        context,
                    )
            }
        }
    }
}
