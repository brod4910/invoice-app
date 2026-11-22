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
