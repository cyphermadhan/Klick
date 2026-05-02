# TestFlight release guide

End-to-end path from a fresh clone to a TestFlight build ready to distribute to testers.

## Prerequisites

- Apple Developer Program membership ($99/yr) — required to upload to App Store Connect.
- Xcode 15 or later signed into your Apple ID (Xcode → Settings → Accounts).
- XcodeGen installed: `brew install xcodegen`.
- An iPhone to install the build on. Simulator can't capture mic audio — TestFlight doesn't run on simulator anyway.

## One-time Apple setup

### 1. Get your Team ID

Open <https://developer.apple.com/account>, go to **Membership details**, copy the 10-character **Team ID**.

### 2. Register the App ID

<https://developer.apple.com/account/resources/identifiers/list> → **+** → **App IDs** → **App**:

- Description: `Walkie`
- Bundle ID: **Explicit**, `com.klick.walkietalkie` (or whatever you change `PRODUCT_BUNDLE_IDENTIFIER` to in `project.yml`).
- Capabilities: none required for Phase 1. Do **not** enable Push Notifications, Background Modes, etc.

### 3. Create the App Store Connect record

<https://appstoreconnect.apple.com/apps> → **+** → **New App**:

- Platform: iOS
- Name: `Walkie` (or anything — shown in TestFlight)
- Primary Language: English (or your preference)
- Bundle ID: the one you just registered
- SKU: `walkie-001` (internal identifier, anything unique)
- User Access: Full Access

## Local setup

### 1. Add your Team ID to the gitignored config

```bash
cp Signing.xcconfig.example Signing.xcconfig
# Open Signing.xcconfig and replace XXXXXXXXXX with your 10-char Team ID
```

`Signing.xcconfig` is in `.gitignore` so your team ID never ships in the public repo.

### 2. Regenerate the Xcode project

```bash
xcodegen generate
open WalkieTalkie.xcodeproj
```

Xcode should now resolve automatic signing against your team.

### 3. (Optional) Replace the placeholder app icon

`Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` is a placeholder I generated from a Swift script. Drop a real 1024×1024 PNG (no transparency, no rounded corners — iOS adds them) in that path to replace it. Keep the filename or update `Contents.json` accordingly.

## Build & upload

### CLI path (reproducible)

```bash
# 1. Archive (signed)
xcodebuild -project WalkieTalkie.xcodeproj \
  -scheme WalkieTalkie \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/WalkieTalkie.xcarchive \
  archive

# 2. Export for App Store
xcodebuild -exportArchive \
  -archivePath build/WalkieTalkie.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist

# 3. Upload
xcrun altool --upload-app \
  --file build/export/WalkieTalkie.ipa \
  --type ios \
  --apiKey YOUR_KEY_ID --apiIssuer YOUR_ISSUER_ID
```

You'll need an App Store Connect API key (<https://appstoreconnect.apple.com/access/integrations/api>) for altool. Alternatively skip altool and use the Xcode Organizer GUI (below).

### GUI path (easier first time)

1. In Xcode: **Product → Archive**. (Must be on a real device target, not a simulator.)
2. When the Organizer opens, select the new archive → **Distribute App** → **App Store Connect** → **Upload**.
3. Keep all the defaults: automatic signing, include symbols, manage version and build number.
4. Upload takes a few minutes. You'll get an email when processing finishes.

### Export options template

Create `ExportOptions.plist` in the repo root if you use the CLI path. **Do not commit it** — it contains your team ID:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>XXXXXXXXXX</string>
    <key>uploadSymbols</key>
    <true/>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
```

## Once in App Store Connect

1. Open the app → **TestFlight** tab.
2. Wait for processing (5–15 min for a small app). Status flips from *Processing* to *Ready to Submit*.
3. Complete the **Export Compliance** questionnaire (first upload only):
   - "Does your app use encryption?" → **Yes**
   - "Does your app qualify for any of the exemptions?" → **Yes**, the primary exemption (using encryption only to protect user data with standard algorithms). The `ITSAppUsesNonExemptEncryption: false` key in Info.plist pre-answers this — ASC may skip the questionnaire on subsequent builds.
4. Add internal testers under **Internal Testing** (up to 100, no review). Each tester gets an email with the TestFlight install link.
5. External testing requires a short App Review (1–2 days for the first build, usually faster after). Fill in:
   - Beta App Description
   - Feedback Email
   - Marketing URL (optional)
   - What to Test: "Push-to-talk audio over local WiFi. Grant mic, local network, and camera permissions on first launch. Pair by scanning one device's QR from the other."

## Bump the build number between uploads

App Store Connect rejects re-uploads with the same `(version, build)` pair. For each new TestFlight upload, bump `CURRENT_PROJECT_VERSION` in `project.yml` (or `MARKETING_VERSION` for a new version line):

```yaml
settings:
  base:
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "2"   # was 1
```

Then `xcodegen generate` and re-archive.

## Known caveats for testers

Paste this into the TestFlight **What to Test** section:

> 1. Install on **two** iPhones on the **same WiFi network**.
> 2. Launch. Grant mic, local network, and camera permissions.
> 3. Tap **START** on both.
> 4. On phone A: **PAIR → SHOW CODE**. On phone B: **PAIR → SCAN CODE**. Scan A's screen. Verify the `FPRINT` value on the **PAIR** tile matches on both phones.
> 5. Close both pairing sheets. Each phone's name should appear in the other's peer list.
> 6. Tap a peer to select it. Hold **TRANSMIT** and talk. You should hear audio on the other device.
> 7. Test the **TELEMETRY** panel — `PKT TX` and `PKT RX` should climb in sync; `LOSS` should stay under 1 %.
> 8. Test key rotation: **Settings → Unpair**, then re-pair.
> 9. Walk away — when out of WiFi range the peer should drop from the list.

## Troubleshooting

- **"No matching provisioning profile found"** → You haven't set `DEVELOPMENT_TEAM` in `Signing.xcconfig`, or Xcode isn't signed in to an account with access to that team.
- **"Bundle ID not available"** → That bundle ID is already registered to another developer. Change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to your own reverse-DNS.
- **Archive succeeds but "invalid icon" on upload** → You replaced `AppIcon-1024.png` with a PNG that has transparency or is not exactly 1024×1024. Re-export.
- **"No Bonjour services found" in TestFlight review** → App reviewers run on a locked-down network. Local-network apps sometimes need a review note. Add "Requires two devices on the same WiFi for end-to-end functionality. Reviewer can verify UI, permission prompts, and pairing QR flow on a single device."
- **"Encryption export compliance missing"** → Re-check `ITSAppUsesNonExemptEncryption` in Info.plist is `false` and redo the archive.
