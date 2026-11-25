import SafetyCore
import SwiftUI

/// Add, remove and list emergency contacts. Each new contact gets a text
/// saying they were added and what an alert means.
struct ContactsEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.server) private var server
    let header: String?

    @State private var name = ""
    @State private var phone = ""
    @State private var error: String?
    @State private var welcomeStatus: [UUID: String] = [:]

    var body: some View {
        List {
            if let header {
                Section {
                    Text(header).font(.subheadline)
                }
            }

            Section("Contacts") {
                if store.data.contacts.isEmpty {
                    Text("No contacts yet").foregroundStyle(.secondary)
                }
                ForEach(store.data.contacts) { contact in
                    HStack(spacing: 12) {
                        InitialsAvatar(name: contact.name, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(contact.name).font(.headline)
                                if contact.testConfirmed {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.good)
                                        .accessibilityLabel("Test confirmed")
                                }
                            }
                            Text(PhoneNumber.display(contact.phone)).font(.subheadline).foregroundStyle(.secondary)
                            if let status = welcomeStatus[contact.id] {
                                Text(status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in store.data.contacts.remove(atOffsets: offsets) }
            }

            if store.data.contacts.count < EmergencyContact.maximumCount {
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                    TextField("Mobile number", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Button(action: add) {
                        Label("Add contact", systemImage: "plus.circle.fill").font(.headline)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || phone.isEmpty)
                } header: {
                    Text("Add a contact")
                } footer: {
                    Text("They'll get a text saying you added them. Ask them to keep naloxone (Narcan) handy and know how to use it.")
                }
            }
        }
    }

    private func add() {
        guard let normalized = PhoneNumber.normalize(phone) else {
            error = "That doesn't look like a mobile number. Include the area code."
            return
        }
        guard !store.data.contacts.contains(where: { $0.phone == normalized }) else {
            error = "That number is already a contact."
            return
        }
        let contact = EmergencyContact(name: name.trimmingCharacters(in: .whitespacesAndNewlines), phone: normalized)
        store.data.contacts.append(contact)
        name = ""
        phone = ""
        error = nil
        sendWelcome(contact)
    }

    private func sendWelcome(_ contact: EmergencyContact) {
        guard server.isConfigured else {
            welcomeStatus[contact.id] = "Texting isn't set up in this build, so no welcome text was sent."
            return
        }
        welcomeStatus[contact.id] = "Sending welcome text…"
        let firstName = store.data.firstName
        Task { @MainActor in
            do {
                try await server.sendWelcome(firstName: firstName, contact: contact)
                welcomeStatus[contact.id] = "Welcome text sent"
            } catch {
                welcomeStatus[contact.id] = "Couldn't send the welcome text: \(error.localizedDescription)"
            }
        }
    }
}

/// Sends the clearly labeled test text and lets the person mark who got it.
struct TestAlertPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.server) private var server
    @State private var sending = false
    @State private var results: [String: ServerClient.SetupResult] = [:]
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("Send each contact a text marked TEST, then ask them if it arrived. This catches wrong numbers before you rely on Spotter.")
                    .font(.subheadline)
                Button {
                    send()
                } label: {
                    HStack {
                        Text(sending ? "Sending…" : "Send test text")
                        if sending { Spacer(); ProgressView() }
                    }
                }
                .disabled(sending || store.data.contacts.isEmpty)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }

            Section("Did they get it?") {
                ForEach($store.data.contacts) { $contact in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $contact.testConfirmed) {
                            VStack(alignment: .leading) {
                                Text(contact.name).font(.headline)
                                Text(PhoneNumber.display(contact.phone)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let result = results[contact.phone] {
                            Text(result.sent ? "Sent" : (result.error ?? "Not sent"))
                                .font(.caption)
                                .foregroundStyle(result.sent ? Color.secondary : Color.red)
                        }
                    }
                }
            }
        }
    }

    private func send() {
        guard server.isConfigured else {
            error = ServerClient.ServerError.notConfigured.localizedDescription
            return
        }
        sending = true
        error = nil
        let firstName = store.data.firstName
        let contacts = store.data.contacts
        Task { @MainActor in
            defer { sending = false }
            do {
                let list = try await server.sendTest(firstName: firstName, contacts: contacts)
                results = Dictionary(list.map { ($0.phone, $0) }, uniquingKeysWith: { a, _ in a })
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
