@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

@MainActor
@discardableResult
func ignoreFocusFromAppIfNeeded(bundleId: String?) -> Bool {
    guard let bundleId, config.ignoreFocusFrom.contains(bundleId) else { return false }
    guard let restoreWindow = focus.windowOrNil else { return true }
    guard restoreWindow.app.rawAppBundleId != bundleId else { return true }
    guard restoreWindow.app.rawAppBundleId.map({ !config.ignoreFocusFrom.contains($0) }) ?? true else { return true }
    restoreWindow.nativeFocus()
    return true
}

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if ignoreFocusFromAppIfNeeded(bundleId: nativeFocused?.app.rawAppBundleId) {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}
