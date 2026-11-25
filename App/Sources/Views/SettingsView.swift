import SwiftUI

/// Set up once (by Brian). Business details appear at the top of every invoice.
struct SettingsView: View {
    @Environment(GmailClient.self) private var gmail
    @AppStorage(BusinessSettings.Key.name) private var name = ""
    @AppStorage(BusinessSettings.Key.recordEmail) private var recordEmail = ""
    @AppStorage("recorder.talkMeThrough") private var talkMeThrough = true
    @AppStorage(BusinessSettings.Key.owner) private var owner = ""
    @AppStorage(BusinessSettings.Key.address) private var address = ""
    @AppStorage(BusinessSettings.Key.phone) private var phone = ""
    @AppStorage(BusinessSettings.Key.email) private var email = ""
    @AppStorage(BusinessSettings.Key.terms) private var terms = ""
    @AppStorage(BusinessSettings.Key.tax) private var taxPercent = 0.0
    @AppStorage(BusinessSettings.Key.nextInvoice) private var nextInvoice = 1
    @State private var gmailError: String?
    private var mailDirectory = MailDirectoryStore.shared

    var body: some View {
        Form {
            Section("Gmail") {
                if let account = gmail.signedInEmail {
                    LabeledContent("Signed in as", value: account)
                    if UserDefaults.standard.bool(forKey: ContactLookup.needsSignInKey) {
                        Text("Sign out and sign in again so the app can look up client emails in your contacts and mail.")
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("Address book from sent mail",
                                   value: mailDirectory.isRefreshing ? "Updating…" : "\(mailDirectory.peopleCount) people")
                    Button("Update address book now") { Task { await mailDirectory.refresh() } }
                        .disabled(mailDirectory.isRefreshing)
                    Button("Sign out", role: .destructive) {
                        gmail.signOut()
                        mailDirectory.clear()
                    }
                } else {
                    Button("Sign in to Gmail") {
                        Task {
                            do {
                                try await gmail.signIn()
                                gmailError = nil
                                UserDefaults.standard.set(false, forKey: ContactLookup.needsSignInKey)
                                await MailDirectoryStore.shared.refresh()
                            }
                            catch { gmailError = error.localizedDescription }
                        }
                    }
                    .font(.title3.bold())
                }
                if let gmailError { Text(gmailError).foregroundStyle(.red) }
                Text("The app only creates drafts. Nothing is sent until you press Send in Gmail. It reads your contacts and mail only to find a client's email address.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Accounting") {
                NavigationLink {
                    ExportView()
                } label: {
                    Label("Export for accounting", systemImage: "tablecells")
                }
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

            Section {
                Toggle("Talk me through new jobs", isOn: $talkMeThrough)
            } header: {
                Text("Recording")
            } footer: {
                Text("When recording a new job, the phone asks out loud for the client, then the address, then the work.")
            }

            Section {
                TextField("Email for job records (optional)", text: $recordEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Job records")
            } footer: {
                Text("With each invoice, a second Gmail draft lists everything said about the job, so nothing is missed. It's addressed to this email, or to no one if blank. It never goes to the client.")
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
