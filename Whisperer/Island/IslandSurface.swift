//
//  IslandSurface.swift
//  Whisperer
//
//  Animatable morphing silhouette for the Whisperer Island.
//
//  The surface is a continuous rounded-rectangle path that interpolates between compact and
//  expanded geometry. A single `progress` value (0 = compact, 1 = expanded) drives the
//  corner radii and frame through SwiftUI's animation system; because SwiftUI interpolates
//  `animatableData`, the shape genuinely morphs rather than crossfading.
//
//  Design note: the Island surface is always opaque black (#000000) — this is an explicit
//  exception to the app's dark-navy design system so the Island merges with the hardware
//  notch on MacBook Pro displays. The DESIGN.md §IslandSurface section documents this.
//

import SwiftUI

// MARK: - Animatable morphing shape

/// A rounded rectangle that interpolates geometry using a [0, 1] progress value.
/// progress = 0 → compact, progress = 1 → expanded.
struct IslandSilhouette: Shape {

    var compactSize:    CGSize
    var expandedSize:   CGSize
    var compactRadii:   IslandGeometryProvider.CornerRadii
    var expandedRadii:  IslandGeometryProvider.CornerRadii
    var progress:       Double   // animatable

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = progress
        let q = 1 - p

        // Interpolate size — anchor the top edge, grow downward
        let w = compactSize.width  * q + expandedSize.width  * p
        let h = compactSize.height * q + expandedSize.height * p

        // Center horizontally within the provided rect; pin to the top
        let x = (rect.width  - w) / 2
        let y = rect.minY   // top-anchored

        let tl = compactRadii.topLeading     * q + expandedRadii.topLeading     * p
        let tr = compactRadii.topTrailing    * q + expandedRadii.topTrailing    * p
        let bl = compactRadii.bottomLeading  * q + expandedRadii.bottomLeading  * p
        let br = compactRadii.bottomTrailing * q + expandedRadii.bottomTrailing * p

        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: x, y: y, width: w, height: h),
            cornerRadii: RectangleCornerRadii(
                topLeading: tl, bottomLeading: bl,
                bottomTrailing: br, topTrailing: tr
            )
        )
        return path
    }
}

// MARK: - Shadow modifier (floating / notchless only)

/// Adds a drop shadow beneath a floating Island (no hardware notch to merge into).
/// On notched displays the shadow is suppressed — the surface flush-mounts the housing.
struct IslandShadowModifier: ViewModifier {
    var drawShadow: Bool

    func body(content: Content) -> some View {
        if drawShadow {
            content
                .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
        } else {
            content
        }
    }
}

extension View {
    func islandShadow(draw: Bool) -> some View {
        modifier(IslandShadowModifier(drawShadow: draw))
    }
}
