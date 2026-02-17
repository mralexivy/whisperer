//
//  DictionaryView.swift
//  Whisperer
//
//  Dictionary management UI
//

import SwiftUI

struct DictionaryView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var dictionaryManager = DictionaryManager.shared
    @State private var searchText = ""
    @State private var selectedEntry: DictionaryEntry?
    @State private var showAddEntry = false
    @State private var highlightedEntryId: UUID? = nil
    @State private var selectedPackId: String? = nil
    @State private var displayLimit = 50
    @State private var showDropdown = false
    @State private var detailPanelWidth: CGFloat = 420
    private let minDetailWidth: CGFloat = 320
    private let maxDetailWidth: CGFloat = 600
    @Namespace private var scrollNamespace

    private let pageSize = 50

    // All filtered entries (before pagination) - computed lazily
    private var allFilteredEntries: [DictionaryEntry] {
        var entries = dictionaryManager.entries

        if let packId = selectedPackId,
           let pack = dictionaryManager.packs.first(where: { $0.id == packId }) {
            entries = entries.filter { $0.category == pack.name }
        }

        if !searchText.isEmpty {
            entries = entries.filter {
                $0.incorrectForm.localizedCaseInsensitiveContains(searchText) ||
                $0.correctForm.localizedCaseInsensitiveContains(searchText)
            }
        }

        return entries
    }

    private var filteredEntries: [DictionaryEntry] {
        Array(allFilteredEntries.prefix(displayLimit))
    }

    private var hasMoreEntries: Bool {
        displayLimit < allFilteredEntries.count
    }

    private var remainingCount: Int {
        max(0, allFilteredEntries.count - displayLimit)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Main content
            HStack(spacing: 0) {
                // Left panel
                VStack(spacing: 0) {
                    headerView

                    Group {
                        DictionaryPacksView(selectedPackId: $selectedPackId, showDropdown: $showDropdown)
                        toolbarView
                        entryList
                    }
                    .opacity(dictionaryManager.isEnabled ? 1.0 : 0.4)
                    .allowsHitTesting(dictionaryManager.isEnabled)
                    .animation(.easeInOut(duration: 0.2), value: dictionaryManager.isEnabled)
                }
                .frame(minWidth: 400, maxWidth: .infinity)

                // Right panel
                if let entry = selectedEntry {
                ResizableDivider(colorScheme: colorScheme) { delta in
                    let newWidth = detailPanelWidth - delta
                    detailPanelWidth = min(max(newWidth, minDetailWidth), maxDetailWidth)
                }
                EntryDetailView(
                    entry: entry,
                    onClose: { selectedEntry = nil },
                    onUpdate: { updated in
                        Task {
                            try? await dictionaryManager.updateEntry(updated)
                        }
                    },
                    onDelete: {
                        Task {
                            try? await dictionaryManager.deleteEntry(entry)
                            selectedEntry = nil
                        }
                    }
                )
                .id(entry.id)
                .frame(width: detailPanelWidth)
                .opacity(dictionaryManager.isEnabled ? 1.0 : 0.4)
                .allowsHitTesting(dictionaryManager.isEnabled)
                .animation(.easeInOut(duration: 0.2), value: dictionaryManager.isEnabled)
            }
            }

            // Dropdown overlay - on top of everything
            if showDropdown {
                PackDropdownOverlay(
                    selectedPackId: $selectedPackId,
                    showDropdown: $showDropdown,
                    packs: dictionaryManager.packs,
                    totalEntries: dictionaryManager.entries.count,
                    colorScheme: colorScheme
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
                .zIndex(100)
                .padding(.top, 130) // Position below header + packs bar
            }
        }
        .background(WhispererColors.background(colorScheme))
        .sheet(isPresented: $showAddEntry) {
            AddDictionaryEntryView()
        }
        .onChange(of: selectedPackId) { _ in
            displayLimit = pageSize
        }
        .onChange(of: dictionaryManager.selectedEntryId) { newValue in
            // When an entry is selected from correction popover, highlight it
            if let entryId = newValue {
                // Clear any active filters/search to ensure entry is visible
                searchText = ""

                // Find the entry
                if let entry = dictionaryManager.entries.first(where: { $0.id == entryId }) {
                    withAnimation(.spring(response: 0.3)) {
                        selectedEntry = entry
                        highlightedEntryId = entryId
                    }

                    // Clear highlight after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation {
                            highlightedEntryId = nil
                        }
                    }

                    // Clear the navigation state
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        dictionaryManager.selectedEntryId = nil
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // Icon — gradient accent fill with shadow
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    WhispererColors.accent.opacity(0.15),
                                    WhispererColors.accentDark.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .shadow(color: WhispererColors.accent.opacity(0.1), radius: 6, y: 2)

                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [WhispererColors.accent, WhispererColors.accentDark],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictionary")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))

                    Text("\(dictionaryManager.entries.count) corrections from \(dictionaryManager.packs.filter { $0.isEnabled }.count) packs")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                }

                Spacer()

                // Global toggle with label
                HStack(spacing: 8) {
                    Text(dictionaryManager.isEnabled ? "Active" : "Disabled")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(dictionaryManager.isEnabled ? WhispererColors.accent : WhispererColors.secondaryText(colorScheme))

                    Toggle("", isOn: $dictionaryManager.isEnabled)
                        .toggleStyle(.switch)
                        .tint(WhispererColors.accent)
                        .labelsHidden()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            // Gradient separator
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
                .frame(height: 1)
        }
        .background(WhispererColors.background(colorScheme))
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        HStack(spacing: 12) {
            // Filter indicator (when pack is selected)
            if let packId = selectedPackId,
               let pack = dictionaryManager.packs.first(where: { $0.id == packId }) {
                HStack(spacing: 6) {
                    Image(systemName: pack.icon)
                        .font(.system(size: 11))
                    Text(pack.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Button(action: { selectedPackId = nil; displayLimit = pageSize }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundColor(WhispererColors.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(WhispererColors.accent.opacity(0.12))
                )
            }

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))

                TextField("Search \(allFilteredEntries.count) entries...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                    .onChange(of: searchText) { _ in
                        displayLimit = pageSize  // Reset pagination on search
                    }

                if !searchText.isEmpty {
                    Button(action: { searchText = ""; displayLimit = pageSize }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(WhispererColors.elevatedBackground(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.06 : 0.03),
                radius: 3, y: 1
            )

            Spacer()

            // Add button
            Button(action: { showAddEntry = true }) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("Add")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(WhispererColors.accent)
                )
                .shadow(
                    color: WhispererColors.accent.opacity(0.25),
                    radius: 4, y: 1
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - List

    private var entryList: some View {
        Group {
            if dictionaryManager.isLoadingEntries {
                // Skeleton loading - shows instantly
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(0..<8, id: \.self) { _ in
                            SkeletonRow(colorScheme: colorScheme)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            } else if filteredEntries.isEmpty && !dictionaryManager.entries.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.5))
                    Text("No matching entries")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    if selectedPackId != nil || !searchText.isEmpty {
                        Button("Clear filters") {
                            selectedPackId = nil
                            searchText = ""
                        }
                        .font(.system(size: 13))
                        .foregroundColor(WhispererColors.accent)
                    }
                    Spacer()
                }
            } else if dictionaryManager.entries.isEmpty && !dictionaryManager.isLoadingEntries {
                emptyStateView
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(filteredEntries) { entry in
                                DictionaryEntryRow(
                                    entry: entry,
                                    isSelected: selectedEntry?.id == entry.id,
                                    isHighlighted: highlightedEntryId == entry.id,
                                    colorScheme: colorScheme,
                                    onSelect: { selectedEntry = entry },
                                    onToggle: {
                                        dictionaryManager.toggleEntry(entry)
                                    }
                                )
                                .id(entry.id)
                            }

                            // Load more button
                            if hasMoreEntries {
                                Button(action: { displayLimit += pageSize }) {
                                    HStack(spacing: 8) {
                                        Text("Load \(min(pageSize, remainingCount)) more")
                                            .font(.system(size: 13, weight: .medium))
                                        Text("(\(remainingCount) remaining)")
                                            .font(.system(size: 12))
                                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                                    }
                                    .foregroundColor(WhispererColors.accent)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(WhispererColors.accent.opacity(0.08))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(WhispererColors.accent.opacity(0.15), lineWidth: 1)
                                    )
                                    .shadow(
                                        color: WhispererColors.accent.opacity(0.08),
                                        radius: 4, y: 1
                                    )
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 6)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: highlightedEntryId) { newValue in
                        if let entryId = newValue {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                scrollProxy.scrollTo(entryId, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                WhispererColors.accent.opacity(0.15),
                                WhispererColors.accentDark.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                    .shadow(color: WhispererColors.accent.opacity(0.1), radius: 8, y: 2)

                Image(systemName: "book.closed")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [WhispererColors.accent, WhispererColors.accentDark],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            VStack(spacing: 6) {
                Text("No Dictionary Entries")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Text("Add technical terms to improve transcription accuracy")
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }

            Button(action: { showAddEntry = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add First Entry")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(WhispererColors.accent)
                )
                .shadow(
                    color: WhispererColors.accent.opacity(0.25),
                    radius: 6, y: 2
                )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

// MARK: - Dictionary Entry Row

struct DictionaryEntryRow: View {
    let entry: DictionaryEntry
    let isSelected: Bool
    let isHighlighted: Bool
    let colorScheme: ColorScheme
    let onSelect: () -> Void
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Incorrect form
                Text(entry.incorrectForm)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.5))

                // Correct form
                Text(entry.correctForm)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                    .lineLimit(1)

                Spacer()

                // Category badge
                if let category = entry.category {
                    Text(category)
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.3)
                        .foregroundColor(WhispererColors.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(WhispererColors.accent.opacity(0.15))
                        )
                }

                // Built-in badge
                if entry.isBuiltIn {
                    Image(systemName: "app.badge")
                        .font(.system(size: 11))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.5))
                }

                // Toggle
                Toggle("", isOn: Binding(
                    get: { entry.isEnabled },
                    set: { _ in onToggle() }
                ))
                    .toggleStyle(.switch)
                    .tint(WhispererColors.accent)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        isHighlighted ? WhispererColors.accent.opacity(0.25) :
                        isSelected ? WhispererColors.accent.opacity(0.15) :
                        isHovered ? WhispererColors.elevatedBackground(colorScheme) :
                        WhispererColors.cardBackground(colorScheme)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isHighlighted ? WhispererColors.accent.opacity(0.6) :
                        isSelected ? WhispererColors.accent.opacity(0.3) :
                        isHovered ? WhispererColors.border(colorScheme).opacity(colorScheme == .dark ? 2.5 : 1.2) :
                        WhispererColors.border(colorScheme),
                        lineWidth: isHighlighted ? 2 : 1
                    )
            )
            .shadow(
                color: isSelected
                    ? WhispererColors.accent.opacity(colorScheme == .dark ? 0.06 : 0.08)
                    : (isHovered
                        ? Color.black.opacity(colorScheme == .dark ? 0.12 : 0.06)
                        : Color.black.opacity(colorScheme == .dark ? 0.06 : 0.03)),
                radius: isSelected ? 8 : (isHovered ? 6 : 3),
                y: isSelected ? 3 : (isHovered ? 2 : 1)
            )
            .scaleEffect(isHovered && !isSelected ? 1.006 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Entry Detail View

struct EntryDetailView: View {
    let entry: DictionaryEntry
    let onClose: () -> Void
    let onUpdate: (DictionaryEntry) -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) var colorScheme
    @State private var incorrectForm: String
    @State private var correctForm: String
    @State private var category: String
    @State private var notes: String
    @State private var isCloseHovered = false
    @State private var isSaveHovered = false
    @State private var isDeleteHovered = false

    init(entry: DictionaryEntry, onClose: @escaping () -> Void, onUpdate: @escaping (DictionaryEntry) -> Void, onDelete: @escaping () -> Void) {
        self.entry = entry
        self.onClose = onClose
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _incorrectForm = State(initialValue: entry.incorrectForm)
        _correctForm = State(initialValue: entry.correctForm)
        _category = State(initialValue: entry.category ?? "")
        _notes = State(initialValue: entry.notes ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Edit Entry")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        .scaleEffect(isCloseHovered ? 1.06 : 1.0)
                        .shadow(
                            color: isCloseHovered ? Color.black.opacity(colorScheme == .dark ? 0.08 : 0.06) : .clear,
                            radius: 3, y: 1
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.15)) {
                        isCloseHovered = hovering
                    }
                }
            }
            .padding(20)
            .background(WhispererColors.cardBackground(colorScheme))
            .overlay(
                // Gradient separator with accent tint on leading edge
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                WhispererColors.accent.opacity(0.2),
                                WhispererColors.border(colorScheme),
                                WhispererColors.border(colorScheme).opacity(0.3)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1),
                alignment: .bottom
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Incorrect form
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Incorrect Form (as heard)")
                            .font(.system(size: 12, weight: .medium))
                            .tracking(0.2)
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        TextField("e.g., post gress", text: $incorrectForm)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(WhispererColors.elevatedBackground(colorScheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                            )
                            .shadow(
                                color: Color.black.opacity(colorScheme == .dark ? 0.04 : 0.025),
                                radius: 3, y: 1
                            )
                            .disabled(entry.isBuiltIn)
                    }

                    // Correct form
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Correct Form")
                            .font(.system(size: 12, weight: .medium))
                            .tracking(0.2)
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        TextField("e.g., PostgreSQL", text: $correctForm)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(WhispererColors.elevatedBackground(colorScheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                            )
                            .shadow(
                                color: Color.black.opacity(colorScheme == .dark ? 0.04 : 0.025),
                                radius: 3, y: 1
                            )
                    }

                    // Category
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Category (optional)")
                            .font(.system(size: 12, weight: .medium))
                            .tracking(0.2)
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        TextField("e.g., Programming", text: $category)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(WhispererColors.elevatedBackground(colorScheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                            )
                            .shadow(
                                color: Color.black.opacity(colorScheme == .dark ? 0.04 : 0.025),
                                radius: 3, y: 1
                            )
                    }

                    // Notes
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notes (optional)")
                            .font(.system(size: 12, weight: .medium))
                            .tracking(0.2)
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        TextEditor(text: $notes)
                            .font(.system(size: 13))
                            .frame(height: 80)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(WhispererColors.elevatedBackground(colorScheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                            )
                            .shadow(
                                color: Color.black.opacity(colorScheme == .dark ? 0.04 : 0.025),
                                radius: 3, y: 1
                            )
                    }

                    // Save button
                    Button(action: saveChanges) {
                        Text("Save Changes")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(WhispererColors.accent)
                            )
                            .shadow(
                                color: WhispererColors.accent.opacity(isSaveHovered ? 0.4 : 0.25),
                                radius: isSaveHovered ? 8 : 4,
                                y: isSaveHovered ? 2 : 1
                            )
                            .scaleEffect(isSaveHovered ? 1.02 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .disabled(incorrectForm.isEmpty || correctForm.isEmpty)
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isSaveHovered = hovering
                        }
                    }

                    // Delete button
                    if !entry.isBuiltIn {
                        Button(action: onDelete) {
                            Text("Delete Entry")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.red)
                                )
                                .shadow(
                                    color: Color.red.opacity(isDeleteHovered ? 0.4 : 0.2),
                                    radius: isDeleteHovered ? 8 : 4,
                                    y: isDeleteHovered ? 2 : 1
                                )
                                .scaleEffect(isDeleteHovered ? 1.02 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.easeOut(duration: 0.15)) {
                                isDeleteHovered = hovering
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(WhispererColors.background(colorScheme))
    }

    private func saveChanges() {
        let updated = DictionaryEntry(
            id: entry.id,
            incorrectForm: incorrectForm,
            correctForm: correctForm,
            category: category.isEmpty ? nil : category,
            isBuiltIn: entry.isBuiltIn,
            isEnabled: entry.isEnabled,
            notes: notes.isEmpty ? nil : notes,
            createdAt: entry.createdAt,
            lastModifiedAt: Date(),
            useCount: entry.useCount
        )
        onUpdate(updated)
        onClose()
    }
}

// MARK: - Skeleton Loading Row

struct SkeletonRow: View {
    let colorScheme: ColorScheme
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 12) {
            // Incorrect form skeleton
            RoundedRectangle(cornerRadius: 4)
                .fill(WhispererColors.elevatedBackground(colorScheme))
                .frame(width: 120, height: 16)

            // Arrow
            Image(systemName: "arrow.right")
                .font(.system(size: 10))
                .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.3))

            // Correct form skeleton
            RoundedRectangle(cornerRadius: 4)
                .fill(WhispererColors.elevatedBackground(colorScheme))
                .frame(width: 100, height: 16)

            Spacer()

            // Category skeleton
            RoundedRectangle(cornerRadius: 4)
                .fill(WhispererColors.elevatedBackground(colorScheme))
                .frame(width: 80, height: 20)

            // Toggle skeleton
            RoundedRectangle(cornerRadius: 10)
                .fill(WhispererColors.elevatedBackground(colorScheme))
                .frame(width: 44, height: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(WhispererColors.cardBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.06 : 0.03),
            radius: 3, y: 1
        )
        .opacity(isAnimating ? 0.5 : 1.0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}
