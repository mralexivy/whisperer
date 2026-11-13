//
//  CloudPanelView.swift
//  Whisperer
//
//  The Whisperer Cloud panel inside Settings → Move History → "Whisperer Cloud" (HistoryArchiveSection).
//  One screen per account state (CloudPanelModel.Screen), each plain, short and calm: current state first,
//  one primary action, steps that unfold in place, plumbing under "Advanced" (DESIGN.md: Connect Flow).
//  This file holds the shell and the sign-up, recovery-key, new-Mac and problem screens; the signed-in
//  screens are in CloudPanelReadyView.swift.
//
//  Test ids: `cloud.*`. Nothing here logs, and the recovery key never appears in an identifier or a title.
//

import SwiftUI

struct CloudPanelView: View {
    let colorScheme: ColorScheme
    @StateObject var model: CloudPanelModel
    @FocusState var keyFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @MainActor
    init(colorScheme: ColorScheme, model: CloudPanelModel? = nil, onExportHistory: (() -> Void)? = nil) {
        self.colorScheme = colorScheme
        _model = StateObject(wrappedValue: {
            let built = model ?? CloudPanelModel.live()
            if let onExportHistory { built.onExportHistory = onExportHistory }
            return built
        }())
    }

    var primary: Color { WhispererColors.primaryText(colorScheme) }
    var secondary: Color { WhispererColors.secondaryText(colorScheme) }
    var tertiary: Color { WhispererColors.tertiaryText(colorScheme) }
    var spring: Animation? { reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            screen
                .transition(.move(edge: .top).combined(with: .opacity))
            if let message = visibleError {
                CloudNotice(text: message, tone: .warning)
                    .uiTestFrame("cloud.error")
            }
        }
        .padding(.leading, 50)
        .animation(spring, value: model.screen)
        .animation(spring, value: model.showsPlans)
        .task { await model.start() }
    }

    private var visibleError: String? {
        if case .progress = model.screen { return nil }
        return model.lastError
    }

    @ViewBuilder
    private var screen: some View {
        switch model.screen {
        case .intro: introScreen
        case .awaitingApproval: awaitingApprovalScreen
        case .progress(let step): progressScreen(step)
        case .offerRecoveryKey: offerKeyScreen
        case .showRecoveryKey(let key): showKeyScreen(key)
        case .ready: readyScreen
        case .readOnly(let reason): readOnlyScreen(reason)
        case .newMac(let needs): newMacScreen(needs)
        case .deviceRevoked: revokedScreen
        case .unavailable(let problem): unavailableScreen(problem)
        }
    }

    // MARK: Shared pieces

    func titleBlock(icon: String, tint: Color, title: String, text: String, pill: (String, CloudTone)? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CloudIconTile(icon: icon, color: tint, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(primary)
                    if let pill { CloudPill(text: pill.0, tone: pill.1) }
                }
                Text(text).font(.system(size: 12)).foregroundColor(secondary)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    func factRow(icon: String, tint: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CloudIconTile(icon: icon, color: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                Text(text).font(.system(size: 12)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    func secondaryButton(_ title: String, icon: String? = nil, id: String, enabled: Bool = true, tint: Color? = nil,
                         action: @escaping () -> Void) -> CloudSecondaryButton {
        CloudSecondaryButton(colorScheme: colorScheme, title: title, icon: icon, id: id, enabled: enabled, tint: tint, action: action)
    }

    // MARK: First Mac: offer

    private var introScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                factRow(icon: "lock.shield.fill", tint: .purple, title: "End-to-end encrypted",
                        text: "Your history is locked on this Mac before it is sent anywhere.")
                factRow(icon: "eye.slash.fill", tint: .cyan, title: "We cannot read it",
                        text: "The key stays with you, in your iCloud Keychain. Not even we can open your history.")
                factRow(icon: "macbook.and.iphone", tint: .orange, title: "A new Mac in minutes",
                        text: "Sign in with the same Apple ID and your history is there.")
            }
            plansContainer
            HStack(spacing: 12) {
                secondaryButton("Restore Purchases", icon: "arrow.clockwise", id: "cloud.restore", enabled: !model.isBusy) { model.restorePurchases() }
                Text("Already subscribed on another Mac? Restore Purchases.")
                    .font(.system(size: 12)).foregroundColor(secondary)
            }
        }
    }

    /// Apple's plan picker, in place; a fixed height so the card never jumps while the plans load.
    var plansContainer: some View {
        model.environment.plansView { await model.planPurchased() }
            .frame(maxWidth: .infinity)
            .frame(height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color.black.opacity(0.05), radius: 4, y: 1)
            .uiTestFrame("cloud.plans")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Whisperer Cloud plans")
    }

    private var awaitingApprovalScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleBlock(icon: "hourglass", tint: .orange, title: "Waiting for approval",
                       text: "Your purchase needs approval from the person who manages your family sharing (Ask to Buy). Nothing more to do here: it finishes by itself once it is approved.",
                       pill: ("Waiting", .warning))
            HStack(spacing: 12) {
                secondaryButton("Check again", icon: "arrow.clockwise", id: "cloud.pending.check", enabled: !model.isBusy) { model.tryAgain() }
                Text("You can keep using Whisperer while you wait.").font(.system(size: 12)).foregroundColor(secondary)
            }
        }
    }

    // MARK: Progress

    private func progressScreen(_ step: CloudPanelModel.Step) -> some View {
        let steps: [(CloudPanelModel.Step, String, String)] = [
            (.purchasing, "Subscribing", "Confirm with Touch ID or your Apple ID if the App Store asks."),
            (.creatingAccount, "Creating your account", "This takes a few seconds."),
            (.creatingLibrary, "Creating your encrypted library", "Making the key that locks your history."),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            switch step {
            case .confirming:
                CloudBlock(colorScheme: colorScheme) { progressRow(.current, "Checking this Mac’s key", "Making sure this Mac can open your library.") }
            case .resetting:
                CloudBlock(colorScheme: colorScheme) { progressRow(.current, "Starting your library over", "Deleting the old cloud copy and making a new key.") }
            default:
                let index = steps.firstIndex { $0.0 == step } ?? 0
                CloudBlock(colorScheme: colorScheme) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, item in
                            progressRow(i < index ? .done : (i == index ? .current : .later), item.1, i == index ? item.2 : nil)
                        }
                    }
                }
            }
        }
        .uiTestFrame("cloud.progress")
    }

    private enum ProgressMark { case done, current, later }

    private func progressRow(_ mark: ProgressMark, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch mark {
                case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundColor(WhispererColors.accentBlue)
                case .current: CloudWorkingDot()
                case .later: Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1.5).frame(width: 14, height: 14)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: mark == .current ? .semibold : .medium))
                    .foregroundColor(mark == .later ? tertiary : primary)
                if let detail { Text(detail).font(.system(size: 12)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(mark == .done ? "Done" : (mark == .current ? "In progress" : "Waiting"))
    }

    // MARK: Recovery key

    private var offerKeyScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleBlock(icon: "key.fill", tint: .orange, title: "Make a recovery key",
                       text: "Your history is locked with a key kept in your iCloud Keychain. A recovery key is a second way in. If you ever lose access to your iCloud Keychain, it is the only way to read your cloud history on a new Mac. Whisperer cannot recover your data without it or your iCloud Keychain.")
            HStack(spacing: 14) {
                CloudPrimaryButton(title: "Create recovery key", icon: "key.fill", id: "cloud.key.create", enabled: !model.isBusy) { model.createRecoveryKey() }
                CloudLinkButton(title: "Skip for now", id: "cloud.key.skip", enabled: !model.isBusy) { model.skipRecoveryKey() }
            }
            Text("If you skip and later lose your iCloud Keychain, your cloud history cannot be recovered. You can make a key any time from this panel.")
                .font(.system(size: 12)).foregroundColor(tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func showKeyScreen(_ key: String) -> some View {
        let groups = key.split(separator: "-").map(String.init)
        let rows = [Array(groups.prefix(7)), Array(groups.dropFirst(7))].filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 16) {
            titleBlock(icon: "key.fill", tint: .orange, title: "Your recovery key",
                       text: "Save it now. It is shown only once and Whisperer does not keep a copy. If you lose access to your iCloud Keychain, this key is the only way to read your cloud history on a new Mac.")
            CloudBlock(colorScheme: colorScheme, padding: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 16) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, group in
                                Text(group).font(.system(size: 16, weight: .medium, design: .monospaced)).foregroundColor(primary)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .privacySensitive()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recovery key")
                .accessibilityValue(groups.joined(separator: ", "))
                .uiTestFrame("cloud.key.text")
            }
            HStack(spacing: 10) {
                secondaryButton(model.keyCopied ? "Copied" : "Copy", icon: model.keyCopied ? "checkmark" : "doc.on.doc", id: "cloud.key.copy") { model.copyRecoveryKey() }
                    .contentTransition(.symbolEffect(.replace))
                secondaryButton(model.keyFileSaved ? "Saved" : "Save as file…", icon: model.keyFileSaved ? "checkmark" : "square.and.arrow.down", id: "cloud.key.save") { model.saveRecoveryKeyFile() }
                secondaryButton("Print…", icon: "printer", id: "cloud.key.print") { model.printRecoveryKey() }
            }
            confirmSavedRow
            HStack(spacing: 14) {
                CloudPrimaryButton(title: "Finish", icon: "checkmark", id: "cloud.key.finish", enabled: model.keyConfirmed) { model.finishRecoveryKey() }
                if !model.keyConfirmed {
                    Text("Tick the box above once your key is somewhere safe.").font(.system(size: 12)).foregroundColor(tertiary)
                }
            }
        }
    }

    /// An explicit tick: the whole row is one button.
    private var confirmSavedRow: some View {
        Button { withAnimation(spring) { model.keyConfirmed.toggle() } } label: {
            HStack(spacing: 12) {
                Image(systemName: model.keyConfirmed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16)).foregroundColor(model.keyConfirmed ? WhispererColors.accentBlue : secondary)
                Text("I have saved it").font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                Text("Somewhere other than this Mac, such as a password manager or a printed page.")
                    .font(.system(size: 12)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerOnHover()
        .uiTestFrame("cloud.key.confirm")
        .accessibilityLabel("I have saved my recovery key")
        .accessibilityValue(model.keyConfirmed ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    // MARK: New Mac

    @ViewBuilder
    private func newMacScreen(_ needs: CloudNeedsKey?) -> some View {
        if let needs {
            needsKeyScreen(needs)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                titleBlock(icon: "macbook", tint: .cyan, title: "Adding this Mac",
                           text: "This Mac is joining your Whisperer Cloud library. If it does not move on, check that you are signed in to the Apple ID that subscribed.")
                HStack(spacing: 12) {
                    secondaryButton("Try again", icon: "arrow.clockwise", id: "cloud.newmac.retry", enabled: !model.isBusy) { model.tryAgain() }
                    secondaryButton("Restore Purchases", id: "cloud.restore", enabled: !model.isBusy) { model.restorePurchases() }
                }
            }
        }
    }

    private func needsKeyScreen(_ needs: CloudNeedsKey) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            titleBlock(icon: "macbook", tint: .cyan, title: "This Mac is new to your library",
                       text: "Your history is locked, and the key normally arrives by itself through iCloud Keychain. Your history here is safe; it just cannot be opened on this Mac yet.",
                       pill: ("Waiting for the key", .warning))
            if needs.wrongKey {
                CloudNotice(text: "The key on this Mac does not match your library. If you started your library over on another Mac, the new key will arrive in a few minutes.", tone: .warning)
            }
            CloudBlock(colorScheme: colorScheme) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        CloudIconTile(icon: "icloud.and.arrow.down", color: .blue)
                        Text("Wait for iCloud Keychain").font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                    }
                    Text("Make sure iCloud Keychain is on in System Settings and that you are signed in to the same Apple ID. This can take a few minutes.")
                        .font(.system(size: 12)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
                    secondaryButton("Check again", icon: "arrow.clockwise", id: "cloud.needskey.recheck", enabled: !model.isBusy) { model.recheckKey() }
                }
            }
            if needs.recoveryAvailable { recoveryEntryBlock(needs) } else {
                CloudNotice(text: "No recovery key was made for this library, so only iCloud Keychain can unlock it on this Mac.", tone: .neutral)
            }
            advancedBlock(consequence: "Starting over deletes your cloud history for good and makes a new, empty library. Your history on your Macs is not touched. Do this only if you cannot get the key back.")
        }
    }

    private func recoveryEntryBlock(_ needs: CloudNeedsKey) -> some View {
        CloudBlock(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    CloudIconTile(icon: "key.fill", color: .orange)
                    Text("Use your recovery key").font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                }
                Text("Type or paste the 13 groups of 4 letters and numbers. Spaces, dashes and capitals do not matter.")
                    .font(.system(size: 12)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
                TextField("", text: $model.keyEntry, prompt: Text("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX")
                    .foregroundColor(Color.white.opacity(0.25)), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced)).foregroundColor(primary)
                    .lineLimit(2...3)
                    .focused($keyFieldFocused)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(WhispererColors.cardBackground(colorScheme))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(needs.wrongRecoveryKey ? CloudTone.warning.color.opacity(0.7) : (keyFieldFocused ? WhispererColors.accentBlue : Color.white.opacity(0.08)), lineWidth: 1)
                                .allowsHitTesting(false))
                    )
                    .privacySensitive()
                    .uiTestFrame("cloud.entry.field")
                    .accessibilityLabel("Recovery key")
                    .accessibilityHint("Thirteen groups of four letters and numbers")
                if needs.wrongRecoveryKey {
                    Text("That key does not unlock this library. Check it and try again.")
                        .font(.system(size: 12)).foregroundColor(CloudTone.warning.color)
                        .uiTestFrame("cloud.entry.rejected")
                }
                HStack(spacing: 12) {
                    CloudPrimaryButton(title: "Unlock", icon: "lock.open.fill", id: "cloud.entry.submit",
                                       enabled: model.keyEntryHasText && !model.isBusy) { model.submitRecoveryKey() }
                    secondaryButton("Paste", icon: "doc.on.clipboard", id: "cloud.entry.paste") { model.pasteRecoveryKey() }
                    if model.keyEntryHasText {
                        Text("\(model.keyEntryCharacterCount) of 52 characters").font(.system(size: 11)).foregroundColor(tertiary)
                    } else {
                        Text("Nothing entered yet.").font(.system(size: 11)).foregroundColor(tertiary)
                    }
                }
            }
        }
    }

    // MARK: Revoked and problems

    private var revokedScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleBlock(icon: "macbook.slash", tint: .orange, title: "This Mac was removed",
                       text: "It was removed from Whisperer Cloud, from this Mac or another one. Your history on this Mac is untouched. You can sign this Mac in again.",
                       pill: ("Signed out", .warning))
            HStack(spacing: 14) {
                CloudPrimaryButton(title: "Start over", icon: "arrow.clockwise", id: "cloud.revoked.start", enabled: !model.isBusy) { model.startOver() }
                Text("Nothing is deleted.").font(.system(size: 12)).foregroundColor(tertiary)
            }
        }
    }

    private func unavailableScreen(_ problem: CloudAccountProblem) -> some View {
        let text = Self.problemText(problem)
        return VStack(alignment: .leading, spacing: 14) {
            titleBlock(icon: text.icon, tint: .orange, title: text.title, text: text.body)
            HStack(spacing: 14) {
                CloudPrimaryButton(title: "Try again", icon: "arrow.clockwise", id: "cloud.unavailable.retry", enabled: !model.isBusy) { model.tryAgain() }
                if text.offersStartOver {
                    CloudLinkButton(title: "Start over", id: "cloud.unavailable.startover", enabled: !model.isBusy) { model.startOver() }
                }
            }
            if let reference = text.reference {
                Text("Reference: \(reference)").font(.system(size: 11, design: .monospaced)).foregroundColor(tertiary)
            }
        }
    }

    static func problemText(_ problem: CloudAccountProblem) -> (icon: String, title: String, body: String, offersStartOver: Bool, reference: String?) {
        switch problem {
        case .offline:
            return ("wifi.slash", "You are offline", "Whisperer Cloud needs a connection. It carries on by itself when you are back online. Nothing is lost.", false, nil)
        case .deviceLimit:
            return ("macbook.gen2", "All the Mac spots are in use", "Your plan covers a limited number of Macs. Remove one from a Mac that is already signed in, or choose a larger plan.", false, nil)
        case .tooManyPending:
            return ("macbook.gen2", "Too many Macs are waiting", "Several Macs are waiting to join. Remove the ones you do not recognise from a Mac that is signed in, then try again.", false, nil)
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { $0 >= 90 ? "in about \(Int($0 / 60)) minutes" : "in a minute" } ?? "in a little while"
            return ("clock", "Please wait a moment", "There were too many attempts. Try again \(wait).", false, nil)
        case .wrongProduct:
            return ("questionmark.circle", "That subscription could not be used", "It does not match this version of Whisperer. Try Restore Purchases, or contact support if it keeps happening.", false, nil)
        case .keychain:
            return ("key.slash", "The Keychain is not available", "Whisperer could not reach the Keychain on this Mac. Unlock it, then try again.", true, nil)
        case .server(let code):
            return ("icloud.slash", "Whisperer Cloud is not reachable", "Nothing is lost. Try again in a moment.", true, code)
        }
    }
}

/// A dot that breathes while something is working; still when Reduce Motion is on.
struct CloudWorkingDot: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(WhispererColors.accentBlue.opacity(0.25)).frame(width: 20, height: 20)
                .scaleEffect(on && !reduceMotion ? 1 : 0.6)
            Circle().fill(WhispererColors.accentBlue).frame(width: 9, height: 9)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
        }
    }
}
