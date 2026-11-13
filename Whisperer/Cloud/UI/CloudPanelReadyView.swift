//
//  CloudPanelReadyView.swift
//  Whisperer
//
//  The signed-in screens of the Cloud panel: ready (plan, sync, usage, Macs, recovery key, Advanced) and
//  read-only (lapsed, refunded, payment retry, sealed, removed, over quota). Plan, dates and usage come
//  from `CloudAccountInfo`; sync state from `CloudSyncStatusSource`.
//

import SwiftUI

extension CloudPanelView {

    // MARK: Ready

    var readyScreen: some View {
        VStack(alignment: .leading, spacing: 20) {
            planBlock
            if let over = model.overQuotaBytes {
                CloudNotice(text: "Your library is \(CloudPanelModel.size(over)) over your plan, so new changes cannot upload. Free about \(CloudPanelModel.size(over)) by deleting old recordings in History, or choose a larger plan in Manage Subscription.",
                            tone: .warning)
                    .uiTestFrame("cloud.overquota")
            }
            syncBlock
            usageBlock
            macsBlock
            recoveryBlock
            advancedBlock(consequence: "This deletes your library from the cloud for good. Your history on your Macs is not touched. Sync starts again with a new key, and the old cloud copy can never be read.")
        }
    }

    private var planBlock: some View {
        CloudBlock(colorScheme: colorScheme) {
            HStack(alignment: .top, spacing: 12) {
                CloudIconTile(icon: "icloud.fill", color: .purple, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.info == nil ? "Whisperer Cloud" : "\(model.planTitle) plan")
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(primary)
                        if let info = model.info {
                            CloudPill(text: info.autoRenew ? "Active" : "Ending", tone: info.autoRenew ? .good : .warning)
                        }
                    }
                    Text(planDetail).font(.system(size: 12)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
                    Text(renewalLine).font(.system(size: 12)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                secondaryButton("Manage Subscription", icon: "creditcard", id: "cloud.manage") { model.manageSubscription() }
            }
        }
    }

    private var planDetail: String {
        guard let info = model.info else { return "Loading your plan…" }
        return "\(CloudPanelModel.size(info.plan.storedBytes)) of storage · up to \(info.deviceLimit) Macs"
    }

    private var renewalLine: String {
        guard let info = model.info else { return " " }
        return info.autoRenew
            ? "Renews on \(model.date(info.paidUntil))."
            : "Will not renew. Cloud works until \(model.date(info.paidUntil))."
    }

    // MARK: Sync

    private var syncBlock: some View {
        let line = syncLine
        return CloudBlock(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    CloudIconTile(icon: line.icon, color: line.tone.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title).font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                            .uiTestFrame("cloud.sync.status")
                        Text(line.detail).font(.system(size: 12)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        secondaryButton(model.sync.status == .paused ? "Resume" : "Pause",
                                        icon: model.sync.status == .paused ? "play.fill" : "pause.fill", id: "cloud.sync.toggle") { model.toggleSyncPaused() }
                        secondaryButton("Sync now", icon: "arrow.triangle.2.circlepath", id: "cloud.sync.now", enabled: canSyncNow) { model.syncNow() }
                    }
                }
                if case .syncing(let progress) = model.sync.status, let progress {
                    CloudUsageBar(fraction: progress, height: 6)
                }
            }
        }
    }

    private var canSyncNow: Bool {
        switch model.sync.status {
        case .idle, .offline, .error: return !model.isBusy
        default: return false
        }
    }

    private struct SyncLine { var icon: String; var tone: CloudTone; var title: String; var detail: String }

    private var syncLine: SyncLine {
        let pending = model.sync.pendingChanges
        let waiting = pending > 0 ? "\(pending.formatted()) \(pending == 1 ? "change is" : "changes are") waiting to upload." : nil
        let last = model.sync.lastSyncedAt.map { "Last synced \(model.relative($0))." } ?? "Not synced yet."
        switch model.sync.status {
        case .idle:
            return SyncLine(icon: "checkmark.icloud.fill", tone: .good, title: "Up to date", detail: [last, waiting].compactMap { $0 }.joined(separator: " "))
        case .syncing(let progress):
            let pct = progress.map { " \(Int($0 * 100))%" } ?? ""
            return SyncLine(icon: "arrow.triangle.2.circlepath.icloud", tone: .accent, title: "Syncing…\(pct)", detail: waiting ?? "Your Macs are catching up.")
        case .offline:
            return SyncLine(icon: "icloud.slash", tone: .warning, title: "Offline", detail: "Changes wait on this Mac and upload when you are connected. \(last)")
        case .paused:
            return SyncLine(icon: "pause.circle.fill", tone: .neutral, title: "Paused", detail: ["Nothing syncs until you resume.", waiting].compactMap { $0 }.joined(separator: " "))
        case .readOnly:
            return SyncLine(icon: "lock.icloud", tone: .warning, title: "Read-only", detail: "Your subscription is not active, so nothing new syncs.")
        case .needsKey:
            return SyncLine(icon: "key.icloud", tone: .warning, title: "Waiting for the library key", detail: "This Mac cannot sync until the key arrives from iCloud Keychain.")
        case .overQuota:
            return SyncLine(icon: "exclamationmark.icloud.fill", tone: .warning, title: "Over your plan", detail: "New changes cannot upload until there is room. \(waiting ?? "")")
        case .error(let message):
            return SyncLine(icon: "exclamationmark.icloud.fill", tone: .warning, title: "Sync stopped", detail: message)
        }
    }

    // MARK: Usage

    private var usageBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            CloudSectionLabel(text: "Storage")
            CloudBlock(colorScheme: colorScheme, padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    if let usage = model.usage {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(CloudPanelModel.size(usage.storedBytes))
                                    .font(.system(size: 24, weight: .light, design: .rounded)).foregroundColor(primary)
                                    .contentTransition(.numericText())
                                Text("of \(CloudPanelModel.size(usage.quotaBytes)) used").font(.system(size: 13)).foregroundColor(secondary)
                            }
                            CloudUsageBar(fraction: usage.fraction, tone: tone(for: usage.fraction), height: 14)
                                .uiTestFrame("cloud.usage.stored")
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Storage")
                        .accessibilityValue("\(CloudPanelModel.size(usage.storedBytes)) of \(CloudPanelModel.size(usage.quotaBytes)) used")
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Downloads this month").font(.system(size: 12, weight: .medium)).foregroundColor(secondary)
                                Spacer()
                                Text("\(CloudPanelModel.size(usage.downloadBytes)) of \(CloudPanelModel.size(usage.downloadQuotaBytes))")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(primary)
                            }
                            CloudUsageBar(fraction: usage.downloadFraction, tone: tone(for: usage.downloadFraction), height: 8)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Downloads this month")
                        .accessibilityValue("\(CloudPanelModel.size(usage.downloadBytes)) of \(CloudPanelModel.size(usage.downloadQuotaBytes))")
                    } else {
                        Text("Measuring…").font(.system(size: 13)).foregroundColor(secondary)
                    }
                }
            }
        }
    }

    private func tone(for fraction: Double) -> CloudTone {
        fraction >= 1 ? .bad : (fraction >= 0.9 ? .warning : .accent)
    }

    // MARK: Macs

    private var macsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            CloudSectionLabel(text: "Your Macs",
                              hint: model.info.map { "\(model.devices.count) of \($0.deviceLimit) in use." })
            VStack(spacing: 8) {
                ForEach(model.devices) { device in deviceRow(device) }
            }
        }
    }

    private func deviceRow(_ device: CloudDeviceInfo) -> some View {
        let confirming = model.revokeCandidate == device.id
        let pending = device.state == .pending
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                CloudIconTile(icon: device.current ? "laptopcomputer" : "macbook", color: device.current ? WhispererColors.accentBlue : (pending ? .orange : .cyan))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(device.current ? "This Mac" : (pending ? "A Mac waiting to join" : "Another Mac"))
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                        if pending { CloudPill(text: "Waiting", tone: .warning) }
                    }
                    Text(deviceDetail(device)).font(.system(size: 12)).foregroundColor(secondary)
                }
                Spacer(minLength: 12)
                if !confirming {
                    CloudLinkButton(title: device.current ? "Sign out" : "Remove", id: "cloud.device.\(device.id).revoke",
                                    enabled: model.canRevoke, tone: .bad) { withAnimation(spring) { model.requestRevoke(device.id) } }
                        .accessibilityLabel(device.current ? "Sign out this Mac" : "Remove this Mac from Whisperer Cloud")
                }
            }
            if confirming {
                VStack(alignment: .leading, spacing: 10) {
                    Text(device.current
                         ? "Sign this Mac out of Whisperer Cloud? Your history here is not deleted, and you can sign in again later."
                         : "Remove this Mac? It stops syncing and must sign in again to come back. Its own history is not deleted.")
                        .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        secondaryButton(device.current ? "Sign out" : "Remove", id: "cloud.device.\(device.id).confirm", enabled: model.canRevoke, tint: CloudTone.bad.color) { model.confirmRevoke() }
                        secondaryButton("Cancel", id: "cloud.device.\(device.id).cancel") { withAnimation(spring) { model.cancelRevoke() } }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.5)))
        .shadow(color: Color.black.opacity(0.05), radius: 4, y: 1)
        .uiTestFrame("cloud.device.\(device.id)")
    }

    private func deviceDetail(_ device: CloudDeviceInfo) -> String {
        if device.state == .pending, let expires = device.expiresAt { return "Needs this Mac’s key. Offer expires \(model.date(expires))." }
        var parts = ["Added \(model.date(device.enrolledAt))"]
        if !device.current, let seen = device.lastSeenAt { parts.append("last seen \(model.relative(seen))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Recovery key

    private var recoveryBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            CloudSectionLabel(text: "Recovery key")
            CloudBlock(colorScheme: colorScheme) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        CloudIconTile(icon: "key.fill", color: .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(model.recoveryKeyIsSet ? "Recovery key is set" : "No recovery key yet")
                                    .font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                                CloudPill(text: model.recoveryKeyIsSet ? "Set" : "Not set", tone: model.recoveryKeyIsSet ? .good : .warning)
                            }
                            Text(model.recoveryKeyIsSet
                                 ? "It lets you open your history on a new Mac if you lose your iCloud Keychain. Lost it? Make a new one."
                                 : "Without one, only your iCloud Keychain can unlock your history on a new Mac.")
                                .font(.system(size: 12)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        if !model.confirmsNewRecoveryKey {
                            secondaryButton(model.recoveryKeyIsSet ? "Make a new key" : "Create key", icon: "key.fill", id: "cloud.recovery.create", enabled: !model.isBusy) {
                                if model.recoveryKeyIsSet { withAnimation(spring) { model.confirmsNewRecoveryKey = true } } else { model.createRecoveryKey() }
                            }
                        }
                    }
                    if model.confirmsNewRecoveryKey {
                        Text("This replaces your current recovery key. The old one stops working, so keep only the new one.")
                            .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            secondaryButton("Make a new key", icon: "key.fill", id: "cloud.recovery.confirm", enabled: !model.isBusy) { model.createRecoveryKey() }
                            secondaryButton("Cancel", id: "cloud.recovery.cancel") { withAnimation(spring) { model.confirmsNewRecoveryKey = false } }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
        }
    }

    // MARK: Advanced

    func advancedBlock(consequence: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(spring) { model.advancedOpen.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(secondary)
                        .rotationEffect(.degrees(model.advancedOpen ? 90 : 0))
                    Text("ADVANCED").font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundColor(secondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerOnHover()
            .uiTestFrame("cloud.advanced.toggle")
            .accessibilityLabel("Advanced")
            .accessibilityValue(model.advancedOpen ? "Expanded" : "Collapsed")
            if model.advancedOpen {
                resetBlock(consequence: consequence)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func resetBlock(consequence: String) -> some View {
        CloudBlock(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    CloudIconTile(icon: "trash.fill", color: CloudTone.bad.color)
                    Text(model.state == .ready ? "Delete cloud data" : "Reset library").font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                }
                Text(consequence).font(.system(size: 12)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
                Text("Type \(CloudResetPhrase.phrase) to confirm.").font(.system(size: 12, weight: .medium)).foregroundColor(Color.white.opacity(0.75))
                HStack(spacing: 12) {
                    TextField("", text: $model.resetPhrase, prompt: Text(CloudResetPhrase.phrase).foregroundColor(Color.white.opacity(0.25)))
                        .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).foregroundColor(primary)
                        .padding(10).frame(maxWidth: 300)
                        .background(RoundedRectangle(cornerRadius: 8).fill(WhispererColors.cardBackground(colorScheme)))
                        .uiTestFrame("cloud.reset.field")
                        .accessibilityLabel("Confirmation phrase")
                    secondaryButton(model.state == .ready ? "Delete cloud data" : "Reset library", icon: "trash", id: "cloud.reset.run",
                                    enabled: model.resetPhraseMatches && !model.isBusy, tint: CloudTone.bad.color) { model.resetLibrary() }
                }
                if !model.resetPhraseMatches {
                    Text("The button turns on when the phrase matches exactly.").font(.system(size: 11)).foregroundColor(tertiary)
                }
            }
        }
    }

    // MARK: Read-only

    func readOnlyScreen(_ reason: CloudReadOnlyReason) -> some View {
        let copy = readOnlyCopy(reason)
        return VStack(alignment: .leading, spacing: 16) {
            titleBlock(icon: copy.icon, tint: .orange, title: copy.title, text: copy.body, pill: ("Read-only", .warning))
            CloudNotice(text: "Your history is safe and still on your Macs. Nothing on them is changed or removed.", tone: .good, icon: "checkmark.shield.fill")
            if let next = copy.next {
                CloudNotice(text: next, tone: .neutral, icon: "calendar")
                    .uiTestFrame("cloud.readonly.next")
            }
            if let over = model.overQuotaBytes {
                CloudNotice(text: "Your library is also \(CloudPanelModel.size(over)) over your plan. To upload again you need to free about \(CloudPanelModel.size(over)) by deleting old recordings in History, or choose a larger plan.",
                            tone: .warning)
                    .uiTestFrame("cloud.overquota")
            }
            HStack(spacing: 12) {
                if reason == .paymentRetry {
                    CloudPrimaryButton(title: "Manage Subscription", icon: "creditcard", id: "cloud.manage") { model.manageSubscription() }
                } else {
                    CloudPrimaryButton(title: "Resubscribe", icon: "icloud.and.arrow.up", id: "cloud.readonly.resubscribe", enabled: !model.showsPlans) { model.showResubscribe() }
                }
                secondaryButton("Export my history", icon: "square.and.arrow.up", id: "cloud.readonly.export") { model.exportHistory() }
            }
            if model.showsPlans && reason != .paymentRetry {
                plansContainer.transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func readOnlyCopy(_ reason: CloudReadOnlyReason) -> (icon: String, title: String, body: String, next: String?) {
        let deleteAfter = model.info?.deleteAfter.map { model.date($0) }
        let keptUntil = deleteAfter.map { "Your cloud copy is kept until \($0). After that it is deleted. Subscribe again before then and sync picks up where it stopped." }
            ?? "Subscribe again and sync picks up where it stopped."
        switch reason {
        case .paymentRetry:
            return ("creditcard", "Apple could not renew your subscription",
                    "Apple is trying the payment again. Until it works, Whisperer Cloud is read-only: nothing new syncs, and you can still read what is there. Updating your payment method fixes it, and sync resumes by itself.",
                    model.info.map { "You have access until \(model.date($0.paidUntil))." })
        case .expired:
            return ("icloud.slash", "Your subscription has ended",
                    "Whisperer Cloud is read-only now. Nothing new syncs, and you can still read and export what is in the cloud.", keptUntil)
        case .refunded:
            return ("arrow.uturn.backward.circle", "This subscription was refunded",
                    "Whisperer Cloud is read-only now. Nothing new syncs, and you can still read and export what is in the cloud.", keptUntil)
        case .sealed:
            return ("lock.icloud", "Only your text can be downloaded now",
                    "Your subscription ended a while ago. Your transcripts can still be exported from the cloud, but recordings are no longer served from it.", keptUntil)
        case .removed:
            return ("icloud.slash", "Your cloud library was deleted",
                    "It was deleted after the subscription ended. Subscribe again to start a new library; your history on your Macs uploads to it.", nil)
        }
    }
}
