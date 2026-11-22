import SwiftUI

/// Set up once (by Brian). Business details appear at the top of every invoice.
struct SettingsView: View {
    @Environment(GmailClient.self) private var gmail
    @AppStorage(BusinessSettings.Key.name) private var name = ""
    @AppStorage(BusinessSettings.Key.owner) private var owner = ""
    @AppStorage(BusinessSettings.Key.address) private var address = ""
    @AppStorage(BusinessSettings.Key.phone) private var phone = ""
    @AppStorage(BusinessSettings.Key.email) private var email = ""
    @AppStorage(BusinessSettings.Key.terms) private var terms = ""
    @AppStorage(BusinessSettings.Key.tax) private var taxPercent = 0.0
    @AppStorage(BusinessSettings.Key.nextInvoice) private var nextInvoice = 1
    @State private var gmailError: String?

    var body: some View {
        Form {
            Section("Gmail") {
                if let account = gmail.signedInEmail {
                    LabeledContent("Signed in as", value: account)
                    Button("Sign out", role: .destructive) { gmail.signOut() }
                } else {
                    Button("Sign in to Gmail") {
                        Task {
                            do { try await gmail.signIn(); gmailError = nil }
                            catch { gmailError = error.localizedDescription }
                        }
                    }
                    .font(.title3.bold())
                }
                if let gmailError { Text(gmailError).foregroundStyle(.red) }
                Text("The app only creates drafts. Nothing is sent until you press Send in Gmail.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Business") {
                TextField("Business name", text: $name)
                TextField("Your name", text: $owner)
                TextField("Address", text: $address, axis: .vertical)
                TextField("Phone", text: $phone).keyboardType(.phonePad)
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
            }

            Section("Invoices") {
                Stepper("Next invoice number: \(nextInvoice)", value: $nextInvoice, in: 1...999_999)
                HStack {
                    Text("Sales tax %")
                    TextField("0", value: $taxPercent, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                TextField("Payment terms, e.g. Due within 30 days", text: $terms, axis: .vertical)
            }
        }
        .navigationTitle("Settings")
    }
}
