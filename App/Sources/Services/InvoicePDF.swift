import InvoiceCore
import UIKit

/// Renders the invoice HTML into a US Letter PDF on the phone.
@MainActor
enum InvoicePDF {
    static func make(_ doc: InvoiceDocument) -> Data {
        let formatter = UIMarkupTextPrintFormatter(markupText: InvoiceRenderer.html(doc))
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)

        let page = CGRect(x: 0, y: 0, width: 612, height: 792) // 8.5 x 11 in at 72 dpi
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(page.insetBy(dx: 36, dy: 36), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, [
            kCGPDFContextTitle as String: "Invoice #\(doc.formattedNumber)",
            kCGPDFContextCreator as String: doc.business.name.isEmpty ? "Invoices" : doc.business.name,
        ])
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for index in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }
}
