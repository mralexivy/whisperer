//
//  CoreDataSave.swift
//  Whisperer
//

import Foundation
import CoreData

enum PersistenceError: Error, LocalizedError {
    case saveFailed(operation: String, underlying: Error)
    case rowNotFound(operation: String)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let op, let underlying):
            return "Couldn't save \(op): \(underlying.localizedDescription)"
        case .rowNotFound(let op):
            return "\(op) failed — the record no longer exists."
        }
    }
}

extension NSManagedObjectContext {
    /// Run `body` on this context's queue, then commit.
    /// Uses CoreData's rethrows `perform` overload — no captured-error local needed.
    func performAndSave<T>(
        _ operation: String,
        _ body: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) async throws -> T {
        try await perform { [self] in
            let result = try body(self)
            guard hasChanges else { return result }
            do {
                try save()
            } catch {
                Logger.error("\(operation) save failed: \(error)", subsystem: .app)
                throw PersistenceError.saveFailed(operation: operation, underlying: error)
            }
            return result
        }
    }
}
