import Contacts

/// Builds a rider-facing label from a contact the out-of-process picker returns.
///
/// `CNContactPickerViewController` only populates `displayedPropertyKeys`
/// (postal addresses or phone numbers here). Reading any other key — including
/// through `CNContactFormatter` — raises `CNContactPropertyNotFetchedException`,
/// an Objective-C exception Swift cannot catch. Every property access is
/// therefore gated with `isKeyAvailable` / `areKeysAvailable`.
enum ContactLabel {
    /// Prefers a formatted full name, then given + family, then organization,
    /// then `fallback` (labeled address or phone). Empty fallback becomes
    /// `"Contact"` so a waypoint always has a label.
    static func name(from contact: CNContact, fallback: String = "Contact") -> String {
        if contact.areKeysAvailable([CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]),
           let formatted = CNContactFormatter.string(from: contact, style: .fullName) {
            let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        var parts: [String] = []
        if contact.isKeyAvailable(CNContactGivenNameKey) {
            let given = contact.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !given.isEmpty { parts.append(given) }
        }
        if contact.isKeyAvailable(CNContactFamilyNameKey) {
            let family = contact.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !family.isEmpty { parts.append(family) }
        }
        if !parts.isEmpty { return parts.joined(separator: " ") }

        if contact.isKeyAvailable(CNContactOrganizationNameKey) {
            let org = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !org.isEmpty { return org }
        }

        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? "Contact" : trimmedFallback
    }

    /// One-line mailing address for a waypoint label or geocode query.
    static func mailingAddress(_ address: CNPostalAddress) -> String {
        CNPostalAddressFormatter.string(from: address, style: .mailingAddress)
            .replacingOccurrences(of: "\n", with: ", ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
