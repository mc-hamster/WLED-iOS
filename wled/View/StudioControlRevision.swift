import SwiftUI

private struct StudioControlRevisionKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var studioControlRevision: Int {
        get { self[StudioControlRevisionKey.self] }
        set { self[StudioControlRevisionKey.self] = newValue }
    }
}
