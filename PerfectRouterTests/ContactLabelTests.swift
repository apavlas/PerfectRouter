import XCTest
import Contacts
@testable import PerfectRouter

/// Labeling for a contact returned by the picker. The crash this covers is
/// `CNContactPropertyNotFetchedException` when name keys were never fetched;
/// `CNMutableContact` has every key, so these tests lock the fallback order.
final class ContactLabelTests: XCTestCase {

    func testPrefersFullNameOverOrganizationAndFallback() {
        let contact = CNMutableContact()
        contact.givenName = "John"
        contact.familyName = "Appleseed"
        contact.organizationName = "Apple"

        XCTAssertEqual(ContactLabel.name(from: contact, fallback: "1 Infinite Loop"), "John Appleseed")
    }

    func testUsesOrganizationWhenNameIsEmpty() {
        let contact = CNMutableContact()
        contact.organizationName = "Apple Park"

        XCTAssertEqual(ContactLabel.name(from: contact, fallback: "1 Infinite Loop"), "Apple Park")
    }

    func testUsesFallbackWhenNameAndOrganizationAreEmpty() {
        let contact = CNMutableContact()

        XCTAssertEqual(ContactLabel.name(from: contact, fallback: "1 Infinite Loop, Cupertino"), "1 Infinite Loop, Cupertino")
    }

    func testIgnoresWhitespaceOnlyNameAndOrganization() {
        let contact = CNMutableContact()
        contact.givenName = "  "
        contact.familyName = "\n"
        contact.organizationName = "   "

        XCTAssertEqual(ContactLabel.name(from: contact, fallback: "fallback"), "fallback")
    }

    func testUsesContactWhenNameOrganizationAndFallbackAreEmpty() {
        let contact = CNMutableContact()
        XCTAssertEqual(ContactLabel.name(from: contact, fallback: ""), "Contact")
        XCTAssertEqual(ContactLabel.name(from: contact, fallback: "  "), "Contact")
        XCTAssertEqual(ContactLabel.name(from: contact), "Contact")
    }

    func testMailingAddressJoinsLines() {
        let address = CNMutablePostalAddress()
        address.street = "1 Infinite Loop"
        address.city = "Cupertino"
        address.state = "CA"
        address.postalCode = "95014"

        let formatted = ContactLabel.mailingAddress(address)
        XCTAssertFalse(formatted.contains("\n"))
        XCTAssertTrue(formatted.contains("1 Infinite Loop"))
        XCTAssertTrue(formatted.contains("Cupertino"))
    }

    func testEmptyPostalAddressFormatsToEmptyString() {
        XCTAssertEqual(ContactLabel.mailingAddress(CNMutablePostalAddress()), "")
    }
}
