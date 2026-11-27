import AppKit
import XCTest
import TerminalCore
@testable import TranoApp

final class AccountOrganizationControlsTests: XCTestCase {
    private let firstUUID = "11111111-2222-4333-8444-555555555555"
    private let secondUUID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    // Implements: FR-ORG-1, FR-ORG-4
    @MainActor func testValidationNormalizesUUIDAndTrimsOptionalNameWithoutAcceptingInvalidUUID() async throws {
        let selection = try XCTUnwrap(AccountOrganizationValidation.selection(uuid: " \nAAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE ", name: "  Team  "))
        XCTAssertEqual(selection.uuid, secondUUID)
        XCTAssertEqual(selection.name, "Team")
        XCTAssertNil(try AccountOrganizationValidation.selection(uuid: " \n", name: ""))
        XCTAssertNil(try AccountOrganizationValidation.selection(uuid: firstUUID, name: "  ")?.name)
        XCTAssertThrowsError(try AccountOrganizationValidation.selection(uuid: "wrong", name: "Team"))
    }

    // Implements: FR-ORG-1, FR-ORG-4
    @MainActor func testNativeKnownChoiceSurvivesRedrawAndWritesOnlyAfterSave() async throws {
        _ = NSApplication.shared
        let known = try ClaudeOrganizationSelection(uuid: firstUUID, name: "Team")
        let owner = OrganizationControlsOwnerFixture()
        var writes: [(String, String, ClaudeOrganizationSelection?)] = []
        let draft = AccountOrganizationDraft(profileID: "profile-A", state: nil, knownOrganizations: [known],
            isCurrent: { profile, binding in profile == owner.profileID && binding.isEmpty },
            refresh: { _, _ in nil }, save: { writes.append(($0, $1, $2)) })
        let view = AccountOrganizationControlsView(draft: draft)
        try select(known.uuid, in: view)
        XCTAssertEqual(draft.organizationUUID, known.uuid)
        XCTAssertTrue(writes.isEmpty)
        let popUp = view.organizationPopUp
        let knownItem = try XCTUnwrap(popUp.selectedItem)
        view.configure(draft: draft)
        XCTAssertTrue(view.organizationPopUp === popUp)
        XCTAssertTrue(view.organizationPopUp.selectedItem === knownItem)
        XCTAssertEqual(view.organizationPopUp.selectedItem?.representedObject as? String, known.uuid)
        XCTAssertTrue(view.manualFields.isHidden)
        view.saveButton.performClick(nil)
        XCTAssertTrue(draft.isSaving)
        await settle()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, "profile-A")
        XCTAssertEqual(writes.first?.1, "")
        XCTAssertEqual(writes.first?.2, known)
        XCTAssertTrue(draft.isClosed)
        XCTAssertEqual(owner.profileID, "profile-A")
        owner.profileID = "profile-B"
    }

    // Implements: FR-ORG-1, FR-ORG-4
    @MainActor func testOtherFieldsValidateAndCancelWithoutWriting() async throws {
        _ = NSApplication.shared
        var writes = 0
        var cancellations = 0
        let draft = AccountOrganizationDraft(profileID: "profile-A", state: nil, knownOrganizations: [],
            refresh: { _, _ in nil }, save: { _, _, _ in writes += 1 }, cancel: { cancellations += 1 })
        let view = AccountOrganizationControlsView(draft: draft)
        try select("other", in: view)
        XCTAssertFalse(view.manualFields.isHidden)
        view.uuidField.stringValue = "wrong"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.uuidField))
        view.saveButton.performClick(nil)
        XCTAssertFalse(draft.isSaving)
        XCTAssertNotNil(draft.errorMessage)
        XCTAssertEqual(writes, 0)
        view.uuidField.stringValue = firstUUID.uppercased()
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.uuidField))
        view.nameField.stringValue = " Team "
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.nameField))
        view.configure(draft: draft)
        XCTAssertEqual(view.uuidField.stringValue, firstUUID.uppercased())
        XCTAssertEqual(view.nameField.stringValue, " Team ")
        view.cancelButton.performClick(nil)
        XCTAssertTrue(draft.isClosed)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(writes, 0)
    }

    // Implements: FR-ORG-1, FR-ORG-4
    @MainActor func testClearIsDraftOnlyAndConfiguredObservedStatusRemainDistinct() async throws {
        _ = NSApplication.shared
        let configured = try ClaudeOrganizationSelection(uuid: firstUUID, name: "Configured team")
        let observed = try ClaudeOrganizationSelection(uuid: secondUUID, name: "Observed team")
        let state = AccountOrganizationState(selection: configured, observed: observed, verification: .mismatch,
                                              checkedAt: Date(timeIntervalSince1970: 1), bindingID: "binding-A")
        var writes = 0
        let draft = AccountOrganizationDraft(profileID: "profile-A", state: state, knownOrganizations: [configured],
            refresh: { _, _ in nil }, save: { _, _, _ in writes += 1 })
        let view = AccountOrganizationControlsView(draft: draft)
        XCTAssertTrue(view.configuredLabel.stringValue.contains("Configured team"))
        XCTAssertTrue(view.observedLabel.stringValue.contains("Observed team"))
        XCTAssertTrue(view.verificationLabel.stringValue.contains("Mismatch"))
        try select("unbound", in: view)
        XCTAssertTrue(draft.organizationUUID.isEmpty)
        XCTAssertNil(try AccountOrganizationValidation.selection(uuid: draft.organizationUUID, name: draft.organizationName))
        XCTAssertEqual(draft.state, state)
        XCTAssertEqual(writes, 0)
    }

    // Implements: FR-ORG-4
    @MainActor func testRefreshIsImmediatelyDisabledAndCancelDropsLateCompletion() async throws {
        _ = NSApplication.shared
        var continuation: CheckedContinuation<AccountOrganizationState?, Error>?
        var calls = 0
        var cancellations = 0
        let draft = AccountOrganizationDraft(profileID: "profile-A", state: nil, knownOrganizations: [],
            refresh: { profile, binding in
                XCTAssertEqual(profile, "profile-A"); XCTAssertEqual(binding, "")
                calls += 1
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }, save: { _, _, _ in XCTFail("Refresh wrote selection") }, cancel: { cancellations += 1 })
        let view = AccountOrganizationControlsView(draft: draft)
        view.refreshButton.performClick(nil)
        XCTAssertTrue(draft.isRefreshing)
        XCTAssertFalse(view.refreshButton.isEnabled)
        XCTAssertFalse(view.spinner.isHidden)
        view.refreshButton.performClick(nil)
        await settle()
        XCTAssertEqual(calls, 1)
        view.cancelButton.performClick(nil)
        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(draft.isClosed)
        continuation?.resume(returning: AccountOrganizationState(selection: nil, observed: nil, verification: .unavailable,
                                                                 checkedAt: Date(), bindingID: ""))
        await settle()
        XCTAssertNil(draft.state)
        XCTAssertFalse(draft.isRefreshing)
    }

    // Implements: FR-ORG-4
    @MainActor func testRefreshRejectsChangedBindingAndChangedSelectedAccount() async throws {
        for changeOwner in [false, true] {
            var continuation: CheckedContinuation<AccountOrganizationState?, Error>?
            let owner = OrganizationControlsOwnerFixture()
            let draft = AccountOrganizationDraft(profileID: "profile-A", state: nil, knownOrganizations: [],
                isCurrent: { _, _ in owner.current },
                refresh: { _, _ in try await withCheckedThrowingContinuation { continuation = $0 } },
                save: { _, _, _ in XCTFail("Refresh wrote selection") })
            draft.refresh()
            XCTAssertTrue(draft.isRefreshing)
            await settle()
            XCTAssertNotNil(continuation)
            if changeOwner { owner.current = false }
            continuation?.resume(returning: AccountOrganizationState(selection: nil, observed: nil, verification: .unavailable,
                checkedAt: Date(), bindingID: changeOwner ? "" : "new-binding"))
            await settle()
            XCTAssertNil(draft.state)
            XCTAssertFalse(draft.isRefreshing)
        }
    }

    // Implements: FR-ORG-4
    @MainActor func testSaveRemainsOpenUntilPersistenceAndDisablesCancelAfterDispatch() async throws {
        _ = NSApplication.shared
        var continuation: CheckedContinuation<Void, Error>?
        var cancellations = 0
        let known = try ClaudeOrganizationSelection(uuid: firstUUID, name: "Team")
        let draft = AccountOrganizationDraft(profileID: "profile-A", state: nil, knownOrganizations: [known],
            refresh: { _, _ in nil },
            save: { _, _, selection in
                XCTAssertEqual(selection, known)
                try await withCheckedThrowingContinuation { continuation = $0 }
            }, cancel: { cancellations += 1 })
        let view = AccountOrganizationControlsView(draft: draft)
        try select(known.uuid, in: view)
        view.saveButton.performClick(nil)
        XCTAssertTrue(draft.isSaving)
        XCTAssertFalse(draft.isClosed)
        XCTAssertFalse(view.cancelButton.isEnabled)
        XCTAssertFalse(view.saveButton.isEnabled)
        await settle()
        draft.cancel()
        XCTAssertEqual(cancellations, 0)
        continuation?.resume(returning: ())
        await settle()
        XCTAssertTrue(draft.isClosed)
        XCTAssertFalse(draft.isSaving)
    }

    // Implements: FR-ORG-4
    @MainActor func testSaveFailureKeepsEditableDraftAndOwnerLossPreventsWrite() async throws {
        enum Failure: Error { case rejected }
        let owner = OrganizationControlsOwnerFixture()
        var writes = 0
        let draft = AccountOrganizationDraft(profileID: "profile-A", state: nil, knownOrganizations: [],
            isCurrent: { _, _ in owner.current }, refresh: { _, _ in nil },
            save: { _, _, _ in writes += 1; throw Failure.rejected })
        draft.save()
        await settle()
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(draft.isClosed)
        XCTAssertFalse(draft.isSaving)
        XCTAssertNotNil(draft.errorMessage)
        owner.current = false
        draft.save()
        await settle()
        XCTAssertEqual(writes, 1)
    }

    // Implements: FR-ORG-4
    @MainActor func testSuccessfulRefreshDisplaysObservedStatusWithoutChangingDraftSelection() async throws {
        _ = NSApplication.shared
        let observed = try ClaudeOrganizationSelection(uuid: secondUUID, name: "Observed team")
        let refreshed = AccountOrganizationState(selection: nil, observed: observed, verification: .unbound,
                                                  checkedAt: Date(timeIntervalSince1970: 1), bindingID: "")
        let draft = AccountOrganizationDraft(profileID: "profile-A", state: nil, knownOrganizations: [],
            refresh: { _, _ in refreshed }, save: { _, _, _ in XCTFail("Refresh wrote selection") })
        let view = AccountOrganizationControlsView(draft: draft)
        view.refreshButton.performClick(nil)
        await settle()
        view.configure(draft: draft)
        XCTAssertEqual(draft.state, refreshed)
        XCTAssertTrue(draft.organizationUUID.isEmpty)
        XCTAssertEqual(view.configuredLabel.stringValue, "Unbound")
        XCTAssertTrue(view.observedLabel.stringValue.contains("Observed team"))
        XCTAssertTrue(view.refreshButton.isEnabled)
        XCTAssertTrue(view.spinner.isHidden)
    }

    // Implements: FR-ORG-4
    @MainActor func testRefreshFailureRemainsEditableAndDoesNotDisplayRawProviderError() async throws {
        struct Failure: LocalizedError { var errorDescription: String? { "sensitive-provider-detail" } }
        let draft = AccountOrganizationDraft(profileID: "profile-A", state: nil, knownOrganizations: [],
            refresh: { _, _ in throw Failure() }, save: { _, _, _ in })
        draft.refresh()
        await settle()
        XCTAssertFalse(draft.isRefreshing)
        XCTAssertFalse(draft.isClosed)
        XCTAssertEqual(draft.errorMessage, "Organization refresh failed.")
    }

    // Implements: FR-ORG-4
    @MainActor func testNativeCompactLayoutContainsVisibleControlsInKnownAndManualModes() async throws {
        _ = NSApplication.shared
        let known = try ClaudeOrganizationSelection(uuid: firstUUID, name: "Team")
        let draft = AccountOrganizationDraft(profileID: "profile-A", state: nil, knownOrganizations: [known],
            refresh: { _, _ in nil }, save: { _, _, _ in })
        let view = AccountOrganizationControlsView(draft: draft)
        for manual in [false, true] {
            if manual { try select("other", in: view) }
            view.setFrameSize(view.intrinsicContentSize)
            view.layoutSubtreeIfNeeded()
            let controls = [view.organizationPopUp, view.refreshButton, view.cancelButton, view.saveButton]
                + (manual ? [view.uuidField, view.nameField] : []) as [NSControl]
            for control in controls {
                let frame = control.convert(control.bounds, to: view)
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
                XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Out of bounds: \(frame)")
            }
        }
    }

    // Implements: FR-ORG-4
    @MainActor func testNativeActionsPreserveMarkedTextUntilCompositionEnds() async throws {
        _ = NSApplication.shared
        let first = try ClaudeOrganizationSelection(uuid: firstUUID, name: "First team")
        let second = try ClaudeOrganizationSelection(uuid: secondUUID, name: "Second team")
        for action in ["choice", "refresh", "save", "cancel"] {
            var writes = 0, refreshes = 0, cancellations = 0
            let state = AccountOrganizationState(selection: first, bindingID: firstUUID)
            let draft = AccountOrganizationDraft(profileID: "profile-A", state: state, knownOrganizations: [first, second],
                refresh: { _, _ in refreshes += 1; return state },
                save: { _, _, _ in writes += 1 }, cancel: { cancellations += 1 })
            let view = AccountOrganizationControlsView(draft: draft)
            view.setFrameSize(view.intrinsicContentSize)
            let window = NSWindow(contentRect: NSRect(x: -14000, y: -14000, width: 460, height: 240),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let container = NSView(frame: window.contentLayoutRect)
            window.contentView = container
            container.addSubview(view)
            let editor = OrganizationControlsMarkedEditor(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            editor.string = "한"
            container.addSubview(editor)
            XCTAssertTrue(window.makeFirstResponder(editor))
            XCTAssertTrue(window.firstResponder === editor)
            func performAction() throws {
                switch action {
                case "choice": try select(second.uuid, in: view)
                case "refresh": view.refreshButton.performClick(nil)
                case "save": view.saveButton.performClick(nil)
                default: view.cancelButton.performClick(nil)
                }
            }
            try performAction()
            await settle()
            XCTAssertEqual(writes, 0, action)
            XCTAssertEqual(refreshes, 0, action)
            XCTAssertEqual(cancellations, 0, action)
            XCTAssertFalse(draft.isClosed, action)
            XCTAssertEqual(draft.organizationUUID, first.uuid, action)
            XCTAssertEqual(view.organizationPopUp.selectedItem?.representedObject as? String, first.uuid, action)
            XCTAssertEqual(editor.string, "한")

            editor.marked = false
            try performAction()
            await settle()
            switch action {
            case "choice": XCTAssertEqual(draft.organizationUUID, second.uuid)
            case "refresh": XCTAssertEqual(refreshes, 1)
            case "save": XCTAssertEqual(writes, 1); XCTAssertTrue(draft.isClosed)
            default: XCTAssertEqual(cancellations, 1); XCTAssertTrue(draft.isClosed)
            }
        }
    }

    // Implements: FR-ORG-4
    @MainActor func testReplacingNativeDraftInvalidatesPreviousRefreshWithoutCancelCallback() async throws {
        _ = NSApplication.shared
        var continuation: CheckedContinuation<AccountOrganizationState?, Error>?
        var cancellations = 0
        let first = AccountOrganizationDraft(profileID: "profile-A", state: nil, knownOrganizations: [],
            refresh: { _, _ in try await withCheckedThrowingContinuation { continuation = $0 } },
            save: { _, _, _ in }, cancel: { cancellations += 1 })
        let second = AccountOrganizationDraft(profileID: "profile-B", state: nil, knownOrganizations: [],
            refresh: { _, _ in nil }, save: { _, _, _ in })
        let view = AccountOrganizationControlsView(draft: first)
        view.refreshButton.performClick(nil)
        await settle()
        view.configure(draft: second)
        continuation?.resume(returning: AccountOrganizationState(selection: nil, observed: nil, verification: .unavailable,
                                                                 checkedAt: Date(), bindingID: ""))
        await settle()
        XCTAssertTrue(first.isClosed)
        XCTAssertNil(second.state)
        XCTAssertTrue(view.draft === second)
        XCTAssertEqual(cancellations, 0)
    }

    @MainActor private func select(_ id: String, in view: AccountOrganizationControlsView) throws {
        let item = try XCTUnwrap(view.organizationPopUp.itemArray.first { $0.representedObject as? String == id })
        view.organizationPopUp.select(item)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(view.organizationPopUp.action), to: view.organizationPopUp.target, from: view.organizationPopUp))
    }

    @MainActor private func settle() async { for _ in 0..<8 { await Task.yield() } }
}

@MainActor private final class OrganizationControlsOwnerFixture {
    var current = true
    var profileID = "profile-A"
}

@MainActor private final class OrganizationControlsMarkedEditor: NSTextView {
    var marked = true
    override func hasMarkedText() -> Bool { marked }
}
