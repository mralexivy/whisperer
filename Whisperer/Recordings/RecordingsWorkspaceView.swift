//
//  RecordingsWorkspaceView.swift
//  Whisperer
//
//  The Recordings destination: list, reader and context sidebar over one playback session. It owns the
//  playback controller, so the player survives tab changes, a hidden sidebar and focus mode, and shows
//  as exactly one of its two faces: full above the sidebar tabs, compact under the reader.
//

import SwiftUI

/// A recording to show without the stores — for tests that render the workspace around fixtures.
struct RecordingsWorkspaceFixture {
    let document: TranscriptDocument
    let record: MeetingRecord
}

struct RecordingsWorkspaceView: View {
    @ObservedObject private var model = RecordingsWorkspaceModel.shared
    @ObservedObject private var appState = AppState.shared
    @StateObject private var detail = RecordingDetailModel()
    @StateObject private var playback: RecordingPlaybackController
    private let fixture: RecordingsWorkspaceFixture?
    private let testScope: String
    private let testSession: MeetingSession?

    init(fixture: RecordingsWorkspaceFixture? = nil, playback: RecordingPlaybackController? = nil, testScope: String = "", session: MeetingSession? = nil) {
        self.testSession = session
        self.fixture = fixture
        self.testScope = testScope
        _playback = StateObject(wrappedValue: playback ?? RecordingPlaybackController())
    }
    @StateObject private var localSession = MeetingSession()
    #if canImport(FluidAudio)
    @ObservedObject private var engines = MeetingEngines.shared
    @State private var continueAnyway = false
    #endif

    @State private var detailTab: RecordingDetailTab = .transcript
    @State private var sidebarTab: RecordingSidebarTab = .askAI
    @AppStorage("recordings.sidebarVisible") private var sidebarVisible = true
    @AppStorage("recordings.sidebarWidth") private var sidebarWidth = 340.0

    private static let listWidth = RecordingsWorkspaceLayout.listWidth
    private static let sidebarRange: ClosedRange<Double> = Double(RecordingsWorkspaceLayout.minSidebar)...Double(RecordingsWorkspaceLayout.maxSidebar)

    private var session: MeetingSession { testSession ?? appState.activeMeetingSession ?? localSession }

    var body: some View {
        GeometryReader { geo in
            let layout = RecordingsWorkspaceLayout(total: geo.size.width, sidebarWidth: CGFloat(sidebarWidth),
                                wantsSidebar: sidebarVisible, focus: model.focusMode,
                                hasDocument: detail.document != nil && !model.isImporting)
            HStack(spacing: 0) {
                if layout.showsList {
                    RecordingsListView(model: model, session: session)
                        .frame(width: Self.listWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    divider
                }
                centre(layout)
                if layout.showsSidebar, let document = detail.document, let record = detail.meetingRecord {
                    ResizeHandle(width: $sidebarWidth, range: Self.sidebarRange)
                    RecordingSidebarView(
                        document: document, meetingRecord: record, playback: playback, session: session, detail: detail,
                        tab: $sidebarTab, onCitation: { openCitation($0) }, onCollapse: { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { sidebarVisible = false } },
                        isLive: document.kind == .meeting && session.isRecording && session.meetingID == document.id.uuid)
                        .frame(width: layout.sidebarWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: layout.showsList)
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: layout.showsSidebar)
        }
        .background(Color(hex: "0C0C1A"))
        .environment(\.colorScheme, .dark)
        .environment(\.uiTestScope, testScope)
        .onAppear {
            if let fixture {
                detail.showForTesting(document: fixture.document, record: fixture.record)
                return
            }
            model.selectFirstIfNeeded()
            detail.select(model.selectedID)
        }
        .onChange(of: model.selectedID) { _, id in if fixture == nil { detail.select(id) } }
        .onChange(of: model.items.count) { _, _ in if fixture == nil { model.selectFirstIfNeeded() } }
        .onChange(of: detail.document) { _, document in
            playback.select(document)
            if let document, !RecordingSidebarPolicy.tabs(for: document.kind).contains(sidebarTab) {
                sidebarTab = RecordingSidebarPolicy.defaultTab(for: document.kind)
            }
        }
        .onChange(of: detail.document?.id) { _, _ in
            if let kind = detail.document?.kind { sidebarTab = RecordingSidebarPolicy.defaultTab(for: kind) }
        }
        .onChange(of: session.meetingID) { _, id in
            // A recording that starts selects its own row once, as the Meeting Notes page did.
            if session.isRecording, let id { model.open(.meeting(id)) }
        }
    }

    // MARK: Layout

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }

    @ViewBuilder private func centre(_ layout: RecordingsWorkspaceLayout) -> some View {
        #if canImport(FluidAudio)
        // Meetings need their speech models once; until then the Meetings filter offers to prepare them.
        // Dictation and files are never held back by it.
        if engines.needsPreparation && !continueAnyway && model.kindFilter == .meetings && model.items.isEmpty && !model.isImporting {
            MeetingPrepView(continueAnyway: $continueAnyway)
        } else {
            centreContent(layout)
        }
        #else
        centreContent(layout)
        #endif
    }

    @ViewBuilder private func centreContent(_ layout: RecordingsWorkspaceLayout) -> some View {
        if model.isImporting {
            RecordingImportView(model: model)
        } else {
            RecordingDetailView(
                detail: detail, playback: playback, workspace: model, session: session,
                tab: $detailTab, sidebarVisible: $sidebarVisible,
                showsCompactPlayer: !layout.showsSidebar,
                onOpenDetails: { sidebarVisible = true; sidebarTab = .details })
        }
    }

    // MARK: Citations

    /// A cited passage: open the transcript, reveal and highlight the paragraph, and seek when it has a time.
    private func openCitation(_ chunk: RAGChunk) {
        guard let document = detail.document,
              let paragraph = document.paragraph(forCitationKey: chunk.startTimestamp) else { return }
        detail.showOriginal = false
        detailTab = .transcript
        DispatchQueue.main.async { playback.open(citation: paragraph) }
    }
}

/// A thin draggable edge that resizes the column to its right.
private struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
            .padding(.horizontal, 2)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let base = startWidth ?? width
                    startWidth = base
                    width = min(max(base - Double(value.translation.width), range.lowerBound), range.upperBound)
                }
                .onEnded { _ in startWidth = nil })
            .accessibilityHidden(true)
    }
}

/// Which columns fit, adapting to the window instead of ignoring the user's choice. A wanted sidebar
/// always appears: it first narrows (down to `minSidebar`), then the recordings list yields, and only a
/// window too small for even the reader plus a minimum sidebar hides it. Focus mode hides the list only;
/// the sidebar follows its own toggle, so its button never does nothing. The compact player takes over
/// exactly when the sidebar (with its full player) is not shown.
struct RecordingsWorkspaceLayout: Equatable {
    static let listWidth: CGFloat = 308
    static let minReader: CGFloat = 420
    static let minSidebar: CGFloat = 280
    static let maxSidebar: CGFloat = 480

    let showsList: Bool
    let showsSidebar: Bool
    /// The width the sidebar is drawn at: the user's choice, narrowed to what fits.
    let sidebarWidth: CGFloat

    init(total: CGFloat, sidebarWidth preferred: CGFloat, wantsSidebar: Bool, focus: Bool, hasDocument: Bool) {
        let preferred = min(max(preferred, Self.minSidebar), Self.maxSidebar)
        guard wantsSidebar, hasDocument else {
            showsList = !focus; showsSidebar = false; sidebarWidth = preferred
            return
        }
        let chrome: CGFloat = 6   // resize handle
        let withList = total - (focus ? 0 : Self.listWidth + 1) - Self.minReader - chrome
        if withList >= Self.minSidebar {
            showsList = !focus; showsSidebar = true; sidebarWidth = min(preferred, withList)
            return
        }
        // Not enough room beside the list: the list yields to the panel the user asked for.
        let withoutList = total - Self.minReader - chrome
        showsList = false
        showsSidebar = withoutList >= Self.minSidebar
        sidebarWidth = min(preferred, max(withoutList, Self.minSidebar))
    }
}
