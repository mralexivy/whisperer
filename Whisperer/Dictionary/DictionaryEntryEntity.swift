//
//  DictionaryEntryEntity.swift
//  Whisperer
//
//  Core Data entity for dictionary entries
//

import Foundation
import CoreData

@objc(DictionaryEntryEntity)
public class DictionaryEntryEntity: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var incorrectForm: String
    @NSManaged public var correctForm: String
    @NSManaged public var category: String?
    @NSManaged public var isBuiltIn: Bool
    @NSManaged public var isEnabled: Bool
    @NSManaged public var notes: String?
    @NSManaged public var createdAt: Date
    @NSManaged public var lastModifiedAt: Date
    @NSManaged public var useCount: Int32
}

extension DictionaryEntryEntity: Identifiable {}

// MARK: - Fetch Request

extension DictionaryEntryEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<DictionaryEntryEntity> {
        return NSFetchRequest<DictionaryEntryEntity>(entityName: "DictionaryEntryEntity")
    }
}

// MARK: - Convenience Initializer

extension DictionaryEntryEntity {
    static func create(
        in context: NSManagedObjectContext,
        incorrectForm: String,
        correctForm: String,
        category: String? = nil,
        isBuiltIn: Bool = false,
        notes: String? = nil
    ) -> DictionaryEntryEntity {
        let entity = DictionaryEntryEntity(context: context)
        let now = Date()

        entity.id = UUID()
        entity.incorrectForm = incorrectForm.lowercased()
        entity.correctForm = correctForm
        entity.category = category
        entity.isBuiltIn = isBuiltIn
        entity.isEnabled = true
        entity.notes = notes
        entity.createdAt = now
        entity.lastModifiedAt = now
        entity.useCount = 0

        return entity
    }
}
