import SwiftUI
import ContactsUI
import Contacts

/// Presents `CNContactPickerViewController` to let the rider pick a single
/// postal address from one of their contacts.
///
/// `CNContactPickerViewController` runs out-of-process and must be *presented*
/// modally — it is not meant to be embedded as a view controller's content.
/// Putting it directly inside a SwiftUI `.sheet` makes the picker flash on
/// screen and immediately dismiss (so it only "sticks" on a second tap).
/// Instead this representable lives invisibly in the view hierarchy and
/// presents/dismisses the picker itself in response to `isPresented`.
///
/// The picker runs out-of-process, so the app needs no Contacts permission and
/// no `NSContactsUsageDescription`: only the address the rider explicitly taps
/// is handed back. Contacts without a postal address are disabled.
struct ContactAddressPicker: UIViewControllerRepresentable {
    /// Drives presentation; reset to dismiss the picker on selection or cancel.
    @Binding var isPresented: Bool

    /// Called with the contact's display name and the postal address the rider
    /// selected. Not called if the rider cancels.
    var onSelect: (String, CNPostalAddress) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, dismiss: { isPresented = false })
    }

    func makeUIViewController(context: Context) -> UIViewController {
        // An empty host that simply presents the picker on top of itself.
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        // Keep the latest callback in case the closure captured fresh state.
        context.coordinator.onSelect = onSelect

        if isPresented {
            // Present only once; ignore repeat update passes while it is up.
            guard context.coordinator.picker == nil else { return }

            let picker = CNContactPickerViewController()
            picker.delegate = context.coordinator
            // Show only postal addresses, and only allow contacts that actually
            // have one to be selected.
            picker.displayedPropertyKeys = [CNContactPostalAddressesKey]
            picker.predicateForEnablingContact = NSPredicate(format: "postalAddresses.@count > 0")
            // Tapping a contact opens its card instead of returning the whole
            // contact, so the rider drills in and taps a specific address.
            picker.predicateForSelectionOfContact = NSPredicate(value: false)
            context.coordinator.picker = picker

            // Present on the next runloop tick so the host is guaranteed to be
            // in the window hierarchy.
            DispatchQueue.main.async {
                host.present(picker, animated: true)
            }
        } else if let picker = context.coordinator.picker {
            // Binding was cleared elsewhere: tear down the presented picker.
            context.coordinator.picker = nil
            picker.dismiss(animated: true)
        }
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var onSelect: (String, CNPostalAddress) -> Void
        private let dismiss: () -> Void
        /// The picker currently on screen, if any. Held weakly because the
        /// presenting host retains it while it is displayed.
        weak var picker: CNContactPickerViewController?

        init(onSelect: @escaping (String, CNPostalAddress) -> Void, dismiss: @escaping () -> Void) {
            self.onSelect = onSelect
            self.dismiss = dismiss
        }

        /// Fires when the rider taps a single property — here, a postal address.
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            defer {
                self.picker = nil
                dismiss()
            }
            guard contactProperty.key == CNContactPostalAddressesKey,
                  let address = contactProperty.value as? CNPostalAddress else { return }
            // Do not read name keys unless they were fetched — see ContactLabel.
            onSelect(
                ContactLabel.name(from: contactProperty.contact, fallback: ContactLabel.mailingAddress(address)),
                address
            )
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            self.picker = nil
            dismiss()
        }
    }
}
