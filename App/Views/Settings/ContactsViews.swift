import SafetyCore
import SwiftUI

/// Name and number fields with an Add button. Sends the new contact a
/// "you've been added" text in the background.
struct AddContactForm: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.server) private var server
    @State private var name = ""
    @State private var phone = ""
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case name, phone }

    var body: some View {
        VStack(spacing: 10) {
            TextField("Name", text: $name)
                .textContentType(.name)
                .submitLabel(.next)
                .focused($focus, equals: .name)
                .onSubmit { focus = .phone }
                .fieldStyle()
            TextField("Mobile number", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .focused($focus, equals: .phone)
                .fieldStyle()
            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: add) {
                Label("Add", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || phone.isEmpty)
        }
    }

    private func add() {
        guard let normalized = PhoneNumber.normalize(phone) else {
            error = "Check the number, including area code."
            return
        }
        guard !store.data.contacts.contains(where: { $0.phone == normalized }) else {
            error = "Already added."
            return
        }
        let contact = EmergencyContact(name: name.trimmingCharacters(in: .whitespacesAndNewlines), phone: normalized)
        withAnimation { store.data.contacts.append(contact) }
        name = ""
        phone = ""
        error = nil
        focus = nil

        guard server.isConfigured else { return }
        let firstName = store.data.firstName
        let server = self.server
        Task { try? await server.sendWelcome(firstName: firstName, contact: contact) }
    }
}

/// One contact: initials, name, and a remove button.
struct ContactRow: View {
    let contact: EmergencyContact
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            InitialsAvatar(name: contact.name, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.name).font(.headline)
                Text(PhoneNumber.display(contact.phone)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(contact.name)")
            }
        }
    }
}

/// Contacts screen in Settings.
struct ContactsEditor: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            Section {
                ForEach(store.data.contacts) { contact in
                    ContactRow(contact: contact)
                }
                .onDelete { store.data.contacts.remove(atOffsets: $0) }
            }
            if store.data.contacts.count < EmergencyContact.maximumCount {
                Section("Add") {
                    AddContactForm()
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
        }
        .navigationTitle("Contacts")
    }
}

/// Sends the TEST text, then lets the person tick who got it.
struct TestTextPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.server) private var server
    @Binding var sent: Bool
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 12) {
            ForEach($store.data.contacts) { $contact in
                HStack(spacing: 12) {
                    InitialsAvatar(name: contact.name, size: 40)
                    Text(contact.name).font(.headline)
                    Spacer()
                    if sent {
                        Toggle("Got it", isOn: $contact.testConfirmed)
                            .labelsHidden()
                            .accessibilityLabel("\(contact.name) got it")
                    }
                }
                .card(padding: 12)
            }
            if sent {
                Text("Turn on each person who got it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
            }
            if !sent {
                Button(action: send) {
                    HStack {
                        if sending { ProgressView() }
                        Text(sending ? "Sending" : "Send test text")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .disabled(sending || store.data.contacts.isEmpty)
            }
        }
    }

    private func send() {
        guard server.isConfigured else {
            error = "Texting isn't set up yet."
            return
        }
        sending = true
        error = nil
        let firstName = store.data.firstName
        let contacts = store.data.contacts
        Task { @MainActor in
            defer { sending = false }
            do {
                let results = try await server.sendTest(firstName: firstName, contacts: contacts)
                if let failed = results.first(where: { !$0.sent }) { error = failed.error ?? "Some texts didn't send. Check the numbers." }
                withAnimation { sent = true }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension View {
    /// Plain rounded text field look used in setup.
    func fieldStyle() -> some View {
        self
            .font(.body)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
