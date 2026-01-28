import Cocoa

class ThumbnailsPanel: NSPanel {
    var thumbnailsView = ThumbnailsView()
    override var canBecomeKey: Bool { true }
    private var didDisplayOnce = false
    static var maxPossibleThumbnailSize = NSSize.zero
    static var maxPossibleAppIconSize = NSSize.zero

    convenience init() {
        self.init(contentRect: .zero, styleMask: .nonactivatingPanel, backing: .buffered, defer: false)
        delegate = self
        isFloatingPanel = true
        animationBehavior = .none
        hidesOnDeactivate = false
        titleVisibility = .hidden
        backgroundColor = .clear
        contentView! = thumbnailsView.contentView
        // triggering AltTab before or during Space transition animation brings the window on the Space post-transition
        collectionBehavior = .canJoinAllSpaces
        // 2nd highest level possible; this allows the app to go on top of context menus
        // highest level is .screenSaver but makes drag and drop on top the main window impossible
        level = .popUpMenu
        // helps filter out this window from the thumbnails
        setAccessibilitySubrole(.unknown)
        // for VoiceOver
        setAccessibilityLabel(App.name)
        updateAppearance()
    }

    func updateAppearance() {
        hasShadow = Appearance.enablePanelShadow
        appearance = NSAppearance(named: Appearance.currentTheme == .dark ? .vibrantDark : .vibrantLight)
    }

    private var lastLayoutTime: DispatchTime = .now()
    
    func updateContents() {
        // Workaround for macOS 15+ hang: throttle full layout passes during rapid interaction
        // External events (window title changes, moves) can trigger expensive layouts while cycling
        // Skip if we just did a layout less than 100ms ago
        // see https://github.com/lwouis/alt-tab-macos/issues/5177
        let now = DispatchTime.now()
        let timeSinceLastLayout = now.uptimeNanoseconds - lastLayoutTime.uptimeNanoseconds
        if timeSinceLastLayout < 100_000_000 { // 100ms in nanoseconds
            return
        }
        lastLayoutTime = now
        
        CATransaction.begin()
        defer { CATransaction.commit() }
        CATransaction.setDisableActions(true)
        thumbnailsView.updateItemsAndLayout()
        guard App.app.appIsBeingUsed else { return }
        setContentSize(thumbnailsView.contentView.frame.size)
        guard App.app.appIsBeingUsed else { return }
        NSScreen.preferred.repositionPanel(self)
    }

    override func orderOut(_ sender: Any?) {
        didDisplayOnce = false
        if Preferences.fadeOutAnimation {
            NSAnimationContext.runAnimationGroup(
                { _ in animator().alphaValue = 0 },
                completionHandler: { super.orderOut(sender) }
            )
        } else {
            super.orderOut(sender)
        }
    }

    override func displayIfNeeded() {
        super.displayIfNeeded()
        if !didDisplayOnce {
            didDisplayOnce = true
            DispatchQueue.main.async {
                Applications.manuallyRefreshAllWindows()
            }
        }
    }

    func show() {
        updateAppearance()
        alphaValue = 1
        makeKeyAndOrderFront(nil)
        MouseEvents.toggle(true)
        CursorEvents.toggle(true)
        thumbnailsView.scrollView.flashScrollers()
    }

    // Performance optimization: Cache screen dimensions per display
    // Prevents layout recalculation when switching between displays
    // see https://github.com/lwouis/alt-tab-macos/issues/5177
    private static var cachedScreenDimensions: [ScreenUuid: (width: CGFloat, height: CGFloat)] = [:]
    
    static func maxThumbnailsWidth(_ screen: NSScreen = NSScreen.preferred) -> CGFloat {
        // Check cache first
        if let uuid = screen.uuid(), let cached = cachedScreenDimensions[uuid] {
            PerfLogger.log("Screen dimensions cache HIT for display \(uuid)")
            return cached.width
        }
        
        // Calculate and cache
        PerfLogger.log("Screen dimensions cache MISS - calculating for display \(screen.uuid() ?? "unknown" as CFString)")
        let width: CGFloat
        if Preferences.appearanceStyle == .titles,
           let readableWidth = ThumbnailView.widthOfComfortableReadability() {
            width = (
                min(
                    screen.frame.width * Appearance.maxWidthOnScreen,
                    readableWidth + Appearance.intraCellPadding * 2 + Appearance.appIconLabelSpacing + Appearance.iconSize
                    // widthOfLongestTitle + Appearance.intraCellPadding * 2 + Appearance.appIconLabelSpacing + Appearance.iconSize
                ) - Appearance.windowPadding * 2
            ).rounded()
        } else {
            width = (screen.frame.width * Appearance.maxWidthOnScreen - Appearance.windowPadding * 2).rounded()
        }
        
        if let uuid = screen.uuid() {
            let height = (screen.frame.height * Appearance.maxHeightOnScreen - Appearance.windowPadding * 2).rounded()
            cachedScreenDimensions[uuid] = (width, height)
        }
        
        return width
    }

    static func maxThumbnailsHeight(_ screen: NSScreen = NSScreen.preferred) -> CGFloat {
        // Check cache first
        if let uuid = screen.uuid(), let cached = cachedScreenDimensions[uuid] {
            return cached.height
        }
        
        // Calculate and cache (will be cached by maxThumbnailsWidth call)
        _ = maxThumbnailsWidth(screen)
        return cachedScreenDimensions[screen.uuid() ?? "" as CFString]?.height ?? (screen.frame.height * Appearance.maxHeightOnScreen - Appearance.windowPadding * 2).rounded()
    }
    
    static func clearScreenDimensionCache() {
        cachedScreenDimensions.removeAll()
        PerfLogger.log("ThumbnailsPanel: Screen dimension cache cleared (\(cachedScreenDimensions.count) entries)")
    }

    static func updateMaxPossibleThumbnailSize() {
        let (w, h) = NSScreen.screens.reduce((CGFloat.zero, CGFloat.zero)) { acc, screen in
            (max(acc.0, ThumbnailView.maxThumbnailWidth(screen) * screen.backingScaleFactor),
            max(acc.1, ThumbnailView.maxThumbnailHeight(screen) * screen.backingScaleFactor))
        }
        maxPossibleThumbnailSize = NSSize(width: w.rounded(), height: h.rounded())
    }

    static func updateMaxPossibleAppIconSize() {
        let (w, h) = NSScreen.screens.reduce((CGFloat.zero, CGFloat.zero)) { acc, screen in
            // in Thumbnails Appearance, AppIcons can be used for windowless apps, thus much bigger than the app icon near the title
            if Preferences.appearanceStyle == .thumbnails {
                return (max(acc.0, ThumbnailView.maxThumbnailWidth(screen) * screen.backingScaleFactor),
                    max(acc.1, ThumbnailView.maxThumbnailHeight(screen) * screen.backingScaleFactor))
            } else {
                let size = ThumbnailView.iconSize(screen)
                return (max(acc.0, size.width * screen.backingScaleFactor),
                    max(acc.1, size.height * screen.backingScaleFactor))
            }
        }
        maxPossibleAppIconSize = NSSize(width: w.rounded(), height: h.rounded())
    }
}

extension ThumbnailsPanel: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        // other windows can steal key focus from alt-tab; we make sure that if it's active, if keeps key focus
        // dispatching to the main queue is necessary to introduce a delay in scheduling the makeKey; otherwise it is ignored
        DispatchQueue.main.async {
            if App.app.appIsBeingUsed {
                App.app.thumbnailsPanel.makeKeyAndOrderFront(nil)
            }
            MainMenu.toggle(enabled: true)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // we toggle the mainMenu off when showing the main window
        // this avoids command+q from quitting AltTab itself, or command+p from printing
        DispatchQueue.main.async {
            MainMenu.toggle(enabled: false)
        }
    }
}