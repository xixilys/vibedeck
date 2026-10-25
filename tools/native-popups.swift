import Cocoa
import SwiftUI

// Compatibility entry point for the existing capture invocation. It now tests the
// actual transient NSPopover and input path; no NSMenu.popUp/tracking remains.
enum NativePopupCheck {
    static func run(output: String, metadataDirectory: String, language: String,
                    appearance: String, report: ScanReport) -> Bool {
        NSApplication.shared.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        return PanelInputCheck.run(output: metadataDirectory, language: language,
                                   scale: Double(UITheme.fontScale), report: report)
    }
}
