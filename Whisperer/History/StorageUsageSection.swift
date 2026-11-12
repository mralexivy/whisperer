//
//  StorageUsageSection.swift
//  Whisperer
//
//  Settings → Storage: what the app keeps on this Mac, drawn like System Settings' storage bar —
//  one segment per kind of data, a legend that lights its segment on hover, and a thin second bar
//  that puts the total against the whole disk. Measurement: `StorageUsage`.
//

import SwiftUI
import Combine

struct StorageUsageSection: View {
    let colorScheme: ColorScheme
    @StateObject private var model: StorageUsageModel
    @State private var hovered: StorageCategory?
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor
    init(colorScheme: ColorScheme, model: StorageUsageModel? = nil) {
        self.colorScheme = colorScheme
        _model = StateObject(wrappedValue: model ?? StorageUsageModel())
    }

    private var primary: Color { WhispererColors.primaryText(colorScheme) }
    private var secondary: Color { WhispererColors.secondaryText(colorScheme) }
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.86) }
    private var breakdown: StorageBreakdown { model.breakdown }

    static func color(_ category: StorageCategory) -> Color {
        switch category {
        case .meetingRecordings: return Color(red: 0.66, green: 0.40, blue: 0.97)     // purple
        case .dictationRecordings: return WhispererColors.accentBlue
        case .transcripts: return Color(red: 0.98, green: 0.62, blue: 0.24)           // orange
        case .models: return Color(red: 0.28, green: 0.80, blue: 0.86)                // cyan
        case .caches: return Color.white.opacity(0.34)
        }
    }

    var body: some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionHeader(icon: "internaldrive.fill", title: "Storage", colorScheme: colorScheme,
                                      color: Color(red: 0.28, green: 0.80, blue: 0.86))

                hero
                appBar
                legend
                diskBlock
            }
        }
        .environment(\.uiTestScope, "storage")
        .onAppear {
            model.refresh()
            withAnimation(spring) { drawn = true }
        }
        .animation(spring, value: breakdown)
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.hasScanned ? Self.size(breakdown.total) : "—")
                        .font(.system(size: 30, weight: .light, design: .rounded))
                        .foregroundColor(primary)
                        .contentTransition(.numericText())
                    Text("used by Whisperer").font(.system(size: 13)).foregroundColor(secondary)
                }
                Text(diskLine).font(.system(size: 12)).foregroundColor(secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.6)))
                    .rotationEffect(.degrees(model.isScanning && !reduceMotion ? 360 : 0))
                    .animation(model.isScanning && !reduceMotion ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                               value: model.isScanning)
            }
            .buttonStyle(.plain).pointerOnHover().disabled(model.isScanning)
            .help("Measure again")
            .uiTestFrame("storage.refresh")
        }
    }

    private var diskLine: String {
        guard model.hasScanned, breakdown.diskTotal > 0 else { return "Measuring…" }
        let percent = breakdown.share * 100
        let share = percent < 0.1 ? "less than 0.1%" : String(format: percent < 10 ? "%.1f%%" : "%.0f%%", percent)
        let name = breakdown.diskName.map { " of \($0)" } ?? ""
        return "\(share)\(name) · \(Self.size(breakdown.diskAvailable)) available"
    }

    // MARK: The app's bar

    private var appBar: some View {
        let slices = breakdown.slices
        return GeometryReader { proxy in
            let values = slices.map(\.bytes)
            let widths = StorageUsage.widths(for: values, width: proxy.size.width, spacing: 3, minimum: 8)
            HStack(spacing: 3) {
                if !model.hasScanned || breakdown.total == 0 {
                    placeholderBar(scanning: model.isScanning || !model.hasScanned)
                } else {
                    ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                        if widths[index] > 0 {
                            segment(slice.category, hovered: hovered == slice.category, dimmed: hovered != nil && hovered != slice.category)
                                .frame(width: drawn ? widths[index] : 0)
                                .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.84).delay(Double(index) * 0.06), value: drawn)
                                .onHover { inside in hovered = inside ? slice.category : (hovered == slice.category ? nil : hovered) }
                                .help("\(slice.category.title) · \(Self.size(slice.bytes))")
                                .uiTestFrame("storage.segment.\(slice.category.rawValue)")
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: 18)
        .clipShape(Capsule())
    }

    private func segment(_ category: StorageCategory, hovered: Bool, dimmed: Bool) -> some View {
        let color = Self.color(category)
        return Rectangle()
            .fill(LinearGradient(colors: [color, color.opacity(0.78)], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(hovered ? 0.3 : 0.14)).frame(height: 1).allowsHitTesting(false) }
            .opacity(dimmed ? 0.3 : 1)
            .scaleEffect(y: hovered ? 1.0 : 0.82)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: dimmed)
    }

    private func placeholderBar(scanning: Bool) -> some View {
        Capsule().fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.7))
            .overlay { if scanning && !reduceMotion { ShimmerOverlay() } }
    }

    // MARK: Legend

    private var legend: some View {
        VStack(spacing: 2) {
            ForEach(StorageCategory.allCases) { category in
                legendRow(category)
            }
        }
    }

    private func legendRow(_ category: StorageCategory) -> some View {
        let slice = breakdown.slice(category)
        let on = hovered == category
        let share = breakdown.total > 0 ? Double(slice.bytes) / Double(breakdown.total) : 0
        return HStack(spacing: 12) {
            Circle().fill(Self.color(category)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title).font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                Text(category.detail).font(.system(size: 11)).foregroundColor(secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text(model.hasScanned ? Self.size(slice.bytes) : "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(primary)
                    .contentTransition(.numericText())
                Text(model.hasScanned && slice.bytes > 0 ? Self.percent(share) : " ")
                    .font(.system(size: 11)).foregroundColor(secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(on ? WhispererColors.elevatedBackground(colorScheme).opacity(0.8) : .clear))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? category : (hovered == category ? nil : hovered) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: on)
        .uiTestFrame("storage.row.\(category.rawValue)")
    }

    // MARK: Against the disk

    private var diskBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ON YOUR DISK").font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundColor(secondary.opacity(0.8))
            GeometryReader { proxy in
                let values: [Int64] = [breakdown.total, breakdown.otherUsed, breakdown.diskAvailable]
                let widths = model.hasScanned && breakdown.diskTotal > 0
                    ? StorageUsage.widths(for: values, width: proxy.size.width, spacing: 2, minimum: 5)
                    : [0, 0, 0]
                HStack(spacing: 2) {
                    Rectangle().fill(LinearGradient(colors: [WhispererColors.accentBlue, Color(red: 0.55, green: 0.42, blue: 0.97)],
                                                    startPoint: .leading, endPoint: .trailing))
                        .frame(width: drawn ? widths[0] : 0)
                    Rectangle().fill(Color.white.opacity(0.24)).frame(width: drawn ? widths[1] : 0)
                    Rectangle().fill(Color.white.opacity(0.07)).frame(width: drawn ? widths[2] : 0)
                    Spacer(minLength: 0)
                }
                .overlay(alignment: .leading) {
                    if !model.hasScanned || breakdown.diskTotal == 0 { placeholderBar(scanning: !model.hasScanned) }
                }
                .animation(spring, value: widths)
                .help("Whisperer \(Self.size(breakdown.total)) · Other \(Self.size(breakdown.otherUsed)) · Available \(Self.size(breakdown.diskAvailable))")
            }
            .frame(height: 10)
            .clipShape(Capsule())

            HStack(spacing: 18) {
                diskKey(WhispererColors.accentBlue, "Whisperer", breakdown.total)
                diskKey(Color.white.opacity(0.34), "Everything else", breakdown.otherUsed)
                diskKey(Color.white.opacity(0.14), "Available", breakdown.diskAvailable)
                Spacer()
            }
        }
        .padding(.top, 4)
    }

    private func diskKey(_ color: Color, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 11)).foregroundColor(secondary)
            Text(model.hasScanned && breakdown.diskTotal > 0 ? Self.size(bytes) : "—")
                .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(primary)
                .contentTransition(.numericText())
        }
    }

    static func percent(_ share: Double) -> String {
        let p = share * 100
        return p < 0.1 ? "<0.1%" : String(format: p < 10 ? "%.1f%%" : "%.0f%%", p)
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// A soft highlight crossing a placeholder while a measurement runs.
private struct ShimmerOverlay: View {
    @State private var phase: CGFloat = -1
    var body: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.clear, Color.white.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: proxy.size.width * 0.4)
                .offset(x: proxy.size.width * phase)
                .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.2 } }
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
    }
}
