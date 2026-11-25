import XCTest

#if canImport(SGSimpleSettings)
import SGSimpleSettings
#endif

final class ExteraAdminHeaderPolicyTests: XCTestCase {
    private typealias Policy = ExteraAdminHeaderPolicy

    private func entries(kind: Policy.Kind = .supergroup, role: Policy.Role = .owner, enabled: Bool = true, isMember: Bool = true, isMonoforum: Bool = false) -> [Policy.Entry] {
        return Policy.entries(enabled: enabled, kind: kind, role: role, isMember: isMember, isMonoforum: isMonoforum)
    }

    func testSwitchDisablesAllFourDestinations() {
        for kind in Policy.Kind.allCases {
            XCTAssertEqual(self.entries(kind: kind, enabled: false), [])
        }
    }

    func testOrdinaryViewerAndUnknownServerRoleHaveNoAdminSections() {
        for kind in Policy.Kind.allCases {
            XCTAssertEqual(self.entries(kind: kind, role: .member), [])
            XCTAssertEqual(self.entries(kind: kind, role: .unknown), [])
        }
    }

    func testLegacyPrivateAndUnsupportedPeersMatchAndroidExclusion() {
        XCTAssertEqual(self.entries(kind: .legacyGroup), [])
        XCTAssertEqual(self.entries(kind: .unsupported), [])
    }

    func testSupergroupOwnerGetsOriginalFourActionsInAndroidOrder() {
        XCTAssertEqual(self.entries().map(\.action), [.permissions, .administrators, .members, .recentActions])
        XCTAssertEqual(self.entries().map(\.destination), [.groupPermissions, .administrators, .members, .recentActions])
    }

    func testAdministratorCanViewSectionsWithoutBeingGrantedMutationRights() {
        // Native PeerInfo uses the admin role for section visibility, including admins who cannot
        // add admins/ban members. The destination controllers retain their per-operation gates.
        for kind in [Policy.Kind.supergroup, .broadcast, .gigagroup] {
            XCTAssertEqual(self.entries(kind: kind, role: .administrator), self.entries(kind: kind, role: .owner))
        }
    }

    func testBroadcastPermissionsSlotOpensRemovedUsersRatherThanGroupPermissions() {
        XCTAssertEqual(self.entries(kind: .broadcast).first, Policy.Entry(action: .permissions, destination: .removedUsers))
        XCTAssertEqual(self.entries(kind: .broadcast).count, 4)
    }

    func testGigagroupPermissionsSlotMatchesAndroidBannedListRoute() {
        XCTAssertEqual(self.entries(kind: .gigagroup).first, Policy.Entry(action: .permissions, destination: .removedUsers))
        XCTAssertEqual(self.entries(kind: .gigagroup).map(\.action), [.permissions, .administrators, .members, .recentActions])
    }

    func testMonoforumAndNonmemberExcludeEvenCachedOwnersAndAdmins() {
        for kind in Policy.Kind.allCases {
            for role in Policy.Role.allCases {
                XCTAssertEqual(self.entries(kind: kind, role: role, isMonoforum: true), [])
                XCTAssertEqual(self.entries(kind: kind, role: role, isMember: false), [])
            }
        }
    }

    func testRevokedAdminRoleOrFailedRecheckInvalidatesOfferedRoutes() {
        let offered = self.entries(role: .administrator)
        XCTAssertEqual(offered.count, 4)
        for entry in offered {
            XCTAssertFalse(self.entries(role: .member).contains(entry))
            XCTAssertFalse(self.entries(role: .unknown).contains(entry))
            XCTAssertFalse(self.entries(enabled: false).contains(entry))
        }
    }

    func testConversionCannotSilentlyChangeAnAlreadySelectedPermissionsDestination() {
        let selected = self.entries().first!
        XCTAssertFalse(self.entries(kind: .gigagroup).contains(selected))
        XCTAssertTrue(self.entries(kind: .gigagroup).contains(Policy.Entry(action: .permissions, destination: .removedUsers)))
    }
}
