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

    /// Riders picked just for this ride, without saving a group.
    @State private var adHocRiders: [Rider] = []
    @State private var showingAdHocPicker = false
    @State private var showingSaveGroupDialog = false
    @State private var saveGroupName = ""

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

                adHocSection

                Section {
                    if let shareURL {
                        ShareLink(
                            item: shareURL,
                            subject: Text("PerfectRouter Ride"),
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
            .alert("Save as Group", isPresented: $showingSaveGroupDialog) {
                TextField("Group name", text: $saveGroupName)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    let group = viewModel.createRiderGroup(name: saveGroupName)
                    for rider in adHocRiders {
                        viewModel.addRider(rider, toGroup: group.id)
                    }
                }
            } message: {
                Text("Save these riders as a group so you can reuse them next time.")
            }
            .background(
                // Invisible host that presents the contacts picker out-of-process.
                ContactPhonePicker(isPresented: $showingAdHocPicker) { name, phone in
                    addAdHocRider(name: name, phone: phone)
                }
            )
        }
    }

    /// A one-off list of riders to message for just this ride, plus the option
    /// to save them as a reusable group.
    @ViewBuilder
    private var adHocSection: some View {
        Section {
            ForEach(adHocRiders) { rider in
                VStack(alignment: .leading, spacing: 2) {
                    Text(rider.name)
                    Text(rider.phoneNumber)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { adHocRiders.remove(atOffsets: $0) }

            Button {
                showingAdHocPicker = true
            } label: {
                Label("Add Person from Contacts", systemImage: "person.crop.circle.badge.plus")
            }

            if !adHocRiders.isEmpty {
                Button {
                    composingGroup = RiderGroup(name: "Selected Riders", riders: adHocRiders)
                } label: {
                    Label("Message These Riders", systemImage: "message.fill")
                }
                .disabled(!MessageComposer.canSendText)

                Button {
                    saveGroupName = ""
                    showingSaveGroupDialog = true
                } label: {
                    Label("Save as Group", systemImage: "square.and.arrow.down")
                }
            }
        } header: {
            Text("Message Specific People")
        } footer: {
            Text("Pick people just for this ride — no group needed.")
        }
    }

    /// Appends a picked contact, skipping exact duplicate numbers.
    private func addAdHocRider(name: String, phone: String) {
        let normalized = phone.filter(\.isNumber)
        guard !adHocRiders.contains(where: { $0.phoneNumber.filter(\.isNumber) == normalized }) else { return }
        adHocRiders.append(Rider(name: name, phoneNumber: phone))
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
