import Cocoa

class Windows {
    static var list = [Window]()
    static var selectedWindowIndex = Int(0)
    static var selectedWindowTarget: String?
    static var hoveredWindowIndex: Int?
    private static var lastWindowActivityType = WindowActivityType.none
    
    // Cache for main window per app (cleared when window list changes significantly)
    private static var mainWindowCache = [Int32: CGWindowID?]()

    static func updateIsFullscreenOnCurrentSpace() {
        let windowsOnCurrentSpace = list.filter { !$0.isWindowlessApp }
        for window in windowsOnCurrentSpace {
            AXUIElement.retryAxCallUntilTimeout(context: window.debugId(), after: .now() + humanPerceptionDelay, callType: .updateWindow) { [weak window] in
                guard let window else { return }
                // we reuse existing code, to update .isFullscreen, as if there was a kAXWindowResizedNotification
                try AccessibilityEvents.handleEventWindow(kAXWindowResizedNotification, window.cgWindowId!, window.application.pid, window.axUiElement!)
            }
        }
    }

    private static func compareByAppNameThenWindowTitle(_ w1: Window, _ w2: Window) -> ComparisonResult {
        let order = w1.application.localizedName.localizedStandardCompare(w2.application.localizedName)
        if order == .orderedSame {
            return w1.title.localizedStandardCompare(w2.title)
        }
        return order
    }

    static func voiceOverWindow(_ windowIndex: Int = selectedWindowIndex) {
        guard App.app.appIsBeingUsed && App.app.thumbnailsPanel.isKeyWindow else { return }
        // it seems that sometimes makeFirstResponder is called before the view is visible
        // and it creates a delay in showing the main window; calling it with some delay seems to work around this
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
            let window = ThumbnailsView.recycledViews[windowIndex]
            if window.window_ != nil && window.window != nil {
                App.app.thumbnailsPanel.makeFirstResponder(window)
            }
        }
    }

    // Performance optimization: Cache last preview state to avoid redundant updates
    // see https://github.com/lwouis/alt-tab-macos/issues/5177
    private static var lastPreviewWindowId: CGWindowID?
    private static var lastPreviewShown: Bool = false
    private static var previewDebounceTimer: Timer?
    private static var pendingPreviewWindow: Window?
    
    /// Clear preview cache to free memory (called by CacheManager on idle)
    static func clearPreviewCache() {
        lastPreviewWindowId = nil
        lastPreviewShown = false
        previewDebounceTimer?.invalidate()
        previewDebounceTimer = nil
        pendingPreviewWindow = nil
        Logger.perf("Windows: Preview cache cleared")
    }
    
    static func previewSelectedWindowIfNeeded() {
        let shouldShow = App.app.appIsBeingUsed && ScreenRecordingPermission.status == .granted
               && Preferences.previewSelectedWindow && !Preferences.onlyShowApplications()
               && App.app.thumbnailsPanel.isKeyWindow
        
        if shouldShow,
           let window = selectedWindow(),
           let id = window.cgWindowId,
           let thumbnail = window.thumbnail,
           let position = window.position,
           let size = window.size {
            // Window changed - debounce to wait for geometry to settle
            if id != lastPreviewWindowId {
                // Cancel any pending preview
                previewDebounceTimer?.invalidate()
                pendingPreviewWindow = window
                
                // Wait 50ms for window geometry to settle before showing preview
                // This prevents size/position fluctuations during window transitions
                previewDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
                    guard let pendingWindow = pendingPreviewWindow,
                          pendingWindow.cgWindowId == id,
                          let thumbnail = pendingWindow.thumbnail,
                          let position = pendingWindow.position,
                          let size = pendingWindow.size else { return }
                    
                    App.app.previewPanel.show(id, thumbnail, position, size)
                    lastPreviewWindowId = id
                    lastPreviewShown = true
                    pendingPreviewWindow = nil
                    Logger.perf("Preview: Shown after geometry settled (id=\(id))")
                }
            } else if !lastPreviewShown {
                // Same window, just needs to be shown (no debounce needed)
                App.app.previewPanel.show(id, thumbnail, position, size)
                lastPreviewWindowId = id
                lastPreviewShown = true
            }
        } else {
            // Cancel any pending preview
            previewDebounceTimer?.invalidate()
            previewDebounceTimer = nil
            pendingPreviewWindow = nil
            
            // Only hide if it was showing before
            if lastPreviewShown {
                App.app.previewPanel.orderOut(nil)
                lastPreviewWindowId = nil
                lastPreviewShown = false
            }
        }
    }

    /// tabs detection is a flaky work-around the lack of public API to observe OS tabs
    /// see: https://github.com/lwouis/alt-tab-macos/issues/1540
    private static func detectTabbedWindows(_ window: Window, _ cgsWindowIds: [CGWindowID], _ visibleCgsWindowIds: [CGWindowID]) {
        if let cgWindowId = window.cgWindowId {
            if window.isMinimized || window.isHidden {
                if #available(macOS 13.0, *) {
                    // not exact after window merging
                    window.isTabbed = !cgsWindowIds.contains(cgWindowId)
                } else {
                    // not known
                    window.isTabbed = false
                }
            } else {
                window.isTabbed = !visibleCgsWindowIds.contains(cgWindowId)
            }
        }
    }

    static func updatesBeforeShowing() -> Bool {
        return Logger.section("updatesBeforeShowing") { section in
            if list.count == 0 || MissionControl.state() == .showAllWindows || MissionControl.state() == .showFrontWindows { return false }
            
            section.log("Processing \(list.count) windows")
        
            // TODO: find a way to update space info when spaces are changed, instead of on every trigger
            // workaround: when Preferences > Mission Control > "Displays have separate Spaces" is unchecked,
            // switching between displays doesn't trigger .activeSpaceDidChangeNotification; we get the latest manually
            section.step("Spaces.refresh") { Spaces.refresh() }
        
            let spaceIdsAndIndexes = Spaces.idsAndIndexes.map { $0.0 }
            lazy var cgsWindowIds = Spaces.windowsInSpaces(spaceIdsAndIndexes)
            lazy var visibleCgsWindowIds = Spaces.windowsInSpaces(spaceIdsAndIndexes, false)
            
            var updatedCount = 0
            var skippedCount = 0
            section.step("Window loop") {
                for window in list {
                    // Performance optimization: Only update windows that need updating
                    // see https://github.com/lwouis/alt-tab-macos/issues/5177
                    var needsUpdate = false
                    if window.needsTabDetection {
                        detectTabbedWindows(window, cgsWindowIds, visibleCgsWindowIds)
                        window.needsTabDetection = false
                        needsUpdate = true
                    }
                    if window.needsSpaceUpdate {
                        window.updateSpacesAndScreen()
                        window.needsSpaceUpdate = false
                        needsUpdate = true
                    }
                    if window.needsVisibilityUpdate {
                        refreshIfWindowShouldBeShownToTheUser(window)
                        window.needsVisibilityUpdate = false
                        needsUpdate = true
                    }
                    if needsUpdate {
                        updatedCount += 1
                    } else {
                        skippedCount += 1
                    }
                }
            }
            section.log("Window loop: updated: \(updatedCount), skipped: \(skippedCount)")
        
            section.step("refreshWhichWindowsToShowTheUser") { refreshWhichWindowsToShowTheUser() }
            section.step("sort") { sort() }
            
            if (!list.contains { $0.shouldShowTheUser }) { return false }
            return true
        }
    }

    // dispatch screenshot requests off the main-thread, then wait for completion
    static func refreshThumbnailsAsync(_ windows: [Window], _ source: RefreshCausedBy, windowRemoved: Bool = false) {
        guard (!windows.isEmpty || windowRemoved) && ScreenRecordingPermission.status == .granted
               && !Preferences.onlyShowApplications()
               && (!Appearance.hideThumbnails || Preferences.previewSelectedWindow) else { return }
        var eligibleWindows = [Window]()
        for window in windows {
            if !window.isWindowlessApp, let cgWindowId = window.cgWindowId, cgWindowId != CGWindowID(bitPattern: -1) {
                eligibleWindows.append(window)
            }
        }
        guard (!eligibleWindows.isEmpty || windowRemoved) else { return }
        if #available(macOS 14.0, *),
           // mitigate macOS 15 bugs with ScreenCapture Kit (see https://github.com/lwouis/alt-tab-macos/issues/5190)
           ProcessInfo.processInfo.operatingSystemVersion.majorVersion != 15 {
            WindowCaptureScreenshots.oneTimeScreenshots(eligibleWindows, source)
        } else {
            WindowCaptureScreenshotsPrivateApi.oneTimeScreenshots(eligibleWindows, source)
        }
    }

    static func refreshWhichWindowsToShowTheUser() {
        let appsToShowSetting = Preferences.appsToShow[App.app.shortcutIndex]
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Logger.perf("refreshWhichWindowsToShowTheUser: shortcutIndex=\(App.app.shortcutIndex), appsToShow=\(appsToShowSetting), frontmostPid=\(frontmostPid ?? -1)")
        
        // For shortcut 0 (cmd+tab): Show one window per app for quick app switching
        // For other shortcuts: Show all windows (already filtered by appsToShow)
        let shouldShowOnePerApp = App.app.shortcutIndex == 0 || Preferences.onlyShowApplications()
        
        if shouldShowOnePerApp {
            // Group windows by application and select the optimal main window
            let windowsGroupedByApp = Dictionary(grouping: list) { $0.application.pid }
            windowsGroupedByApp.forEach { (pid, windows) in
                if windows.count > 1 {
                    // Check cache first
                    let cachedMainWindowId = mainWindowCache[pid]
                    let mainWindow: Window?
                    
                    if let cachedId = cachedMainWindowId, let cached = windows.first(where: { $0.cgWindowId == cachedId }) {
                        // Use cached main window if it still exists
                        mainWindow = cached
                        Logger.cacheHit("Main window", details: "pid \(pid)")
                    } else {
                        // Cache miss - find main window (expensive)
                        mainWindow = findMainWindowSimple(windows)
                        if let mainWindowId = mainWindow?.cgWindowId {
                            mainWindowCache[pid] = mainWindowId
                            Logger.cacheMiss("Main window", reason: "pid \(pid) - cached \(mainWindowId)")
                        }
                    }
                    
                    if let mainWindow = mainWindow {
                        windows.forEach { window in
                            if window.cgWindowId != mainWindow.cgWindowId {
                                window.shouldShowTheUser = false
                            }
                        }
                    }
                }
            }
        }
        
        let visibleCount = list.filter { $0.shouldShowTheUser }.count
        Logger.perf("refreshWhichWindowsToShowTheUser: showing \(visibleCount) of \(list.count) windows (onePerApp: \(shouldShowOnePerApp))")
    }

    private static func refreshIfWindowShouldBeShownToTheUser(_ window: Window) {
        window.shouldShowTheUser =
            !(window.application.bundleIdentifier.flatMap { id in
                Preferences.blacklist.contains {
                    id.hasPrefix($0.bundleIdentifier) &&
                        ($0.hide == .always || (window.isWindowlessApp && $0.hide != .none))
                }
            } ?? false) &&
            !(Preferences.appsToShow[App.app.shortcutIndex] == .active && window.application.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier) &&
            !(Preferences.appsToShow[App.app.shortcutIndex] == .nonActive && window.application.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier) &&
            !(!(Preferences.showHiddenWindows[App.app.shortcutIndex] != .hide) && window.isHidden) &&
            ((Preferences.showWindowlessApps[App.app.shortcutIndex] != .hide && window.isWindowlessApp) ||
                !window.isWindowlessApp &&
                !(!(Preferences.showFullscreenWindows[App.app.shortcutIndex] != .hide) && window.isFullscreen) &&
                !(!(Preferences.showMinimizedWindows[App.app.shortcutIndex] != .hide) && window.isMinimized) &&
                !(Preferences.spacesToShow[App.app.shortcutIndex] == .visible && !Spaces.visibleSpaces.contains { visibleSpace in window.spaceIds.contains { $0 == visibleSpace } }) &&
                !(Preferences.screensToShow[App.app.shortcutIndex] == .showingAltTab && !window.isOnScreen(NSScreen.preferred)) &&
                (Preferences.showTabsAsWindows || !window.isTabbed))
    }

    /// Fast version of findMainWindow that avoids expensive AX calls
    /// Uses simple heuristics: focused window > most recently focused > first visible
    static func findMainWindowSimple(_ windows: [Window]) -> Window? {
        let visibleWindows = windows.filter { $0.shouldShowTheUser }
        if visibleWindows.isEmpty { return nil }
        
        // Prefer the focused window
        if let focusedWindowId = windows.first?.application.focusedWindow?.cgWindowId,
           let focusedWindow = visibleWindows.first(where: { $0.cgWindowId == focusedWindowId }) {
            return focusedWindow
        }
        
        // Prefer most recently focused window (lowest lastFocusOrder)
        return visibleWindows.min(by: { $0.lastFocusOrder < $1.lastFocusOrder })
    }
    
    /// Selects the most appropriate main window from a given list of windows.
    ///
    /// The selection criteria are as follows:
    /// 1. Prefer the focused window if it exists.
    /// 2. Prefer the main window of the application if the focused window is not found.
    ///
    /// - Parameter windows: An array of `Window` objects to select from.
    /// - Returns: The most appropriate `Window` object based on the selection criteria, or `nil` if the array is empty.
    static func findMainWindow(_ windows: [Window]) -> Window? {
        let sortedWindows = windows.sorted { (window1, window2) -> Bool in
            // Prefer the focus window
            if window1.application.focusedWindow?.cgWindowId == window1.cgWindowId {
                return true
            } else if window2.application.focusedWindow?.cgWindowId == window2.cgWindowId {
                return false
            }
            // Prefer the main window
            if window1.isAppMainWindow() && !window2.isAppMainWindow() {
                return true
            } else if !window1.isAppMainWindow() && window2.isAppMainWindow() {
                return false
            }
            return true
        }
        return sortedWindows.first { $0.shouldShowTheUser }
    }

    /// selectedWindowIndex methods
    //////////////////////////////

    static func selectedWindow() -> Window? {
        return list.count > selectedWindowIndex ? list[selectedWindowIndex] : nil
    }

    static func setInitialSelectedAndHoveredWindowIndex() {
        let oldIndex = selectedWindowIndex
        selectedWindowIndex = 0
        selectedWindowTarget = nil
        ThumbnailsView.highlight(oldIndex)
        if let oldIndex = hoveredWindowIndex {
            hoveredWindowIndex = nil
            ThumbnailsView.highlight(oldIndex)
        }
        if let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let frontmostApp = Applications.findOrCreate(frontmostPid),
           (frontmostApp.focusedWindow == nil || Preferences.windowOrder[App.app.shortcutIndex] != .recentlyFocused),
           let lastFocusedOrderWindowIndex = getLastFocusedOrderWindowIndex() {
            updateSelectedAndHoveredWindowIndex(lastFocusedOrderWindowIndex)
        } else {
            cycleSelectedWindowIndex(1)
            if selectedWindowIndex == 0 {
                updateSelectedAndHoveredWindowIndex(0)
            }
        }
    }

    static func updateSelectedWindow() {
        guard let index = (list.firstIndex { $0.id == selectedWindowTarget }) else {
            setInitialSelectedAndHoveredWindowIndex()
            return
        }
        updateSelectedAndHoveredWindowIndex(index)
    }

    static func updateSelectedAndHoveredWindowIndex(_ newIndex: Int, _ fromMouse: Bool = false) {
        Logger.section("updateSelectedAndHoveredWindowIndex") { section in
        
        var index: Int?
        if fromMouse && (newIndex != hoveredWindowIndex || lastWindowActivityType == .focus) {
            let oldIndex = hoveredWindowIndex
            hoveredWindowIndex = newIndex
            if let oldIndex {
                ThumbnailsView.highlight(oldIndex)
            }
            index = hoveredWindowIndex
            lastWindowActivityType = .hover
        }
        if (!fromMouse || Preferences.mouseHoverEnabled)
               && (newIndex != selectedWindowIndex || lastWindowActivityType == .hover) {
            let oldIndex = selectedWindowIndex
            selectedWindowIndex = newIndex
            selectedWindowTarget = list[newIndex].id
            
            section.step("highlight(old)") { ThumbnailsView.highlight(oldIndex) }
            section.step("previewSelectedWindowIfNeeded") { previewSelectedWindowIfNeeded() }
            
            index = selectedWindowIndex
            lastWindowActivityType = .focus
        }
        guard let index else { return }
        
            section.step("highlight(new)") { ThumbnailsView.highlight(index) }
            
            let focusedView = ThumbnailsView.recycledViews[index]
            
            section.step("scrollToVisible") {
                App.app.thumbnailsPanel.thumbnailsView.scrollView.contentView.scrollToVisible(focusedView.frame)
            }
            
            section.step("voiceOverWindow") { voiceOverWindow(index) }
        }
    }

    static func cycleSelectedWindowIndex(_ step: Int, allowWrap: Bool = true) {
        Logger.section("cycleSelectedWindowIndex: Tab pressed, step=\(step)") { section in
            guard App.app.appIsBeingUsed else { return }
            let nextIndex = selectedWindowIndexAfterCycling(step)
            // don't wrap-around at the end, if key-repeat
            if (((step > 0 && nextIndex < selectedWindowIndex) || (step < 0 && nextIndex > selectedWindowIndex)) &&
                (!allowWrap || ATShortcut.lastEventIsARepeat || !KeyRepeatTimer.timerIsSuspended))
                   // don't cycle to another row, if !allowWrap
                   || (!allowWrap && list[nextIndex].rowIndex != list[selectedWindowIndex].rowIndex) {
                section.log("Skipped (constraints)")
                return
            }
            updateSelectedAndHoveredWindowIndex(nextIndex)
        }
    }

    static func selectedWindowIndexAfterCycling(_ step: Int) -> Int {
        if list.count == 0 { return 0 }
        var iterations = 0
        var targetIndex = selectedWindowIndex
        repeat {
            let next = (targetIndex + step) % list.count
            targetIndex = next < 0 ? list.count + next : next
            iterations += 1
        } while !list[targetIndex].shouldShowTheUser && iterations <= list.count
        return targetIndex
    }

    /// lastFocusOrder methods
    //////////////////////////////

    /// Updates windows "lastFocusOrder" to ensure unique values based on window z-order.
    /// Windows are ordered by their position in Spaces.windowsInSpaces() results,
    /// with topmost windows first.
    static func sortByLevel() {
        var windowLevelMap = [CGWindowID?: Int]()
        for (index, cgWindowId) in Spaces.windowsInSpaces(Spaces.visibleSpaces).enumerated() {
            windowLevelMap[cgWindowId] = index
        }
        list = list
        .sorted { w1, w2 in
            (windowLevelMap[w1.cgWindowId] ?? .max) < (windowLevelMap[w2.cgWindowId] ?? .max)
        }
        .enumerated()
        .map { (index, window) -> Window in
            window.lastFocusOrder = index
            return window
        }
    }

    /// reordered list based on preferences, keeping the original index
    private static func sort() {
        list.sort {
            // separate buckets for these types of windows
            if Preferences.showWindowlessApps[App.app.shortcutIndex] == .showAtTheEnd && $0.isWindowlessApp != $1.isWindowlessApp {
                return $1.isWindowlessApp
            }
            if Preferences.showHiddenWindows[App.app.shortcutIndex] == .showAtTheEnd && $0.isHidden != $1.isHidden {
                return $1.isHidden
            }
            if Preferences.showMinimizedWindows[App.app.shortcutIndex] == .showAtTheEnd && $0.isMinimized != $1.isMinimized {
                return $1.isMinimized
            }
            // sort within each buckets
            let sortType = Preferences.windowOrder[App.app.shortcutIndex]
            if sortType == .recentlyFocused {
                return $0.lastFocusOrder < $1.lastFocusOrder
            }
            if sortType == .recentlyCreated {
                return $1.creationOrder < $0.creationOrder
            }
            var order = ComparisonResult.orderedSame
            if sortType == .alphabetical {
                order = compareByAppNameThenWindowTitle($0, $1)
            }
            if sortType == .space {
                if $0.isOnAllSpaces && $1.isOnAllSpaces {
                    order = .orderedSame
                } else if $0.isOnAllSpaces {
                    order = .orderedAscending
                } else if $1.isOnAllSpaces {
                    order = .orderedDescending
                } else if let spaceIndex0 = $0.spaceIndexes.first, let spaceIndex1 = $1.spaceIndexes.first {
                    order = spaceIndex0.compare(spaceIndex1)
                }
                if order == .orderedSame {
                    order = compareByAppNameThenWindowTitle($0, $1)
                }
            }
            if order == .orderedSame {
                order = $0.lastFocusOrder.compare($1.lastFocusOrder)
            }
            return order == .orderedAscending
        }
    }

    static func getLastFocusedOrderWindowIndex() -> Int? {
        var index: Int? = nil
        var lastFocusOrderMin = Int.max
        for (offset, w) in list.enumerated() {
            if !w.isWindowlessApp && w.shouldShowTheUser && w.lastFocusOrder < lastFocusOrderMin {
                lastFocusOrderMin = w.lastFocusOrder
                index = offset
            }
        }
        return index
    }

    static func updateLastFocusOrder(_ focusedWindow: Window) -> [Window]? {
        // no need to update the list is the window is already lastFocusOrder 0
        guard focusedWindow.lastFocusOrder != 0 && list.count > 1, let previousFocus = (list.first { $0.lastFocusOrder == 0 }) else { return [focusedWindow] }
        // 2 windows have recently changed: the one which got focused, and the one who just lost focus
        let windowsToRefresh = [focusedWindow, previousFocus]
        let focusedWindowOldFocusOrder = focusedWindow.lastFocusOrder
        list.forEach {
            if $0.lastFocusOrder == focusedWindowOldFocusOrder {
                $0.lastFocusOrder = 0
            } else if $0.lastFocusOrder < focusedWindowOldFocusOrder {
                $0.lastFocusOrder += 1
            }
        }
        return windowsToRefresh
    }

    static func findOrCreate(_ windowAxUiElement: AXUIElement, _ wid: CGWindowID, _ app: Application, _ level: CGWindowLevel, _ title: String?, _ subrole: String?, _ role: String?, _ size: CGSize?, _ position: CGPoint?, _ isFullscreen: Bool?, _ isMinimized: Bool?) -> Window? {
        if let window = (list.first { $0.isEqualRobust(windowAxUiElement, wid) }) {
            // on any window event, we take the opportunity to refresh all window attributes
            window.updateFromAxAttributes(title, size, position, isFullscreen, isMinimized)
            return window
        }
        guard WindowDiscriminator.isActualWindow(app, wid, level, title, subrole, role, size) else { return nil }
        let window = Window(windowAxUiElement, app, wid, title, isFullscreen, isMinimized, position, size)
        appendWindow(window)
        return window
    }

    static func appendWindow(_ window: Window) {
        list.forEach {
            $0.lastFocusOrder += 1
        }
        list.append(window)
        if list.count > ThumbnailsView.recycledViews.count {
            ThumbnailsView.recycledViews.append(ThumbnailView())
        }
    }

    static func removeWindows(_ windows: [Window], _ addWindowlessWindowIfNeeded: Bool) {
        let toRemove = windows.map { $0.lastFocusOrder }
        list.removeAll { w in
            if toRemove.contains(w.lastFocusOrder) {
                return true
            }
            let howManyToShift = toRemove.reduce(0) { $1 < w.lastFocusOrder ? $0 + 1 : $0 }
            w.lastFocusOrder -= howManyToShift
            return false
        }
        if addWindowlessWindowIfNeeded {
            windows.forEach { $0.application.addWindowlessWindowIfNeeded() }
        }
        App.app.refreshOpenUi([], .refreshUiAfterExternalEvent, windowRemoved: true)
    }
}

enum WindowActivityType: Int {
    case none = 0
    case hover = 1
    case focus = 2
}
