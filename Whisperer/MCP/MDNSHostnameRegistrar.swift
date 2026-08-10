//
//  MDNSHostnameRegistrar.swift
//  Whisperer
//
//  Resolves the machine's own mDNS hostname (e.g. "alexs-macbook-pro.local").
//  mDNSResponder already manages the machine's A record — no custom registration needed.
//  Excluded from App Store binary via #if !APP_STORE.
//

#if !APP_STORE
import Foundation
import SystemConfiguration

final class MDNSHostnameRegistrar {
    static let shared = MDNSHostnameRegistrar()

    private(set) var registeredHostname: String?

    /// Reads the machine's Bonjour hostname from the OS and stores it.
    /// The OS manages the .local A record automatically — this never fails on macOS.
    @discardableResult
    func register() -> Bool {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String? else {
            Logger.warning("mDNS: could not resolve local hostname", subsystem: .app)
            return false
        }
        registeredHostname = "\(name).local"
        Logger.info("mDNS: local hostname is \(registeredHostname!)", subsystem: .app)
        return true
    }

    func unregister() {
        registeredHostname = nil
    }
}
#endif
