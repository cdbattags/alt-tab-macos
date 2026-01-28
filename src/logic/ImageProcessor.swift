import Cocoa

/// High-performance image processing for thumbnails
/// Handles async decoding (GPU handles scaling during display for zero layout shift)
class ImageProcessor {
    /// Cache of decoded images: [windowId: decodedImage]
    /// Note: We cache decoded (decompressed) images, not scaled images
    /// The GPU handles scaling efficiently during display, avoiding layout shift issues
    private static var decodeCache = [CGWindowID: CGImage]()
    
    /// Async decode CGImage on background thread (GPU handles scaling during display)
    /// - Parameters:
    ///   - image: Source image to decode
    ///   - windowId: Window ID for caching
    ///   - completion: Called on main thread with decoded image
    static func processImage(
        _ image: CGImage,
        windowId: CGWindowID,
        completion: @escaping (CGImage) -> Void
    ) {
        BackgroundWork.screenshotsQueue.addOperation {
            Logger.perf("ImageProcessor: Starting decode for window \(windowId)")
            let start = DispatchTime.now()
            
            // Check cache first (cache by windowId only, not size)
            if let cachedImage = getCachedImage(windowId: windowId) {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                Logger.cacheHit("Decoded image", details: "window \(windowId), \(String(format: "%.2f", elapsed))ms")
                DispatchQueue.main.async {
                    completion(cachedImage)
                }
                return
            }
            
            // Decode image by drawing to context (forces decompression on background thread)
            let decodedImage: CGImage
            if let decoded = decodeImage(image) {
                decodedImage = decoded
                cacheImage(decodedImage, windowId: windowId)
            } else {
                // Fallback to original if decode fails
                decodedImage = image
            }
            
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Logger.perf("ImageProcessor: Decoded in \(String(format: "%.2f", elapsed))ms for window \(windowId)")
            
            DispatchQueue.main.async {
                completion(decodedImage)
            }
        }
    }
    
    /// Force decode image by drawing to context (decompresses on current thread)
    private static func decodeImage(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        
        guard width > 0, height > 0 else { return nil }
        
        // Create bitmap context matching image format
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = image.bitmapInfo.rawValue
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        
        // Drawing forces decompression
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: rect)
        
        return context.makeImage()
    }
    
    // MARK: - Cache Management
    
    private static func getCachedImage(windowId: CGWindowID) -> CGImage? {
        return decodeCache[windowId]
    }
    
    private static func cacheImage(_ image: CGImage, windowId: CGWindowID) {
        decodeCache[windowId] = image
        Logger.cacheMiss("Decoded image", reason: "window \(windowId) - cached")
    }
    
    /// Clear cache for specific window (called when window closes or updates)
    static func clearCache(for windowId: CGWindowID) {
        decodeCache.removeValue(forKey: windowId)
        Logger.perf("ImageProcessor: Cache cleared for window \(windowId)")
    }
    
    /// Clear all cached images
    static func clearAllCaches() {
        let count = decodeCache.count
        decodeCache.removeAll()
        Logger.perf("ImageProcessor: All caches cleared (\(count) windows)")
    }
    
    /// Get cache statistics for debugging
    static func getCacheStats() -> (windows: Int, totalImages: Int) {
        return (decodeCache.count, decodeCache.count)
    }
}
