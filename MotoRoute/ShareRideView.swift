import SwiftUI

/// The sheet shown when the rider shares a planned ride. Lets them pick a saved
/// rider group to message in one tap (pre-addressed Messages composer), or fall
/// back to the system share sheet for any other channel (Mail, AirDrop, etc.).
struct ShareRideView: View {
    @Bindable var viewModel: RoutePlannerViewModel
    @Environment(\.dismiss) private var dismiss

    /// The group whose riders the Messages composer is being opened for.
    @State private var composingGroup: RiderGroup?
    @State private var showingManageGroups = false

    private var shareURL: URL? { viewModel.sharedRoute.shareURL }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.defaultRouteName)
                            .font(.headline)
                        Text(viewModel.sharedRoute.shareMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ridersSection

                Section {
                    if let shareURL {
                        ShareLink(
                            item: shareURL,
                            subject: Text("MotoRoute Ride"),
                            message: Text(viewModel.sharedRoute.shareMessage)
                        ) {
                            Label("Share via…", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        showingManageGroups = true
                    } label: {
                        Label("Manage Rider Groups", systemImage: "person.2")
                    }
                } footer: {
                    Text("Use Share via… for Mail, AirDrop, or any other app.")
                }
            }
            .navigationTitle("Share Ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $composingGroup) { group in
                MessageComposer(
                    recipients: group.phoneNumbers,
                    body: viewModel.rideInviteMessage()
                ) {
                    composingGroup = nil
                    dismiss()
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingManageGroups) {
                RiderGroupsView(viewModel: viewModel)
            }
        }
    }

    @ViewBuilder
    private var ridersSection: some View {
        Section {
            if viewModel.riderGroups.isEmpty {
                Button {
                    showingManageGroups = true
                } label: {
                    Label("Create a Rider Group", systemImage: "person.crop.circle.badge.plus")
                }
            } else {
                ForEach(viewModel.riderGroups) { group in
                    Button {
                        composingGroup = group
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name)
                                    .foregroundStyle(.primary)
                                Text(group.memberSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "message.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                    .disabled(group.riders.isEmpty || !MessageComposer.canSendText)
                }
            }
        } header: {
            Text("Message a Rider Group")
        } footer: {
            if !MessageComposer.canSendText {
                Text("Messaging isn't available on this device. Use Share via… below instead.")
            } else {
                Text("Pre-fills a message to everyone in the group with a link to this ride.")
            }
        }
    }
}
