extension MonitorInfo {
    @MainActor
    var visibleRectPaddedByOuterGaps: Rect {
        visibleRect.inset(by: ResolvedGaps.Outer(config.gaps.outer, monitor: self))
    }

    /// The wall that floating windows can't cross. Each monitor has its own
    @MainActor
    var safeAreaRect: Rect {
        visibleRect.inset(by: ResolvedGaps.Outer(config.safeArea ?? config.gaps.outer, monitor: self))
    }

    var monitorId_oneBased: Int? {
        let sorted = globalSortedMonitorInfos
        let origin = self.rect.topLeftCorner
        return sorted.firstIndex { $0.rect.topLeftCorner == origin }.map { $0 + 1 }
    }
}
