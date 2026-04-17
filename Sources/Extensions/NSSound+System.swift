import AppKit

extension NSSound {
    /// System "Tink" sound — used when recording starts.
    static let tink = NSSound(named: "Tink")

    /// System "Pop" sound — used when recording stops.
    static let pop = NSSound(named: "Pop")

    /// System "Bottle" sound — soft no-op chime played when a recording
    /// contained no speech, so the user knows the trigger registered.
    static let bottle = NSSound(named: "Bottle")
}
