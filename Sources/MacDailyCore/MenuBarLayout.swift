import Foundation

public enum MenuBarLayoutGeometry {
    /// macOS 27's separate pusher stays below half of the narrowest display width.
    /// Mechanism reference: CleanMenuBar, commit e9652547fa5ff70e7e93ab76ac2966bedcafe02d (MIT).
    public static func collapsedLength(screenWidths: [Double]) -> Double? {
        guard let narrowest = screenWidths.min(), narrowest > 40 else { return nil }
        return narrowest / 2 - 20
    }
}
