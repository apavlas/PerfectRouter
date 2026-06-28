import SwiftUI

/// Lets the rider create and manage named groups of riding buddies, each built
/// from contacts. Groups are reused when sharing a ride so the rider can invite
/// a whole crew in one tap.
struct RiderGroupsView: View {
    @Bindable var viewModel: RoutePlannerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingNewGroupDialog = false
    @State private var newGroupName = ""

    var body: some View {
        NavigationStack {
            List {
                if viewModel.riderGroups.isEmpty {
                    ContentUnavailableView {
                        Label("No Rider Groups", systemImage: "person.2")
                    } description: {
                        Text("Create a group of riding buddies so you can share a ride with the whole crew at once.")
                    } actions: {
                        Button("New Group") { startNewGroup() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Section {
                        ForEach(viewModel.riderGroups) { group in
                            NavigationLink {
                                RiderGroupDetailView(viewModel: viewModel, groupID: group.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name)
                                    Text(group.memberSummary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { viewModel.deleteRiderGroups(at: $0) }
                    } footer: {
                        Text("Riders are stored only on this device.")
                    }
                }
            }
            .navigationTitle("Rider Groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { startNewGroup() } label: {
                        Label("New Group", systemImage: "plus")
                    }
                }
            }
            .alert("New Group", isPresented: $showingNewGroupDialog) {
                TextField("Group name", text: $newGroupName)
                Button("Cancel", role: .cancel) { }
                Button("Create") { viewModel.createRiderGroup(name: newGroupName) }
            } message: {
                Text("Name this group of riders, then add people from your contacts.")
            }
        }
    }

    private func startNewGroup() {
        newGroupName = ""
        showingNewGroupDialog = true
    }
}

/// Shows the riders in a single group and lets the rider rename it, add people
/// from contacts, or remove them. Works off the group's id so edits always read
/// the live copy from the view model.
struct RiderGroupDetailView: View {
    @Bindable var viewModel: RoutePlannerViewModel
    let groupID: UUID

    @State private var showingContactPicker = false
    @State private var showingRenameDialog = false
    @State private var renameText = ""

    private var group: RiderGroup? { viewModel.riderGroup(id: groupID) }

    var body: some View {
        List {
            if let group {
                Section("Riders") {
                    if group.riders.isEmpty {
                        Text("No riders yet. Add people from your contacts.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(group.riders) { rider in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rider.name)
                            Text(rider.phoneNumber)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { viewModel.removeRiders(at: $0, fromGroup: groupID) }
                }

                Section {
                    Button {
                        showingContactPicker = true
                    } label: {
                        Label("Add Rider from Contacts", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            } else {
                // The group was deleted out from under this view.
                ContentUnavailableView("Group Unavailable", systemImage: "person.2.slash")
            }
        }
        .navigationTitle(group?.name ?? "Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if group != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Rename") {
                        renameText = group?.name ?? ""
                        showingRenameDialog = true
                    }
                }
            }
        }
        .alert("Rename Group", isPresented: $showingRenameDialog) {
            TextField("Group name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Save") { viewModel.renameRiderGroup(id: groupID, to: renameText) }
        }
        .background(
            // Invisible host that presents the contacts picker out-of-process.
            ContactPhonePicker(isPresented: $showingContactPicker) { name, phone in
                viewModel.addRider(Rider(name: name, phoneNumber: phone), toGroup: groupID)
            }
        )
    }
}
