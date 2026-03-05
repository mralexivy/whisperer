//
//  View+DrawingGroupWorkaround.swift
//  Whisperer
//
//  macOS 26 (Tahoe) text rendering workaround
//

import SwiftUI

extension View {
    /// macOS 26 text rendering workaround — groups layers before compositing to prevent
    /// flipped/mirrored glyph compositing in popovers and NSPanel-hosted views.
    /// https://github.com/p0deje/Maccy/issues/1113
    /// Remove when Apple fixes the underlying compositing bug.
    func tahoeTextFix() -> some View {
        self.compositingGroup()
    }
}
