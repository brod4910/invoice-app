import XCTest
@testable import InvoiceCore

final class MoneyTests: XCTestCase {
    func testFormat() {
        XCTAssertEqual(Money.format(cents: 12345), "$123.45")
        XCTAssertEqual(Money.format(cents: 0), "$0.00")
    }

    func testParse() {
        XCTAssertEqual(Money.parseCents("120"), 12000)
        XCTAssertEqual(Money.parseCents("$1,200.50"), 120050)
        XCTAssertEqual(Money.parseCents("45.5"), 4550)
        XCTAssertNil(Money.parseCents(""))
        XCTAssertNil(Money.parseCents("abc"))
    }

    func testLineTotal() {
        XCTAssertEqual(Money.lineTotal(quantity: 2.5, unitPriceCents: 4000), 10000)
    }
}

final class ExtractionTests: XCTestCase {
    func testDecodesProxyJSON() throws {
        let json = """
        {"client_name":"Mary Johnson","client_email":"mary@example.com","client_phone":null,
         "job_address":"12 Oak St","job_title":"Fence repair",
         "items":[{"description":"Replace fence boards","quantity":12,"unit_price_cents":1500,"details":"Cedar"},
                  {"description":"Haul away debris","quantity":1,"unit_price_cents":null,"details":null}],
         "notes":null}
        """
        let result = try ExtractionDecoding.decode(Data(json.utf8))
        XCTAssertEqual(result.clientName, "Mary Johnson")
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items[0].unitPriceCents, 1500)
        XCTAssertNil(result.items[1].unitPriceCents)
    }

    func testEncodesRequestSnakeCase() throws {
        let data = try JSONEncoder().encode(ExtractionRequest(transcript: "hi", existingItems: ["a"], knownClients: ["b"]))
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("existing_items"))
        XCTAssertTrue(s.contains("known_clients"))
    }
}

final class ClientMatchingTests: XCTestCase {
    func testExactAndPartial() {
        let known = ["Mary Johnson", "Bob's Diner", "Tom Lee"]
        XCTAssertEqual(ClientMatching.bestMatch(for: "mary johnson", in: known), 0)
        XCTAssertEqual(ClientMatching.bestMatch(for: "Bobs Diner", in: known), nil) // "bob s" vs "bobs" differ
        XCTAssertEqual(ClientMatching.bestMatch(for: "Bob's diner", in: known), 1)
        XCTAssertEqual(ClientMatching.bestMatch(for: "Johnson", in: known), 0)
        XCTAssertNil(ClientMatching.bestMatch(for: "Smith", in: known))
    }

    func testAmbiguousPartialReturnsNil() {
        XCTAssertNil(ClientMatching.bestMatch(for: "Lee", in: ["Tom Lee", "Ann Lee"]))
    }
}

final class DuplicateDetectionTests: XCTestCase {
    func testSameClientSameDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let morning = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 9))!
        let afternoon = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15))!
        let nextDay = cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 9))!
        let a = JobFingerprint(id: UUID(), clientName: "Mary Johnson", jobDate: morning)
        let b = JobFingerprint(id: UUID(), clientName: "mary  johnson", jobDate: afternoon)
        let c = JobFingerprint(id: UUID(), clientName: "Mary Johnson", jobDate: nextDay)
        let d = JobFingerprint(id: UUID(), clientName: nil, jobDate: morning)
        let pairs = DuplicateDetection.likelyDuplicates([b, c, a, d], calendar: cal)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].keep, a.id)
        XCTAssertEqual(pairs[0].mergeIn, b.id)
    }
}

final class InvoiceTests: XCTestCase {
    func makeDoc(tax: Double = 0) -> InvoiceDocument {
        InvoiceDocument(
            number: 7,
            date: Date(timeIntervalSince1970: 1_795_000_000),
            business: BusinessInfo(name: "Smith Handyman", ownerName: "Joe Smith", phone: "555-0100", taxRatePercent: tax),
            clientName: "Mary <Johnson>",
            clientEmail: "mary@example.com",
            jobTitle: "Fence repair",
            lines: [
                InvoiceLine(description: "Boards", details: "Cedar", quantity: 12, unitPriceCents: 1500),
                InvoiceLine(description: "Labor", quantity: 2.5, unitPriceCents: 6000),
            ]
        )
    }

    func testTotals() {
        let doc = makeDoc(tax: 8.25)
        XCTAssertEqual(doc.subtotalCents, 33000)
        XCTAssertEqual(doc.taxCents, 2723)
        XCTAssertEqual(doc.totalCents, 35723)
        XCTAssertEqual(doc.subject, "Invoice #0007 from Smith Handyman")
    }

    func testHTMLEscapesAndIncludesTotals() {
        let html = InvoiceRenderer.html(makeDoc())
        XCTAssertTrue(html.contains("Mary &lt;Johnson&gt;"))
        XCTAssertFalse(html.contains("<Johnson>"))
        XCTAssertTrue(html.contains("$330.00"))
        XCTAssertFalse(html.contains("Subtotal")) // no tax -> single total row
    }

    func testCoverNote() {
        var doc = makeDoc()
        doc.business.paymentTerms = "Due within 30 days."
        let note = InvoiceRenderer.coverNoteText(doc)
        XCTAssertTrue(note.hasPrefix("Hello Mary,"))
        XCTAssertTrue(note.contains("Attached is invoice #0007 for $330.00 for fence repair."))
        XCTAssertTrue(note.contains("Due within 30 days."))
        XCTAssertTrue(note.contains("Joe Smith"))
        XCTAssertEqual(doc.pdfFilename, "Invoice-0007.pdf")
    }

    func testPlainText() {
        let text = InvoiceRenderer.plainText(makeDoc())
        XCTAssertTrue(text.contains("INVOICE #0007"))
        XCTAssertTrue(text.contains("Labor: 2.50 x $60.00 = $150.00"))
        XCTAssertTrue(text.contains("Total due: $330.00"))
    }
}

final class MIMETests: XCTestCase {
    func testStructure() {
        let raw = MIMEMessage.build(to: "a@b.com", subject: "Invoice #0001", html: "<b>hi</b>", text: "hi", boundary: "XYZ")
        XCTAssertTrue(raw.hasPrefix("To: a@b.com\r\nSubject: Invoice #0001\r\n"))
        XCTAssertTrue(raw.contains("multipart/alternative; boundary=\"XYZ\""))
        XCTAssertTrue(raw.contains("--XYZ--"))
    }

    func testPDFAttachment() {
        let pdf = Data("%PDF-1.4 fake".utf8)
        let raw = MIMEMessage.build(
            to: "a@b.com", subject: "Invoice #0001", html: "<p>hi</p>", text: "hi",
            attachments: [.init(filename: "Invoice-0001.pdf", mimeType: "application/pdf", data: pdf)],
            boundary: "XYZ"
        )
        XCTAssertTrue(raw.contains("Content-Type: multipart/mixed; boundary=\"XYZ\""))
        XCTAssertTrue(raw.contains("Content-Type: multipart/alternative; boundary=\"XYZ-alt\""))
        XCTAssertTrue(raw.contains("Content-Disposition: attachment; filename=\"Invoice-0001.pdf\""))
        XCTAssertTrue(raw.contains(pdf.base64EncodedString()))
        XCTAssertTrue(raw.contains("--XYZ-alt--"))
        XCTAssertTrue(raw.hasSuffix("--XYZ--\r\n"))
    }

    func testNonASCIISubjectEncoded() {
        XCTAssertEqual(MIMEMessage.encodeHeader("Café"), "=?UTF-8?B?Q2Fmw6k=?=")
    }

    func testBase64URLHasNoPadding() {
        let encoded = MIMEMessage.base64URL("??>")
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
    }
}

final class EmailTests: XCTestCase {
    func testPlausible() {
        XCTAssertTrue(EmailAddress.isPlausible("mary@example.com"))
        XCTAssertFalse(EmailAddress.isPlausible("mary at example dot com"))
        XCTAssertFalse(EmailAddress.isPlausible("mary@example"))
        XCTAssertFalse(EmailAddress.isPlausible(nil))
    }
}

final class GroundingTests: XCTestCase {
    func testDropsInventedItemsWhenOnlyAnAddressWasSaid() {
        let transcript = "123 Main Street, Springfield"
        let invented = ExtractionResult(
            jobAddress: "123 Main Street, Springfield",
            items: [
                ExtractedItem(description: "Replace kitchen faucet", quantity: 1, unitPriceCents: 12500),
                ExtractedItem(description: "Labor", quantity: 2, unitPriceCents: 4000),
            ]
        )
        let grounded = ExtractionGrounding.ground(invented, transcript: transcript)
        XCTAssertTrue(grounded.items.isEmpty)
        XCTAssertEqual(grounded.jobAddress, "123 Main Street, Springfield")
    }

    func testKeepsSaidItemsAndPrices() {
        let transcript = "Job for Mary Johnson. Replaced 12 fence boards at $15 each, and 2 hours labor at 60 an hour."
        let result = ExtractionResult(
            clientName: "Mary Johnson",
            items: [
                ExtractedItem(description: "Replace fence boards", quantity: 12, unitPriceCents: 1500),
                ExtractedItem(description: "Labor", quantity: 2, unitPriceCents: 6000),
            ]
        )
        let grounded = ExtractionGrounding.ground(result, transcript: transcript)
        XCTAssertEqual(grounded, result)
    }

    func testClearsPriceThatWasNotSaid() {
        let transcript = "Painted the back door"
        let result = ExtractionResult(items: [ExtractedItem(description: "Paint back door", quantity: 1, unitPriceCents: 9900)])
        let grounded = ExtractionGrounding.ground(result, transcript: transcript)
        XCTAssertEqual(grounded.items.count, 1)
        XCTAssertNil(grounded.items[0].unitPriceCents)
    }

    func testDropsInventedClient() {
        let grounded = ExtractionGrounding.ground(
            ExtractionResult(clientName: "John Smith", clientEmail: "john@example.com"),
            transcript: "Fixed the gate"
        )
        XCTAssertNil(grounded.clientName)
        XCTAssertNil(grounded.clientEmail)
    }

    func testSpokenNumbers() {
        XCTAssertEqual(ExtractionGrounding.spokenNumbers("$1,200.50 and 15."), [Decimal(string: "1200.50")!, 15])
    }
}

final class SpokenFieldsTests: XCTestCase {
    func testClientAndAddress() {
        let f = SpokenFields.parse("Client Mary Johnson. Address 12 Oak St, Springfield. Replaced the fence boards.")
        XCTAssertEqual(f.client, "Mary Johnson")
        XCTAssertEqual(f.address, "12 Oak St, Springfield")
    }

    func testCompanyWithFillerWords() {
        let f = SpokenFields.parse("okay the client is acme plumbing and the address is 400 Elm Avenue")
        XCTAssertEqual(f.client, "Acme Plumbing")
        XCTAssertEqual(f.address, "400 Elm Avenue")
    }

    func testStopsAtNextLabel() {
        let f = SpokenFields.parse("Customer: Bob's Diner address 9 Pine Road email bob at diner dot com phone 555 123 4567")
        XCTAssertEqual(f.client, "Bob's Diner")
        XCTAssertEqual(f.address, "9 Pine Road")
        XCTAssertEqual(f.email, "bob@diner.com")
        XCTAssertEqual(f.phone, "(555) 123-4567")
    }

    func testEmailWithDotsInsideIsKept() {
        XCTAssertEqual(SpokenFields.parse("Email mary@gmail.com. Fixed sink.").email, "mary@gmail.com")
    }

    func testEmailAddressLabel() {
        let f = SpokenFields.parse("Her email address is mary at gmail dot com. Fixed sink.")
        XCTAssertEqual(f.email, "mary@gmail.com")
        XCTAssertNil(f.address)
    }

    func testClientInASentenceIsNotAName() {
        XCTAssertNil(SpokenFields.parse("The client wanted the deck stained.").client)
    }

    func testNoLabels() {
        XCTAssertEqual(SpokenFields.parse("Fixed the gate for 40 dollars."), SpokenFields())
    }

    func testApplyOverridesModel() {
        let model = ExtractionResult(clientName: "Marie", jobAddress: nil)
        let out = SpokenFields(client: "Mary Johnson", address: "12 Oak St").apply(to: model)
        XCTAssertEqual(out.clientName, "Mary Johnson")
        XCTAssertEqual(out.jobAddress, "12 Oak St")
    }
}

final class ClientResolverTests: XCTestCase {
    let mary = ClientRecord(id: UUID(), name: "Mary Johnson", addresses: ["12 Oak Street, Springfield"])
    let bob = ClientRecord(id: UUID(), name: "Bob's Diner", addresses: ["9 Pine Rd", "40 Main St"])
    let maryJones = ClientRecord(id: UUID(), name: "Mary Jones", addresses: ["7 Elm Ave"])
    var history: [ClientRecord] { [mary, bob, maryJones] }

    func testRepeatClientByName() {
        XCTAssertEqual(ClientResolver.resolve(name: "mary johnson", address: nil, history: history), .existing(mary.id))
    }

    func testRepeatClientAtNewAddress() {
        XCTAssertEqual(ClientResolver.resolve(name: "Mary Johnson", address: "99 Lake Dr", history: history), .existing(mary.id))
    }

    func testAddressOnlyFindsClient() {
        XCTAssertEqual(ClientResolver.resolve(name: nil, address: "12 Oak St", history: history), .existing(mary.id))
    }

    func testNewClient() {
        XCTAssertEqual(ClientResolver.resolve(name: "Tom Lee", address: "1 New Rd", history: history), .new)
    }

    func testAmbiguousFirstName() {
        guard case .ambiguous(let ids) = ClientResolver.resolve(name: "Mary", address: nil, history: history) else {
            return XCTFail("expected ambiguous")
        }
        XCTAssertEqual(Set(ids), [mary.id, maryJones.id])
    }

    func testFirstNamePlusAddressSettlesIt() {
        XCTAssertEqual(ClientResolver.resolve(name: "Mary", address: "7 Elm Avenue", history: history), .existing(maryJones.id))
    }

    func testFullNameWinsOverSomeoneElsesAddress() {
        XCTAssertEqual(ClientResolver.resolve(name: "Mary Johnson", address: "9 Pine Road", history: history), .existing(mary.id))
    }

    func testPartialNameAndAddressDisagree() {
        guard case .ambiguous = ClientResolver.resolve(name: "Johnson", address: "9 Pine Road", history: history) else {
            return XCTFail("expected ambiguous")
        }
    }

    func testTwoClientsAtOneAddress() {
        let tenant = ClientRecord(id: UUID(), name: "Ann Lee", addresses: ["12 Oak St"])
        guard case .ambiguous = ClientResolver.resolve(name: nil, address: "12 Oak St", history: history + [tenant]) else {
            return XCTFail("expected ambiguous")
        }
    }

    func testNothingToGoOn() {
        XCTAssertEqual(ClientResolver.resolve(name: nil, address: "5 Unknown Ln", history: history), .unknown)
        XCTAssertEqual(ClientResolver.resolve(name: nil, address: nil, history: history), .unknown)
    }

    func testUsualAddress() {
        XCTAssertEqual(ClientResolver.usualAddress(of: mary), "12 Oak Street, Springfield")
        XCTAssertNil(ClientResolver.usualAddress(of: bob))
        let repeatSame = ClientRecord(id: UUID(), name: "X", addresses: ["12 Oak St", "12 Oak Street"])
        XCTAssertEqual(ClientResolver.usualAddress(of: repeatSame), "12 Oak St")
    }

    func testAddressMatching() {
        XCTAssertTrue(AddressMatching.same("12 Oak Street", "12 oak st."))
        XCTAssertTrue(AddressMatching.same("12 Oak St", "12 Oak Street, Springfield"))
        XCTAssertFalse(AddressMatching.same("12 Oak St", "120 Oak St"))
        XCTAssertFalse(AddressMatching.same("Oak St", "Oak St Springfield"))
    }
}

final class AccountingExportTests: XCTestCase {
    func makeJobs() -> [ExportJob] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let nov20 = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12))!
        let nov2 = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
        return [
            ExportJob(invoiceNumber: 7, date: nov20, client: "Mary Johnson", email: "mary@example.com",
                      address: "12 Oak St, Springfield", job: "Fence repair", status: "Invoiced",
                      lines: [ExportLine(description: "Boards", details: "Cedar, 6 ft", quantity: 12, unitPriceCents: 1500),
                              ExportLine(description: "Labor", quantity: 2.5, unitPriceCents: 6000)]),
            ExportJob(invoiceNumber: nil, date: nov2, client: "Bob's \"Diner\"", email: "", address: "", job: "Gate",
                      status: "Needs review", lines: [ExportLine(description: "Fix gate", quantity: 1, unitPriceCents: nil)]),
        ]
    }

    func testInvoicesCSV() {
        let lines = AccountingExport.invoicesCSV(makeJobs(), taxRatePercent: 0).components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Invoice #,Date,Client,Email,Address,Job,Status,Subtotal,Tax,Total,Missing prices")
        XCTAssertEqual(lines[1], ",2026-11-02,\"Bob's \"\"Diner\"\"\",,,Gate,Needs review,0.00,0.00,0.00,Yes")
        XCTAssertEqual(lines[2], "0007,2026-11-20,Mary Johnson,mary@example.com,\"12 Oak St, Springfield\",Fence repair,Invoiced,330.00,0.00,330.00,")
    }

    func testTax() {
        let csv = AccountingExport.invoicesCSV([makeJobs()[0]], taxRatePercent: 8.25)
        XCTAssertTrue(csv.contains(",330.00,27.23,357.23,"))
    }

    func testLineItemsCSV() {
        let lines = AccountingExport.lineItemsCSV(makeJobs()).components(separatedBy: "\r\n")
        XCTAssertEqual(lines[1], ",2026-11-02,\"Bob's \"\"Diner\"\"\",Gate,Fix gate,,1,,")
        XCTAssertEqual(lines[2], "0007,2026-11-20,Mary Johnson,Fence repair,Boards,\"Cedar, 6 ft\",12,15.00,180.00")
        XCTAssertEqual(lines[3], "0007,2026-11-20,Mary Johnson,Fence repair,Labor,,2.50,60.00,150.00")
    }

    func testFormulaInjectionDefused() {
        XCTAssertEqual(AccountingExport.field("=SUM(A1)"), "'=SUM(A1)")
        XCTAssertEqual(AccountingExport.field("-12.50"), "-12.50")
    }

    // MARK: One price for several tasks

    func testWholeJobPriceFoldsSplitItemsIntoOne() {
        let raw = ExtractionResult(items: [
            ExtractedItem(description: "Paint kitchen", unitPriceCents: 45_000),
            ExtractedItem(description: "clean floor"),
        ])
        let out = ExtractionGrounding.combineSharedPrice(raw, transcript: "paint kitchen and clean floor 450$ for the whole job")
        XCTAssertEqual(out.items.count, 1)
        XCTAssertEqual(out.items[0].description, "Paint kitchen and clean floor")
        XCTAssertEqual(out.items[0].unitPriceCents, 45_000)
    }

    func testSeparatelyPricedWorkIsNotFolded() {
        let raw = ExtractionResult(items: [
            ExtractedItem(description: "Paint kitchen", unitPriceCents: 45_000),
            ExtractedItem(description: "Clean floor"),
        ])
        let out = ExtractionGrounding.combineSharedPrice(raw, transcript: "paint kitchen 450, cleaned the floor, not sure what to charge yet")
        XCTAssertEqual(out.items.count, 2)

        let install = ExtractionGrounding.combineSharedPrice(raw, transcript: "paint kitchen 450, install in the hall closet")
        XCTAssertEqual(install.items.count, 2)
    }

    func testJoinWork() {
        XCTAssertEqual(ExtractionGrounding.joinWork(["fix door"]), "Fix door")
        XCTAssertEqual(ExtractionGrounding.joinWork(["Paint kitchen", "Clean floor", "Haul trash"]),
                       "Paint kitchen, clean floor and haul trash")
    }

    // MARK: Spoken corrections

    private let paintJob = [ExistingItem(description: "Paint kitchen and clean floor", unitPriceCents: 45_000)]

    func testCorrectionChangesRoomAndDropsDuplicateItem() {
        let raw = ExtractionResult(
            items: [ExtractedItem(description: "Paint living room")],
            changes: [ItemChange(itemNumber: 1, newDescription: "Paint living room and clean floor")]
        )
        let out = ExtractionGrounding.groundChanges(raw, transcript: "instead of kitchen i meant living room", existing: paintJob)
        XCTAssertEqual(out.changes, [ItemChange(itemNumber: 1, newDescription: "Paint living room and clean floor")])
        XCTAssertTrue(out.items.isEmpty)
    }

    func testCorrectionPriceMustBeSaid() {
        let raw = ExtractionResult(changes: [ItemChange(itemNumber: 1, newUnitPriceCents: 35_000)])
        XCTAssertEqual(ExtractionGrounding.groundChanges(raw, transcript: "actually make that 350", existing: paintJob).changes.first?.newUnitPriceCents, 35_000)
        XCTAssertTrue(ExtractionGrounding.groundChanges(raw, transcript: "actually make it cheaper", existing: paintJob).changes.isEmpty)
    }

    func testCorrectionNeedsRealItemAndRemovalWords() {
        let badNumber = ExtractionResult(changes: [ItemChange(itemNumber: 4, newUnitPriceCents: 35_000)])
        XCTAssertTrue(ExtractionGrounding.groundChanges(badNumber, transcript: "make it 350", existing: paintJob).changes.isEmpty)

        let remove = ExtractionResult(changes: [ItemChange(itemNumber: 1, remove: true)])
        XCTAssertTrue(ExtractionGrounding.groundChanges(remove, transcript: "also fixed a door", existing: paintJob).changes.isEmpty)
        XCTAssertEqual(ExtractionGrounding.groundChanges(remove, transcript: "take that off, I didn't do it", existing: paintJob).changes.count, 1)
    }

    func testOldServerReplyWithoutChangesStillDecodes() throws {
        let json = #"{"client_name":null,"client_email":null,"client_phone":null,"job_address":null,"job_title":null,"items":[],"notes":null}"#
        let result = try JSONDecoder().decode(ExtractionResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.changes, [])
    }

    func testNumberedExistingItems() {
        XCTAssertEqual(ExistingItem.numberedList(paintJob + [ExistingItem(description: "Haul trash", unitPriceCents: nil)]),
                       ["1. Paint kitchen and clean floor ($450.00)", "2. Haul trash (no price)"])
    }

    // MARK: Contact email lookup

    func testContactEmailOnlyWhenClear() {
        let mary = ContactCandidate(names: ["Mary A. Johnson"], emails: ["mary@example.com"])
        let otherMary = ContactCandidate(names: ["Mary Smith"], emails: ["msmith@example.com"])
        XCTAssertEqual(ContactEmailMatching.pick(name: "Mary Johnson", candidates: [mary, otherMary]), "mary@example.com")
        // First name alone is too vague.
        XCTAssertNil(ContactEmailMatching.pick(name: "Mary", candidates: [mary, otherMary]))
        // Same person found twice (Google and phone) is still one answer.
        XCTAssertEqual(ContactEmailMatching.pick(name: "mary johnson", candidates: [mary, ContactCandidate(names: ["Mary Johnson"], emails: ["MARY@example.com "])]), "mary@example.com")
        // Two different addresses: leave it blank.
        XCTAssertNil(ContactEmailMatching.pick(name: "Mary Johnson", candidates: [ContactCandidate(names: ["Mary Johnson"], emails: ["a@example.com", "b@example.com"])]))
        // Company name said exactly.
        XCTAssertEqual(ContactEmailMatching.pick(name: "Acme", candidates: [ContactCandidate(names: [" ", "Acme"], emails: ["office@acme.com"])]), "office@acme.com")
    }

    func testMailHeadersAndAddressSearch() {
        let mail = MailParticipants.parse(headers: ["\"Johnson, Mary\" <mary@example.com>", "dad@gmail.com, Bob <bob@example.com>"])
        XCTAssertEqual(mail.people.map(\.emails), [["mary@example.com"], ["dad@gmail.com"], ["bob@example.com"]])
        XCTAssertEqual(mail.people[0].names, ["Johnson, Mary"])

        let quote = MailParticipants.parse(headers: ["Mary <mary@example.com>", "dad@gmail.com"])
        let alert = MailParticipants.parse(headers: ["no-reply@city.gov", "dad@gmail.com"])
        XCTAssertEqual(ContactEmailMatching.pickByAddress(mails: [quote, alert], ownEmail: "Dad@gmail.com"), "mary@example.com")
        XCTAssertNil(ContactEmailMatching.pickByAddress(mails: [quote, mail], ownEmail: "dad@gmail.com"))

        XCTAssertEqual(ContactEmailMatching.addressSearchTerm("123 Oak Street, Apt 4"), "123 Oak")
        XCTAssertNil(ContactEmailMatching.addressSearchTerm("Oak Street"))
    }
}
