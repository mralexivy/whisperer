//
//  CloudPanelTestSupport.swift
//  WhispererTests
//
//  A stub account, a recording environment and a fake plan picker for the Cloud panel tests: no network,
//  no StoreKit, no pasteboard, no panels.
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class StubCloudAccount: CloudAccountDriving {
    @Published var state: CloudAccountState
    @Published var identity: CloudAccountIdentity?
    @Published var accountInfo: CloudAccountInfo?
    @Published var lastError: String?
    @Published var isPurchasePending = false

    private(set) var purchases: [CloudProduct] = []
    private(set) var restoreCount = 0
    private(set) var refreshCount = 0
    private(set) var recheckCount = 0
    private(set) var submitted: [String] = []
    private(set) var createKeyCount = 0
    private(set) var finishCount = 0
    private(set) var resets: [String] = []
    private(set) var revoked: [String] = []
    private(set) var startOverCount = 0

    static let sampleKey: String = { try! CloudRecoveryKey.encode(Data((0..<32).map { UInt8(($0 * 7 + 3) % 256) })) }()

    init(state: CloudAccountState = .notSubscribed, info: CloudAccountInfo? = nil) {
        self.state = state
        self.accountInfo = info
    }

    func refresh() async { refreshCount += 1 }
    func recheckKey() async { recheckCount += 1 }
    func purchase(_ product: CloudProduct) async { purchases.append(product); state = .creatingAccount }
    func restorePurchases() async { restoreCount += 1 }

    func submitRecoveryKey(_ text: String) async {
        submitted.append(text)
        guard case .needsKey(var needs) = state else { return }
        if (try? CloudRecoveryKey.decode(text)) != nil { state = .ready } else { needs.wrongRecoveryKey = true; state = .needsKey(needs) }
    }

    func createRecoveryKey() async { createKeyCount += 1; state = .showRecoveryKey(Self.sampleKey) }
    func finishRecoveryKey() { finishCount += 1; state = .ready }
    func resetLibrary(confirmation: String) async { resets.append(confirmation); state = .offerRecoveryKey }
    func refreshAccount() async {}

    func revokeDevice(id: String) async {
        revoked.append(id)
        accountInfo?.devices.removeAll { $0.id == id }
    }

    func startOver() async { startOverCount += 1; state = .notSubscribed }
}

/// Everything the panel does to the outside world, recorded.
@MainActor
final class PanelRecorder {
    var copied: [(text: String, sensitive: Bool)] = []
    var clipboard: String?
    var savedKeys: [String] = []
    var printedKeys: [String] = []
    var managed = 0

    func environment(for account: StubCloudAccount) -> CloudPanelEnvironment {
        CloudPanelEnvironment(
            plansView: { _ in AnyView(StubPlans(account: account)) },
            copy: { [unowned self] text, sensitive in copied.append((text, sensitive)) },
            readClipboard: { [unowned self] in clipboard },
            saveRecoveryKeyFile: { [unowned self] key in savedKeys.append(key); return true },
            printRecoveryKey: { [unowned self] key in printedKeys.append(key) },
            openSubscriptionManagement: { [unowned self] in managed += 1 },
            now: { Date(timeIntervalSince1970: 1_794_000_000) })
    }
}

/// Stands in for Apple's SubscriptionStoreView, which cannot load products in a test.
struct StubPlans: View {
    let account: StubCloudAccount

    var body: some View {
        VStack(spacing: 10) {
            Text("Choose a plan").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            HStack(spacing: 10) {
                ForEach(["Starter · 5 GB", "Standard · 25 GB", "Large · 100 GB"], id: \.self) { name in
                    VStack(spacing: 4) {
                        Text(name).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        Text("Price from the App Store").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                }
            }
            Button { Task { await account.purchase(CloudProduct(tier: .standard, period: .monthly)) } } label: {
                Text("Subscribe").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 9).fill(WhispererColors.accentBlue))
            }
            .buttonStyle(.plain)
            .uiTestFrame("cloud.stub.subscribe")
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(WhispererColors.elevatedBackground(.dark).opacity(0.6))
    }
}

enum CloudPanelFixtures {
    static let now = Date(timeIntervalSince1970: 1_794_000_000)   // 2026-11-12

    static func device(_ id: String, current: Bool = false, state: CloudDeviceState = .authorized, addedDaysAgo: Int = 30, seenHoursAgo: Int? = 2) -> CloudDeviceInfo {
        CloudDeviceInfo(id: id, state: state, current: current, labelEnc: nil,
                        enrolledAt: now.addingTimeInterval(-Double(addedDaysAgo) * 86_400),
                        lastSeenAt: seenHoursAgo.map { now.addingTimeInterval(-Double($0) * 3_600) },
                        expiresAt: state == .pending ? now.addingTimeInterval(5 * 86_400) : nil)
    }

    static func info(plan: String = "standard", storedGB: Double = 12.4, quotaGB: Double = 25, autoRenew: Bool = true,
                     state: CloudServerState = .active, deleteAfter: Date? = nil, recovery: Bool = true,
                     devices: [CloudDeviceInfo]? = nil) -> CloudAccountInfo {
        let gb = 1_000_000_000.0
        return CloudAccountInfo(
            accountId: String(repeating: "a", count: 32), epoch: 1, state: state,
            paidUntil: now.addingTimeInterval(31 * 86_400), autoRenew: autoRenew, deleteAfter: deleteAfter,
            plan: CloudPlanSummary(name: plan, storedBytes: Int64(quotaGB * gb), monthlyDownloadBytes: Int64(quotaGB * 2 * gb), monthlyUploadGrants: 50_000),
            deviceLimit: 4, usage: CloudUsage(storedBytes: Int64(storedGB * gb), downloadBytes: Int64(3.1 * gb), uploadGrants: 410),
            library: CloudLibraryInfo(exists: true, keyVersion: 1, recoveryAvailable: recovery),
            devices: devices ?? [device("dev-this", current: true, addedDaysAgo: 120, seenHoursAgo: 0),
                                 device("dev-studio", addedDaysAgo: 60, seenHoursAgo: 5),
                                 device("dev-air", state: .pending, addedDaysAgo: 1, seenHoursAgo: nil)])
    }
}

/// Hosts the panel in a real window so tests can send real mouse events to it.
@MainActor
final class CloudPanelHost {
    static var keepAlive: [AnyObject] = []
    let window: NSWindow
    let scope = "cloud-\(UUID().uuidString.prefix(8))"

    init<V: View>(_ view: V, width: CGFloat = 800, height: CGFloat = 2400) {
        let hosting = NSHostingView(rootView: view.padding(24).frame(width: width).environment(\.uiTestScope, scope).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeKeyAndOrderFront(nil)
        window.setFrame(CGRect(x: 40, y: 40, width: width, height: height), display: true)
        self.window = window
        Self.keepAlive += [hosting, window]
        pump(0.5)
    }

    func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    func frame(_ id: String) -> CGRect? { UITestFrames.frames[UITestFrames.key(scope: scope, id: id)] }

    func click(_ id: String, x: CGFloat = 0.5, y: CGFloat = 0.5, file: StaticString = #filePath, line: UInt = #line) throws {
        pump(0.4)
        guard let f = frame(id) else {
            XCTFail("no frame for \(id); have \(UITestFrames.frames.keys.filter { $0.hasPrefix(scope) }.sorted())", file: file, line: line)
            return
        }
        let height = window.contentView?.bounds.height ?? 0
        let point = NSPoint(x: f.minX + f.width * x, y: height - (f.minY + f.height * y))
        for (type, hold) in [(NSEvent.EventType.mouseMoved, 0.15), (.leftMouseDown, 0.2), (.leftMouseUp, 0.05)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1), file: file, line: line)
            window.sendEvent(event)
            pump(hold)
        }
        pump(0.5)
    }
}
