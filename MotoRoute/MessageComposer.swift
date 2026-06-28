import SwiftUI
import MessageUI

/// Presents the native Messages composer pre-addressed to a set of riders with
/// the shared-route link already in the body, so the rider can fire off a ride
/// invite to a whole group in one step.
///
/// `MFMessageComposeViewController` is a system view controller meant to be
/// presented modally; here it's hosted directly as SwiftUI `.sheet` content,
/// which presents it for us. Call `MessageComposer.canSendText` before
/// presenting — it is `false` on the Simulator and on devices without iMessage
/// or SMS configured.
struct MessageComposer: UIViewControllerRepresentable {
    /// Phone numbers to pre-address the message to.
    let recipients: [String]
    /// The message body (route summary plus the `motoroute://` link).
    let body: String
    /// Called when the composer is dismissed (sent, cancelled, or failed).
    var onFinish: () -> Void

    /// Whether this device can send a text message at all.
    static var canSendText: Bool { MFMessageComposeViewController.canSendText() }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = context.coordinator
        composer.recipients = recipients
        composer.body = body
        return composer
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {
        // The composer is configured once at creation; nothing to update.
    }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            onFinish()
        }
    }
}
