import Foundation

/// Memory-efficient cache manager with configurable idle expiration
/// Automatically clears caches after idle period to free memory
/// see https://github.com/lwouis/alt-tab-macos/issues/5177
class CacheManager {
    // MARK: - Configuration
    
    /// Time to wait after last UI hide before clearing caches
    /// Configured via preferences (default: 60 seconds)
    static var cacheExpirationSeconds: TimeInterval {
        return TimeInterval(Preferences.cacheExpirationSeconds)
    }
    
    // MARK: - Private State
    
    private static var expirationTimer: Timer?
    private static var isUiActive = false
    
    // MARK: - Public Interface
    
    /// Call when UI is shown - cancels any pending cache expiration
    static func uiDidShow() {
        isUiActive = true
        cancelExpirationTimer()
        Logger.perf("CacheManager: UI shown, cache expiration cancelled")
    }
    
    /// Call when UI is hidden - schedules cache expiration
    static func uiDidHide() {
        isUiActive = false
        scheduleExpirationTimer()
        Logger.perf("CacheManager: UI hidden, cache expiration scheduled for \(cacheExpirationSeconds)s")
    }
    
    /// Manually clear all caches immediately
    static func clearAllCaches() {
        clearLayoutCaches()
        clearScreenCaches()
        clearPreviewCaches()
        clearImageCaches()
        Logger.perf("CacheManager: All caches cleared manually")
    }
    
    // MARK: - Private Implementation
    
    private static func scheduleExpirationTimer() {
        cancelExpirationTimer()
        
        expirationTimer = Timer.scheduledTimer(
            withTimeInterval: cacheExpirationSeconds,
            repeats: false
        ) { _ in
            if !isUiActive {
                clearAllCaches()
                Logger.perf("CacheManager: Idle timeout - caches expired and freed")
            }
        }
    }
    
    private static func cancelExpirationTimer() {
        expirationTimer?.invalidate()
        expirationTimer = nil
    }
    
    private static func clearLayoutCaches() {
        // Clear ThumbnailsView layout cache
        App.app.thumbnailsPanel.thumbnailsView.clearLayoutCache()
    }
    
    private static func clearScreenCaches() {
        // Clear ThumbnailsPanel screen dimension cache
        ThumbnailsPanel.clearScreenDimensionCache()
    }
    
    private static func clearPreviewCaches() {
        // Clear Windows preview cache
        Windows.clearPreviewCache()
    }
    
    private static func clearImageCaches() {
        // Clear ImageProcessor scaled image cache
        ImageProcessor.clearAllCaches()
    }
}
