import XCTest

#if canImport(SGSimpleSettings)
import SGSimpleSettings
#endif

final class ExteraAdminShortcutPolicyTests: XCTestCase {
    private typealias Policy = ExteraAdminShortcutPolicy

    private func actions(_ actor: Policy.Actor = .owner, target: Policy.Target = .member, kind: Policy.GroupKind = .supergroup, enabled: Bool = true, isSelf: Bool = false) -> [Policy.Action] {
        return Policy.actions(enabled: enabled, kind: kind, actor: actor, target: target, isSelf: isSelf)
    }

    func testDisabledPreferenceSuppressesEvenOwnerActions() {
        XCTAssertEqual(self.actions(enabled: false), [])
    }

    func testPrivateBroadcastAndUnsupportedLocationsHaveNoActions() {
        XCTAssertEqual(self.actions(kind: .unsupported), [])
    }

    func testMissingServerActorAndOrdinaryViewersHaveNoActions() {
        XCTAssertEqual(self.actions(.unknown), [])
        XCTAssertEqual(self.actions(.member), [])
        XCTAssertEqual(self.actions(.administrator([])), [])
    }

    func testSelfIsNeverAModerationTarget() {
        for kind in [Policy.GroupKind.legacyGroup, .supergroup] {
            XCTAssertEqual(self.actions(kind: kind, isSelf: true), [])
        }
    }

    func testOwnerAdminRemovedAndUnknownTargetsAreExcludedForEveryRightsCombination() {
        for target in Policy.Target.allCases where target != .member {
            for kind in [Policy.GroupKind.legacyGroup, .supergroup] {
                XCTAssertEqual(self.actions(target: target, kind: kind), [])
                for rawRights in 0 ..< 8 {
                    XCTAssertEqual(self.actions(.administrator(Policy.Rights(rawValue: rawRights)), target: target, kind: kind), [])
                }
            }
        }
    }

    func testBanPermissionCannotGrantPromotionOrHistoryDeletion() {
        XCTAssertEqual(self.actions(.administrator(.banMembers)), [.restrict, .ban])
    }

    func testAddAdminsPermissionCannotGrantBanOrDeletion() {
        XCTAssertEqual(self.actions(.administrator(.addAdmins)), [.promote])
    }

    func testDeletePermissionDoesNotRequireOrGrantBan() {
        XCTAssertEqual(self.actions(.administrator(.deleteMessages)), [.deleteMessages])
    }

    func testCombinedPermissionsRemainIndependent() {
        XCTAssertEqual(self.actions(.administrator([.banMembers, .addAdmins])), [.promote, .restrict, .ban])
        XCTAssertEqual(self.actions(.administrator([.addAdmins, .deleteMessages])), [.promote, .deleteMessages])
        XCTAssertEqual(self.actions(.administrator([.banMembers, .deleteMessages])), [.restrict, .ban, .deleteMessages])
    }

    func testSupergroupOwnerAndFullAdminGetFourNativeActionsInStableOrder() {
        let expected: [Policy.Action] = [.promote, .restrict, .ban, .deleteMessages]
        XCTAssertEqual(self.actions(), expected)
        XCTAssertEqual(self.actions(.administrator([.banMembers, .addAdmins, .deleteMessages])), expected)
    }

    func testLegacyGroupOwnerHasOnlySupportedActions() {
        XCTAssertEqual(self.actions(kind: .legacyGroup), [.promote, .removeMember])
    }

    func testLegacyGroupAdminCannotPromoteOrClearAuthorHistory() {
        XCTAssertEqual(self.actions(.administrator([.banMembers, .addAdmins, .deleteMessages]), kind: .legacyGroup), [.removeMember])
        XCTAssertEqual(self.actions(.administrator([.addAdmins, .deleteMessages]), kind: .legacyGroup), [])
    }

    func testRevokedRightsAndPromotedTargetInvalidatePreviouslyOfferedAction() {
        XCTAssertTrue(self.actions(.administrator(.banMembers)).contains(.ban))
        XCTAssertFalse(self.actions(.member).contains(.ban))
        XCTAssertFalse(self.actions(.administrator(.deleteMessages)).contains(.ban))
        XCTAssertFalse(self.actions(target: .administrator).contains(.ban))
        XCTAssertFalse(self.actions(target: .owner).contains(.deleteMessages))
        XCTAssertFalse(self.actions(.unknown).contains(.deleteMessages))
    }

    func testUnknownFutureRightsDoNotGrantAnyAction() {
        XCTAssertEqual(self.actions(.administrator(Policy.Rights(rawValue: 1 << 12))), [])
    }
}
