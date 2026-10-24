//
//  FocusedFieldEditabilityTests.swift
//  OpenClickyTests
//
//  Which focused element counts as a text box for a take. A Chrome page with nothing clicked
//  reports the page itself (AXWebArea) as focused; counted as a box, a take sent ⌘V into the page
//  and put the old clipboard back, so the words were lost (2026-10-23).
//

import Testing
@testable import OpenClicky

struct FocusedFieldEditabilityTests {
    @Test func aPageWithNothingClickedIsNotATextBox() {
        #expect(!FocusedFieldReader.isEditable(role: "AXWebArea", valueIsSettable: false, hasEditableAncestor: false))
    }

    @Test func anEditablePageStillIs() {
        // A document in design mode, or a page inside an editable region.
        #expect(FocusedFieldReader.isEditable(role: "AXWebArea", valueIsSettable: true, hasEditableAncestor: false))
        #expect(FocusedFieldReader.isEditable(role: "AXWebArea", valueIsSettable: false, hasEditableAncestor: true))
    }

    @Test func textRolesAreBoxesAndOthersNeedEvidence() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            #expect(FocusedFieldReader.isEditable(role: role, valueIsSettable: false, hasEditableAncestor: false), "\(role)")
        }
        #expect(!FocusedFieldReader.isEditable(role: "AXGroup", valueIsSettable: false, hasEditableAncestor: false))
        #expect(FocusedFieldReader.isEditable(role: "AXGroup", valueIsSettable: false, hasEditableAncestor: true))
        #expect(!FocusedFieldReader.isEditable(role: "AXButton", valueIsSettable: true, hasEditableAncestor: true))
        #expect(!FocusedFieldReader.isEditable(role: nil, valueIsSettable: true, hasEditableAncestor: true))
    }
}
