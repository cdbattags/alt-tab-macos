import Cocoa

class Spaces {
    static var currentSpaceId = CGSSpaceID(1)
    static var currentSpaceIndex = SpaceIndex(1)
    static var visibleSpaces = [CGSSpaceID]()
    static var screenSpacesMap = [ScreenUuid: [CGSSpaceID]]()
    static var idsAndIndexes = [(CGSSpaceID, SpaceIndex)]()
    
    // Performance optimization: cache expensive WindowServer API calls
    // See https://github.com/lwouis/alt-tab-macos/issues/5177
    private static var windowsInSpacesCache = [String: [CGWindowID]]()
    private static var lastRefreshTime: DispatchTime = .now() - .seconds(1)
    private static let refreshThrottle: TimeInterval = 0.2

    static func isSingleSpace() -> Bool {
        return idsAndIndexes.count == 1
    }

    static func windowsInSpaces(_ spaceIds: [CGSSpaceID], _ includeInvisible: Bool = true) -> [CGWindowID] {
        let cacheKey = "\(spaceIds)_\(includeInvisible)"
        if let cached = windowsInSpacesCache[cacheKey] {
            Logger.cacheHit("windowsInSpaces", details: "\(spaceIds.count) spaces")
            return cached
        }
        
        return Logger.measure("windowsInSpaces: CGSCopyWindowsWithOptionsAndTags") {
            var set_tags = ([] as CGSCopyWindowsTags).rawValue
            var clear_tags = ([] as CGSCopyWindowsTags).rawValue
            var options = [.screenSaverLevel1000] as CGSCopyWindowsOptions
            if includeInvisible {
                options = [options, .invisible1, .invisible2]
            }
            let result = CGSCopyWindowsWithOptionsAndTags(CGS_CONNECTION, 0, spaceIds as CFArray, options.rawValue, &set_tags, &clear_tags) as! [CGWindowID]
            
            windowsInSpacesCache[cacheKey] = result
            Logger.perf("windowsInSpaces: returned \(result.count) windows")
            return result
        }
    }

    static func refresh() {
        let now = DispatchTime.now()
        let timeSinceLastRefresh = Double(now.uptimeNanoseconds - lastRefreshTime.uptimeNanoseconds) / 1_000_000_000
        
        if timeSinceLastRefresh < refreshThrottle && !idsAndIndexes.isEmpty {
            Logger.perf("Spaces.refresh: THROTTLED (last refresh \(String(format: "%.2f", timeSinceLastRefresh * 1000))ms ago)")
            return
        }
        
        Logger.measure("Spaces.refresh (last refresh \(String(format: "%.2f", timeSinceLastRefresh * 1000))ms ago)") {
            lastRefreshTime = now
            windowsInSpacesCache.removeAll()
            refreshAllIdsAndIndexes()
            updateCurrentSpace()
        }
    }

    private static func updateCurrentSpace() {
        // it seems that in some rare scenarios, some of these values are nil; we wrap to avoid crashing
        if let mainScreen = NSScreen.main,
           let uuid = mainScreen.uuid() {
            currentSpaceId = CGSManagedDisplayGetCurrentSpace(CGS_CONNECTION, uuid)
        }
        currentSpaceIndex = idsAndIndexes.first { (spaceId: CGSSpaceID, _) -> Bool in
            spaceId == currentSpaceId
        }?.1 ?? SpaceIndex(1)
    }

    private static func refreshAllIdsAndIndexes() -> Void {
        idsAndIndexes.removeAll()
        screenSpacesMap.removeAll()
        visibleSpaces.removeAll()
        
        var spaceIndex = SpaceIndex(1)
        (CGSCopyManagedDisplaySpaces(CGS_CONNECTION) as! [NSDictionary]).forEach { (screen: NSDictionary) in
            var display = screen["Display Identifier"] as! ScreenUuid
            if display as String == "Main", let mainUuid = NSScreen.main?.uuid() {
                display = mainUuid
            }
            (screen["Spaces"] as! [NSDictionary]).forEach { (space: NSDictionary) in
                let spaceId = space["id64"] as! CGSSpaceID
                idsAndIndexes.append((spaceId, spaceIndex))
                screenSpacesMap[display, default: []].append(spaceId)
                spaceIndex += 1
            }
            visibleSpaces.append((screen["Current Space"] as! NSDictionary)["id64"] as! CGSSpaceID)
        }
        Logger.perf("refreshAllIdsAndIndexes: found \(idsAndIndexes.count) spaces")
    }
}

typealias SpaceIndex = Int
