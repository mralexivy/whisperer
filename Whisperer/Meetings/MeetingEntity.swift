//
//  MeetingEntity.swift
//  Whisperer
//
//  Core Data entity for meeting recordings.
//

import Foundation
import CoreData

@objc(MeetingEntity)
public class MeetingEntity: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var title: String
    @NSManaged public var createdAt: Date
    @NSManaged public var duration: Double
    @NSManaged public var audioFileURL: String?
    @NSManaged public var segmentsJSON: String?
    @NSManaged public var aiSummaryJSON: String?
    @NSManaged public var notesJSON: String?
    @NSManaged public var wordCount: Int32
    @NSManaged public var language: String
    @NSManaged public var modelUsed: String
    @NSManaged public var isInProgress: Bool
}

extension MeetingEntity: Identifiable {}

extension MeetingEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<MeetingEntity> {
        NSFetchRequest<MeetingEntity>(entityName: "MeetingEntity")
    }
}
