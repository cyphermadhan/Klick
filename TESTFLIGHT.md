# TestFlight release — step-by-step

Hand-holding walkthrough from a fresh clone to testers installing via TestFlight. Assumes you already have an **Apple Developer Program** membership ($99/yr) and **Xcode** installed.

---

## Short answer to common questions

> **Do I need App Groups?** No. App Groups are for sharing data between a main app and its extensions (Widgets, Share Extensions, etc.). Walkie has no extensions, so **skip App Groups entirely**.

> **What capabilities do I add in Xcode?** None. Walkie uses mic / camera / local network / Keychain / Bonjour — all of those work with just Info.plist keys we've already set. The **Signing & Capabilities** tab should show only the one default "Signing" block.

> **Do I need to create a Distribution certificate manually?** No. With automatic signing, Xcode creates and manages certificates and provisioning profiles for you the first time you archive.

---

## Part 1 — Apple Developer Portal (one-time, 5 min)

**URL:** <https://developer.apple.com/account>

### 1.1 Copy your Team ID

- Click **Membership details** in the sidebar.
- Find the **Team ID** row — it's a 10-character alphanumeric string like `A1B2C3D4E5`.
- Copy it. You'll paste it into `Signing.xcconfig` in a minute.

### 1.2 Create the App ID (Bundle ID)

- Sidebar → **Certificates, Identifiers & Profiles**.
- Click **Identifiers** on the left.
- Click the blue **+** next to "Identifiers".
- Select **App IDs** → **Continue**.
- Select type: **App** → **Continue**.
- Fill in:
  - **Description:** `Walkie`
  - **Bundle ID:** Select **Explicit**, enter `com.klick.walkietalkie`
    - Or pick your own reverse-DNS (e.g. `com.yourname.walkietalkie`). If you change it here, also change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`.
- **Capabilities section:** **leave everything unchecked.** Walkie needs none of these.
- **App Services section:** **leave everything unchecked.**
- Click **Continue** → **Register**.

That's it. No App Group, no entitlement, no push cert.

---

## Part 2 — App Store Connect (one-time, 3 min)

**URL:** <https://appstoreconnect.apple.com/apps>

- Click the blue **+** button → **New App**.
- Fill in:
  - **Platforms:** ☑ iOS
  - **Name:** `Walkie` (shown to testers in TestFlight)
  - **Primary Language:** English (U.S.)
  - **Bundle ID:** select `com.klick.walkietalkie - Walkie` from the dropdown (the one you just registered)
  - **SKU:** `walkie-001` (any unique internal string)
  - **User Access:** Full Access
- Click **Create**.

The app record exists now. You'll come back to it after uploading a build.

---

## Part 3 — Local setup (one-time, 1 min)

```bash
cd /Users/mraj/Documents/GitHub/Klick

# 1. Copy the example and open in your editor
cp Signing.xcconfig.example Signing.xcconfig
open -e Signing.xcconfig
```

Replace `XXXXXXXXXX` with your 10-char Team ID from Part 1.1. Save and close.

```bash
# 2. Regenerate the Xcode project so it picks up the xcconfig
xcodegen generate

# 3. Open in Xcode
open WalkieTalkie.xcodeproj
```

`Signing.xcconfig` is in `.gitignore` — your Team ID stays local and never hits GitHub.

---

## Part 4 — In Xcode (verify signing, 1 min)

### 4.1 Sign in with your Apple ID (first time only)

- Xcode menu → **Settings…** (`⌘,`) → **Accounts** tab.
- If your Apple ID isn't listed, click **+** → **Apple ID** → enter credentials.
- In the right pane, your team should appear in the list. Close Settings.

### 4.2 Check Signing & Capabilities tab

- In the Project Navigator (left sidebar), click the blue **WalkieTalkie** project icon at the top.
- In the middle pane, select the **WalkieTalkie** target (not the tests target, not the project).
- Click the **Signing & Capabilities** tab at the top.

You should see exactly this:

```
┌─ Signing ────────────────────────────────────────────────┐
│ ☑ Automatically manage signing                           │
│                                                           │
│ Team:               [ Your Team Name ]          [ ▼ ]     │
│ Bundle Identifier:  com.klick.walkietalkie                │
│ Provisioning Profile: Xcode Managed Profile               │
│ Signing Certificate:  Apple Development: ...              │
└───────────────────────────────────────────────────────────┘
```

- **If Team is empty or says "None":** click the dropdown and pick your team. (This shouldn't happen if Signing.xcconfig is set correctly, but sometimes the UI lags.)
- **If you see a red warning "Failed to register bundle identifier":** you didn't create the App ID in Part 1.2. Go back and do that.

**Do not click "+ Capability".** You don't need any. The list should be empty except the default Signing block.

### 4.3 Try a quick build

- Top-left of Xcode, select any connected iPhone or "Any iOS Device (arm64)" as the destination.
- Press `⌘B` to build. Should succeed. If it fails on signing, re-check Part 4.2.

---

## Part 5 — Archive and upload (5 min)

### 5.1 Select the archive destination

- Top of Xcode, click the device/simulator picker (next to the scheme name).
- Choose **Any iOS Device (arm64)**.
  - *Not* a simulator — you can't archive to simulator.
  - *Not* a specific iPhone unless you only want to sign for that device.

### 5.2 Archive

- Menu: **Product → Archive**.
- Wait 2–5 minutes. You'll see "Archiving WalkieTalkie…" in the activity bar.
- When it finishes, the **Organizer** window opens automatically, showing your new archive.

### 5.3 Distribute

In the Organizer:

- Your new archive is selected at the top. Click **Distribute App** (right side).
- Select **App Store Connect** → **Next**.
- Select **Upload** → **Next**.
  - *Not* Export — that creates an .ipa file but doesn't upload.
- **App Store Connect distribution options screen:**
  - ☑ Strip Swift symbols
  - ☑ Upload your app's symbols
  - ☑ Manage Version and Build Number
  - Click **Next**.
- **Re-sign confirmation screen:**
  - Select **Automatically manage signing** → **Next**.
- **Review screen:** shows everything bundled. Should list:
  - Team, bundle ID, version, size
  - Entitlements: none special
  - Capabilities: none
  - Click **Upload**.
- Wait 1–3 minutes for upload. You'll see a progress bar.
- On success: "App uploaded successfully" → **Done**.

---

## Part 6 — In App Store Connect (5 min)

**URL:** <https://appstoreconnect.apple.com/apps>

- Click your **Walkie** app.
- Top tab: **TestFlight**.

### 6.1 Wait for processing

- Your build appears under **iOS Builds** with status **Processing**.
- Takes 5–15 min the first time, 2–5 min subsequently.
- You'll get an email when it's done. Status becomes **Ready to Submit** or shows a yellow warning.

### 6.2 Export compliance (if prompted)

If ASC asks an Export Compliance question on this build (it often doesn't now that `ITSAppUsesNonExemptEncryption=false` is set in Info.plist, but sometimes does for the first upload):

- "Does your app use encryption?" → **Yes**
- "Does it qualify for an exemption?" → **Yes**
- Select: **Your app uses or accesses encryption that falls within the exemption categories.**
- "Which exemption?" → **The encryption is used only to protect sensitive user data** (or similar wording).
- **Start Internal Testing**.

### 6.3 Add internal testers

Internal testers don't require App Review — instant install. Up to 100.

- Left sidebar → **Internal Testing** → **+ Testers**.
- Pick yourself + anyone with an Apple ID on your team.
- Click **Add**.
- Each gets an email with a TestFlight install link. They click it, install TestFlight app from the App Store if they don't have it, then install Walkie.

### 6.4 (Optional) External testers

If you want to send to non-team people, that requires an initial Beta App Review (usually < 24 h):

- Left sidebar → **External Testing** → create a group → add testers by email.
- Fill in:
  - **Beta App Description:** "Encrypted push-to-talk over local WiFi. Hold the big button to talk."
  - **What to Test:** use the tester brief below.
  - **Feedback Email:** your email.
- Submit for Review.

### Tester brief (paste into "What to Test")

```
Requires two iPhones on the same WiFi network.

1. Install on both phones. Grant mic, local network, and camera
   permissions when prompted.
2. Tap START on both phones.
3. On phone A: PAIR → SHOW CODE.
4. On phone B: PAIR → SCAN CODE. Scan A's screen.
5. Verify the FPRINT value on both phones' PAIR tile matches
   after scanning — that confirms encryption keys are shared.
6. Close both pairing sheets. Each phone's name should appear
   in the other's peer list.
7. Tap a peer to select it. Hold TRANSMIT and talk.
8. Watch TELEMETRY: PKT TX and PKT RX should climb in sync
   while talking; LOSS should stay under 1%.

Known limits: one-to-one only (no group talk). Foreground only
(no background audio). LAN only (no internet relay).
```

---

## Part 7 — Releasing a new build

App Store Connect rejects re-uploads with the same (version, build) pair. Bump the build number every time.

Edit `project.yml`:

```yaml
settings:
  base:
    MARKETING_VERSION: "0.1.0"        # same version line
    CURRENT_PROJECT_VERSION: "2"      # was 1, increment every upload
```

For a new version line (e.g. 0.2.0), bump `MARKETING_VERSION` and reset `CURRENT_PROJECT_VERSION` to 1.

Then:

```bash
xcodegen generate
```

And repeat Part 5.

---

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| Red "Failed to register bundle identifier" in Signing tab | Didn't do Part 1.2 | Register the App ID in the Developer Portal |
| "No profiles for 'com.klick.walkietalkie' were found" | Your Apple ID isn't on the team that owns the App ID | Get invited to the team, or change bundle ID to one you own |
| "Could not find team with id 'XXXX'" | Wrong Team ID in Signing.xcconfig | Re-check Membership details |
| Archive succeeds but upload says "invalid icon" | Asset catalog broken | Verify `Resources/Assets.xcassets/AppIcon.appiconset/` has Contents.json + 3 PNGs |
| TestFlight says "Missing Compliance" | Edge case where ITSAppUsesNonExemptEncryption didn't stick | Answer the compliance question in the ASC web UI (Part 6.2) |
| ASC review rejects with "peers not found" | Reviewer runs on a locked-down network | Add reviewer note: "Requires two devices on same WiFi for full functionality; reviewer can verify UI, permission prompts, and the pairing QR generation on a single device." |
| Testers don't see the build | Processing not done yet, or you haven't added them to a testing group | Wait and re-check under TestFlight → Internal or External Testing |

---

## Summary — what lives where

| What | Where | Gitignored? |
|---|---|---|
| Team ID | `Signing.xcconfig` | ✅ yes |
| Bundle identifier | `project.yml` | no (public-safe) |
| Version / build number | `project.yml` (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`) | no |
| App icons | `Resources/Assets.xcassets/AppIcon.appiconset/` | no |
| Privacy manifest | `Resources/PrivacyInfo.xcprivacy` | no |
| Export compliance answer | `Resources/Info.plist` (`ITSAppUsesNonExemptEncryption: false`) | no |
| Provisioning profiles / certificates | Managed by Xcode automatically | n/a |
