//
//  BuildIdentity.swift
//  Whisperer
//
//  What an offline symbolicator needs to turn a logged address back into a function: which binary this is
//  (its UUID) and where it was loaded (the ASLR slide). Logged next to every main-thread stack.
//

import Foundation
import MachO

nonisolated enum BuildIdentity {
    /// "uuid=… load=0x…": the dSYM with that UUID plus `atos -o <dSYM>/Contents/Resources/DWARF/whisperer -l <load> <address>`.
    static let symbolicationNote: String = {
        var uuid = "unknown"
        var load: UInt = 0
        if let header = _dyld_get_image_header(0) {
            load = UInt(bitPattern: header) // the Mach header's address is exactly what atos wants as the load address
            var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let command = cursor.load(as: load_command.self)
                if command.cmd == UInt32(LC_UUID) {
                    let u = cursor.load(as: uuid_command.self)
                    uuid = UUID(uuid: u.uuid).uuidString
                    break
                }
                cursor = cursor.advanced(by: Int(command.cmdsize))
            }
        }
        return "uuid=\(uuid) load=0x\(String(load, radix: 16))"
    }()
}
