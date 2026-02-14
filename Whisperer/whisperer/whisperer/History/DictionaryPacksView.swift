//
//  DictionaryPacksView.swift
//  Whisperer
//
//  Custom fancy dropdown for dictionary packs
//

import SwiftUI

struct DictionaryPacksView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var dictionaryManager = DictionaryManager.shared
    @Binding var selectedPackId: String?
    @Binding var showDropdown: Bool

    private var selectedPack: DictionaryPack? {
        guard let id = selectedPackId else { return nil }
        return dictionaryManager.packs.first { $0.id == id }
    }

    private var enabledPacks: [DictionaryPack] {
        dictionaryManager.packs.filter { $0.isEnabled }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Custom dropdown trigger
            Button(action: { withAnimation(.easeOut(duration: 0.15)) { showDropdown.toggle() } }) {
                HStack(spacing: 10) {
                    // Icon — gradient fill with micro-shadow
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        WhispererColors.accent.opacity(0.18),
                                        WhispererColors.accentDark.opacity(0.08)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 32, height: 32)
                            .shadow(color: WhispererColors.accent.opacity(0.08), radius: 3, y: 1)

                        Image(systemName: selectedPack?.icon ?? "books.vertical.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(WhispererColors.accent)
                    }

                    // Text
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selectedPack.map { shortName($0.name) } ?? "All Dictionaries")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        Text(selectedPack.map { "\($0.entryCount) entries" } ?? "\(enabledPacks.count) packs")
                            .font(.system(size: 11))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    }

                    Spacer()

                    // Chevron
                    Image(systemName: showDropdown ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(showDropdown ? WhispererColors.accent.opacity(0.08) : WhispererColors.cardBackground(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(showDropdown ? WhispererColors.accent.opacity(0.3) : WhispererColors.border(colorScheme), lineWidth: 1)
                )
                .shadow(
                    color: showDropdown
                        ? WhispererColors.accent.opacity(0.08)
                        : Color.black.opacity(colorScheme == .dark ? 0.06 : 0.03),
                    radius: showDropdown ? 6 : 3,
                    y: 1
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 280)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(WhispererColors.background(colorScheme))
        .overlay(
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            WhispererColors.border(colorScheme).opacity(0.6),
                            WhispererColors.border(colorScheme),
                            WhispererColors.border(colorScheme).opacity(0.6)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func shortName(_ name: String) -> String {
        let replacements: [String: String] = [
            // Technical packs
            "Programming Languages & Frameworks": "Languages",
            "Cloud, DevOps & Infrastructure": "DevOps",
            "Databases, AI/ML & Data Science": "Data & AI",
            "Developer Tools, Version Control & Companies": "Dev Tools",
            "Programming Concepts, Acronyms & General Tech Terms": "Concepts",
            "Operating Systems, Security, Mobile & Emerging Tech": "OS & Security",
            // Workflow packs (matched to actual JSON category names)
            "Agile, Scrum & Sprint Methodology": "Agile",
            "OKRs, Product Management, Strategy & Business Metrics": "Product",
            "Code Review, PRs, Git Workflow & Engineering Process": "Git & PRs",
            "Architecture, System Design & Engineering Discussion": "Architecture",
            "Spoken Developer Phrases, Verbal Shortcuts & Common Dictation Patterns": "Phrases",
            "AdTech, Brand Safety, SaaS, Enterprise & Industry Terms": "Enterprise"
        ]
        return replacements[name] ?? name
    }
}

// MARK: - Premium Dropdown Overlay (Gemini-style)

struct PackDropdownOverlay: View {
    @Binding var selectedPackId: String?
    @Binding var showDropdown: Bool
    let packs: [DictionaryPack]
    let totalEntries: Int
    let colorScheme: ColorScheme
    @ObservedObject var dictionaryManager = DictionaryManager.shared
    @State private var searchText = ""

    private var technicalPacks: [DictionaryPack] {
        packs.filter { !$0.isWorkflowPack }
    }

    private var workflowPacks: [DictionaryPack] {
        packs.filter { $0.isWorkflowPack }
    }

    private var filteredTechnicalPacks: [DictionaryPack] {
        if searchText.isEmpty { return technicalPacks }
        return technicalPacks.filter { shortName($0.name).localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredWorkflowPacks: [DictionaryPack] {
        if searchText.isEmpty { return workflowPacks }
        return workflowPacks.filter { shortName($0.name).localizedCaseInsensitiveContains(searchText) }
    }

    private var enabledCount: Int {
        packs.filter { $0.isEnabled }.count
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.15)) { showDropdown = false }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Backdrop
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // Premium dropdown card
            VStack(alignment: .leading, spacing: 0) {
                // Search field
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.6))

                    TextField("Search packs...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))

                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(WhispererColors.elevatedBackground(colorScheme).opacity(0.5))

                Divider()

                // Scrollable content
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // All Dictionaries option (filter only)
                        PremiumDropdownItem(
                            icon: "books.vertical.fill",
                            title: "All Dictionaries",
                            subtitle: "\(totalEntries)",
                            isSelected: selectedPackId == nil,
                            isEnabled: true,
                            showToggle: false,
                            colorScheme: colorScheme
                        ) {
                            selectedPackId = nil
                            dismiss()
                        } onToggle: { _ in }

                        // Technical section
                        if !filteredTechnicalPacks.isEmpty {
                            sectionHeader("TECHNICAL")

                            ForEach(filteredTechnicalPacks) { pack in
                                PremiumDropdownItem(
                                    icon: iconFor(pack),
                                    title: shortName(pack.name),
                                    subtitle: "\(pack.entryCount)",
                                    isSelected: selectedPackId == pack.id,
                                    isEnabled: pack.isEnabled,
                                    showToggle: true,
                                    colorScheme: colorScheme
                                ) {
                                    selectedPackId = pack.id
                                    dismiss()
                                } onToggle: { _ in
                                    Task { try? await dictionaryManager.togglePack(pack) }
                                }
                            }
                        }

                        // Workflow section
                        if !filteredWorkflowPacks.isEmpty {
                            sectionHeader("WORKFLOW")

                            ForEach(filteredWorkflowPacks) { pack in
                                PremiumDropdownItem(
                                    icon: iconFor(pack),
                                    title: shortName(pack.name),
                                    subtitle: "\(pack.entryCount)",
                                    isSelected: selectedPackId == pack.id,
                                    isEnabled: pack.isEnabled,
                                    showToggle: true,
                                    colorScheme: colorScheme
                                ) {
                                    selectedPackId = pack.id
                                    dismiss()
                                } onToggle: { _ in
                                    Task { try? await dictionaryManager.togglePack(pack) }
                                }
                            }
                        }

                        // No results
                        if filteredTechnicalPacks.isEmpty && filteredWorkflowPacks.isEmpty && !searchText.isEmpty {
                            HStack {
                                Spacer()
                                Text("No packs found")
                                    .font(.system(size: 12))
                                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                                Spacer()
                            }
                            .padding(.vertical, 16)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 340)

                Divider()

                // Bottom bar - enabled count
                HStack {
                    Text("\(enabledCount)/\(packs.count) packs enabled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))

                    Spacer()

                    // Enable all / disable all
                    if enabledCount < packs.count {
                        Button("Enable All") {
                            Task {
                                for pack in packs where !pack.isEnabled {
                                    try? await dictionaryManager.togglePack(pack)
                                }
                            }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(WhispererColors.accent)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(WhispererColors.elevatedBackground(colorScheme).opacity(0.3))
            }
            .frame(width: 280)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(WhispererColors.cardBackground(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(WhispererColors.border(colorScheme).opacity(0.5), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.15), radius: 20, x: 0, y: 8)
            .padding(.leading, 20)
            .padding(.top, 4)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.5))
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func shortName(_ name: String) -> String {
        let replacements: [String: String] = [
            "Programming Languages & Frameworks": "Languages",
            "Cloud, DevOps & Infrastructure": "DevOps",
            "Databases, AI/ML & Data Science": "Data & AI",
            "Developer Tools, Version Control & Companies": "Dev Tools",
            "Programming Concepts, Acronyms & General Tech Terms": "Concepts",
            "Operating Systems, Security, Mobile & Emerging Tech": "OS & Security",
            "Agile, Scrum & Sprint Methodology": "Agile",
            "OKRs, Product Management, Strategy & Business Metrics": "Product",
            "Code Review, PRs, Git Workflow & Engineering Process": "Git & PRs",
            "Architecture, System Design & Engineering Discussion": "Architecture",
            "Spoken Developer Phrases, Verbal Shortcuts & Common Dictation Patterns": "Phrases",
            "AdTech, Brand Safety, SaaS, Enterprise & Industry Terms": "Enterprise"
        ]
        return replacements[name] ?? name
    }

    private func iconFor(_ pack: DictionaryPack) -> String {
        let icons: [String: String] = [
            "Languages": "chevron.left.forwardslash.chevron.right",
            "DevOps": "cloud",
            "Data & AI": "brain.head.profile",
            "Dev Tools": "hammer",
            "Concepts": "lightbulb",
            "OS & Security": "lock.shield",
            "Agile": "arrow.triangle.2.circlepath",
            "Product": "chart.bar.xaxis",
            "Git & PRs": "arrow.triangle.branch",
            "Architecture": "building.2",
            "Phrases": "text.bubble",
            "Enterprise": "briefcase"
        ]
        return icons[shortName(pack.name)] ?? pack.icon
    }
}

// MARK: - Premium Dropdown Item

struct PremiumDropdownItem: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let isEnabled: Bool
    let showToggle: Bool
    let colorScheme: ColorScheme
    let onSelect: () -> Void
    let onToggle: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Tappable area for selection (everything except toggle)
            HStack(spacing: 10) {
                // Selection checkmark
                ZStack {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(WhispererColors.accent)
                    }
                }
                .frame(width: 16)

                // Icon
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isEnabled ? WhispererColors.accent : WhispererColors.secondaryText(colorScheme).opacity(0.5))
                    .frame(width: 18)

                // Title
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isEnabled ? WhispererColors.primaryText(colorScheme) : WhispererColors.secondaryText(colorScheme))
                    .lineLimit(1)

                Spacer()

                // Entry count
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(WhispererColors.elevatedBackground(colorScheme))
                    )
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }

            // Toggle switch - separate from row tap
            if showToggle {
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.65)
                .labelsHidden()
                .tint(WhispererColors.accent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? WhispererColors.accent.opacity(0.1) : (isHovered ? WhispererColors.elevatedBackground(colorScheme) : Color.clear))
        )
        .scaleEffect(isHovered ? 1.006 : 1.0)
        .padding(.horizontal, 4)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Dropdown Item

struct DropdownItem: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? WhispererColors.accent : WhispererColors.secondaryText(colorScheme))
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? WhispererColors.accent : WhispererColors.primaryText(colorScheme))
                    .lineLimit(1)

                Spacer()

                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.6))

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(WhispererColors.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? WhispererColors.accent.opacity(0.1) : (isHovered ? WhispererColors.elevatedBackground(colorScheme) : Color.clear))
            )
            .scaleEffect(isHovered ? 1.006 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Pack Manager Sheet

struct PackManagerSheet: View {
    let colorScheme: ColorScheme
    @ObservedObject var dictionaryManager = DictionaryManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Packs")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(dictionaryManager.packs) { pack in
                        PackManagerRow(pack: pack, colorScheme: colorScheme)
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Text("\(dictionaryManager.packs.filter { $0.isEnabled }.count)/\(dictionaryManager.packs.count) enabled")
                    .font(.system(size: 12))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(WhispererColors.accent)
            }
            .padding(16)
        }
        .frame(width: 420, height: 480)
        .background(WhispererColors.background(colorScheme))
    }
}

struct PackManagerRow: View {
    let pack: DictionaryPack
    let colorScheme: ColorScheme
    @ObservedObject var dictionaryManager = DictionaryManager.shared
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pack.icon)
                .font(.system(size: 14))
                .foregroundColor(pack.isEnabled ? WhispererColors.accent : WhispererColors.secondaryText(colorScheme))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(pack.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(pack.isEnabled ? WhispererColors.primaryText(colorScheme) : WhispererColors.secondaryText(colorScheme))
                    .lineLimit(1)
                Text("\(pack.entryCount) entries")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { pack.isEnabled },
                set: { _ in Task { try? await dictionaryManager.togglePack(pack) } }
            ))
            .toggleStyle(.switch)
            .tint(WhispererColors.accent)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? WhispererColors.elevatedBackground(colorScheme) : Color.clear))
        .scaleEffect(isHovered ? 1.006 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
