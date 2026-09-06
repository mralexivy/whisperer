//
//  MeetingSourceAppTests.swift
//  WhispererTests
//
//  Tests for source-app attribution on meeting notes.
//
//  Run with:
//    xcodebuild test -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
//      -destination "platform=macOS" -only-testing:WhispererTests/MeetingSourceAppTests
//

import XCTest
import CoreData
import SwiftUI
@testable import whisperer

@MainActor
final class MeetingSourceAppTests: XCTestCase {

    // MARK: - MeetingListItem round-trip

    func testListItemRoundTripWithSource() throws {
        let entity = makeMeetingEntity(bundleID: "us.zoom.xos", appName: "Zoom")
        let item = MeetingListItem(from: entity)
        XCTAssertEqual(item.sourceBundleID, "us.zoom.xos")
        XCTAssertEqual(item.sourceAppName, "Zoom")
    }

    func testListItemRoundTripWithNoSource() throws {
        let entity = makeMeetingEntity(bundleID: nil, appName: nil)
        let item = MeetingListItem(from: entity)
        XCTAssertNil(item.sourceBundleID)
        XCTAssertNil(item.sourceAppName)
    }

    func testListItemConvenienceInitDefaults() {
        let item = MeetingListItem(id: UUID(), title: "Test", language: "en")
        XCTAssertNil(item.sourceBundleID)
        XCTAssertNil(item.sourceAppName)
    }

    func testListItemConvenienceInitWithSource() {
        let item = MeetingListItem(id: UUID(), title: "Test", language: "en",
                                   sourceBundleID: "com.tinyspeck.slackmacgap",
                                   sourceAppName: "Slack Huddle")
        XCTAssertEqual(item.sourceBundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(item.sourceAppName, "Slack Huddle")
    }

    // MARK: - MeetingRecord round-trip

    func testRecordRoundTripWithSource() throws {
        let entity = makeMeetingEntity(bundleID: "com.microsoft.teams2", appName: "Microsoft Teams")
        let record = MeetingRecord(from: entity)
        XCTAssertEqual(record.sourceBundleID, "com.microsoft.teams2")
        XCTAssertEqual(record.sourceAppName, "Microsoft Teams")
    }

    func testRecordRoundTripWithNoSource() throws {
        let entity = makeMeetingEntity(bundleID: nil, appName: nil)
        let record = MeetingRecord(from: entity)
        XCTAssertNil(record.sourceBundleID)
        XCTAssertNil(record.sourceAppName)
    }

    func testRecordNewInitDefaults() {
        let record = MeetingRecord(title: "Test", language: "en", modelUsed: "tiny")
        XCTAssertNil(record.sourceBundleID)
        XCTAssertNil(record.sourceAppName)
    }

    // MARK: - MeetingDetector.fallbackIcon

    func testFallbackIconSlack() {
        let fb = MeetingDetector.shared.fallbackIcon(for: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(fb.symbol, "headphones")
    }

    func testFallbackIconTeams() {
        let fb = MeetingDetector.shared.fallbackIcon(for: "com.microsoft.teams2")
        XCTAssertEqual(fb.symbol, "person.3.fill")
    }

    func testFallbackIconZoom() {
        let fb = MeetingDetector.shared.fallbackIcon(for: "us.zoom.xos")
        XCTAssertEqual(fb.symbol, "video.fill")
    }

    func testFallbackIconBrowser() {
        let fb = MeetingDetector.shared.fallbackIcon(for: "com.google.Chrome")
        // Chrome is a browser → blue video.fill
        XCTAssertEqual(fb.symbol, "video.fill")
    }

    func testFallbackIconUnknown() {
        let fb = MeetingDetector.shared.fallbackIcon(for: "com.example.unknown")
        XCTAssertEqual(fb.symbol, "video.fill")
    }

    // MARK: - Helpers

    // Kept alive for the process: NSManagedObject has a synthesized @MainActor deinit under
    // SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor; deallocating the container from a synchronous
    // test method aborts the test host. Storing it statically avoids the deinit entirely.
    private static let sharedTestContainer: NSPersistentContainer = {
        let model = NSManagedObjectModel()
        let entityDesc = NSEntityDescription()
        entityDesc.name = "MeetingEntity"
        entityDesc.managedObjectClassName = NSStringFromClass(MeetingEntity.self)

        func attr(_ name: String, type: NSAttributeType, optional: Bool = true) -> NSAttributeDescription {
            let d = NSAttributeDescription()
            d.name = name
            d.attributeType = type
            d.isOptional = optional
            return d
        }

        entityDesc.properties = [
            attr("id",            type: .UUIDAttributeType,      optional: false),
            attr("title",         type: .stringAttributeType,    optional: false),
            attr("createdAt",     type: .dateAttributeType,      optional: false),
            attr("duration",      type: .doubleAttributeType,    optional: false),
            attr("audioFileURL",  type: .stringAttributeType),
            attr("segmentsJSON",  type: .stringAttributeType),
            attr("aiSummaryJSON", type: .stringAttributeType),
            attr("notesJSON",     type: .stringAttributeType),
            attr("wordCount",     type: .integer32AttributeType, optional: false),
            attr("language",      type: .stringAttributeType,    optional: false),
            attr("modelUsed",     type: .stringAttributeType,    optional: false),
            attr("isInProgress",  type: .booleanAttributeType,   optional: false),
            attr("sourceBundleID", type: .stringAttributeType),
            attr("sourceAppName",  type: .stringAttributeType),
        ]
        model.entities = [entityDesc]

        let container = NSPersistentContainer(name: "Test", managedObjectModel: model)
        let desc = NSPersistentStoreDescription()
        desc.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [desc]
        container.loadPersistentStores { _, _ in }
        return container
    }()

    private func makeMeetingEntity(bundleID: String?, appName: String?) -> MeetingEntity {
        let ctx = Self.sharedTestContainer.viewContext
        let entityDesc = Self.sharedTestContainer.managedObjectModel.entitiesByName["MeetingEntity"]!
        let entity = MeetingEntity(entity: entityDesc, insertInto: ctx)
        entity.id = UUID()
        entity.title = "Test Meeting"
        entity.createdAt = Date()
        entity.duration = 0
        entity.language = "en"
        entity.modelUsed = "tiny"
        entity.isInProgress = false
        entity.wordCount = 0
        entity.sourceBundleID = bundleID
        entity.sourceAppName = appName
        return entity
    }
}
