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
    /// The recording produced no audio at all — the input delivered silence for its whole
    /// length. Distinct from "a quiet meeting": nothing was ever captured, so there is no
    /// transcript to be had and the row must never read as an ordinary empty meeting.
    @NSManaged public var captureFailed: Bool
    /// True when the user has explicitly set the title. When true, automatic LLM title
    /// generation never overwrites it.
    @NSManaged public var titleIsUserSet: Bool
    @NSManaged public var sourceBundleID: String?
    @NSManaged public var sourceAppName: String?
}

extension MeetingEntity: Identifiable {}

extension MeetingEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<MeetingEntity> {
        NSFetchRequest<MeetingEntity>(entityName: "MeetingEntity")
    }
}
