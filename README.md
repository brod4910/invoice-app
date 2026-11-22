# Invoices

An iPhone app for a self-employed tradesperson who isn't comfortable with technology. Open the app, tap the big red button, talk through the job you just finished, and tap Stop. The app writes up the job with line items and prices, and with one more tap puts a formatted invoice in your Gmail drafts. You check the draft in Gmail and press Send yourself. The app never sends email on its own.

## How it works

| Step | Where it runs | Code |
| --- | --- | --- |
| Record the job | iPhone | `App/Sources/Services/AudioRecorder.swift` |
| Speech to text | iPhone, on-device (iOS 26 SpeechAnalyzer, falls back to SFSpeechRecognizer) | `Transcriber.swift` |
| Pull out client, items and prices | Cloudflare Worker calling Claude with structured output | `proxy/` |
| Review, edit, add more, combine jobs | iPhone (SwiftData) | `App/Sources/Views/` |
| Invoice email | iPhone builds HTML and plain text, Gmail API creates a draft | `InvoiceCore/`, `GmailClient.swift`, `GoogleAuth.swift` |

Audio and transcripts stay on the phone. Only the transcript text goes to the extraction server, and only the finished invoice goes to Gmail. If the phone has no signal, recordings are kept and processed when the app is next opened.

Prices are only ever what was said out loud. An item with no spoken price shows an orange **Price?** tag and the invoice screen warns before drafting.

## Layout

- `App/` – the SwiftUI app
- `InvoiceCore/` – a plain Swift package with the logic that doesn't need a phone: money, invoice HTML, the email (MIME) format, client name matching, duplicate job detection. It has unit tests.
- `proxy/` – a small Cloudflare Worker that holds the Anthropic API key so it never ships inside the app
- `project.yml` – the Xcode project, generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen). The app has no third-party dependencies; Google sign-in uses Apple's built-in web sign-in sheet.

## One-time setup

You need a Mac with Xcode 26, an Apple Developer account (for TestFlight), a Google account, a Cloudflare account (free tier is fine) and an Anthropic API key.

### 1. Extraction server

```sh
cd proxy
npm install
npx wrangler login
npx wrangler secret put ANTHROPIC_API_KEY   # paste your Anthropic key
npx wrangler secret put APP_TOKEN           # paste a long random string, e.g. from `openssl rand -hex 32`
npx wrangler deploy                         # prints your https://invoice-extract.<you>.workers.dev URL
```

Run `npm test` to check it locally.

### 2. Google sign-in for Gmail drafts

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project and enable the **Gmail API**.
2. Set up the **OAuth consent screen** (External). Add the scope `https://www.googleapis.com/auth/gmail.compose`, and add your dad's Gmail address as a **test user**.
3. Create an **OAuth client ID** of type **iOS**, with your app's bundle ID. Note the client ID and the "iOS URL scheme" (the reversed client ID).

Heads up: while the Google project is in "Testing" mode, Google may ask your dad to sign in again about once a week. The app will show "Please sign in to Gmail again" when that happens. Getting the app verified by Google removes this, but is a longer process.

### 3. Build the app

```sh
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # fill in your values
xcodegen
open InvoiceApp.xcodeproj
```

Pick your dad's iPhone (or a simulator) and press Run. To install it on his phone for the long term, use Product → Archive and upload to TestFlight.

Run the unit tests with ⌘U, or `swift test` inside `InvoiceCore/`.

### 4. First run on your dad's phone

Open **Settings** (gear icon, top right) and fill in the business name, phone, payment terms, sales tax (leave 0 for none) and the first invoice number. Then tap **Sign in to Gmail** with his account.

## Using it

- **Record a job:** the big red button. Say who it was for, their email, what you did, and the price of each part.
- **Stopped by accident?** Tap **Oops, keep talking** right away, or later open the job and tap **Add more to this job**.
- **Fix anything:** tap an item to change it, or tap the client name.
- **Two jobs that should be one:** the jobs list suggests combining jobs for the same client on the same day, or use **⋯ → Combine with another job**.
- **Send the invoice:** **Make invoice → Put in Gmail drafts**, then open Gmail, check it, and press Send.
