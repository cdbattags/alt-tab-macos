import Cocoa

class AnimationsSheet: SheetWindow {
    override func makeContentView() -> NSView {
        let table = TableGroupView(title: NSLocalizedString("Animations", comment: ""), width: SheetWindow.width)
        let slider = LabelAndControl.makeLabelWithSlider("", "windowDisplayDelay", 0, 900, 19, true, "ms", width: 180)
        let rule = slider[1]
        let indicator = slider[2] as! NSTextField
        indicator.alignment = .right
        indicator.fit(56, indicator.fittingSize.height)
        table.addRow(leftText: NSLocalizedString("Apparition delay of Switcher", comment: ""),
            rightViews: [rule, indicator])
        table.addRow(leftText: NSLocalizedString("Fade out animation of Switcher", comment: ""),
            rightViews: LabelAndControl.makeSwitch("fadeOutAnimation"))
        table.addRow(leftText: NSLocalizedString("Fade in animation of Preview", comment: ""),
            rightViews: LabelAndControl.makeSwitch("previewFadeInAnimation"))
        table.addNewTable()
        
        // Cache expiration setting - see https://github.com/lwouis/alt-tab-macos/issues/5177
        let cacheSlider = LabelAndControl.makeLabelWithSlider("", "cacheExpirationSeconds", 30, 300, 10, false, "s", width: 180)
        let cacheRule = cacheSlider[1]
        let cacheIndicator = cacheSlider[2] as! NSTextField
        cacheIndicator.alignment = .right
        cacheIndicator.fit(56, cacheIndicator.fittingSize.height)
        table.addRow(leftText: NSLocalizedString("Cache expiration delay", comment: ""),
            rightViews: [cacheRule, cacheIndicator])
        
        table.fit()
        return table
    }
}
