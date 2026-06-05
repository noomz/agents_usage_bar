# Release Setup: One-Time Credential Provisioning

This runbook lists everything a maintainer must set up **once** before the unattended release pipeline (`.github/workflows/release.yml`) can sign, notarize, staple, and publish a DMG on `v*` tag push.

Subsequent releases are then fully automated — push a `v0.2.0` tag, the workflow consumes the GitHub repository secrets named below and produces a notarized, stapled DMG attached to a GitHub Release plus an updated EdDSA-signed `appcast.xml` on the `gh-pages` branch.

## Two lanes: Apple-signed vs. free/unsigned

The release workflow auto-detects which lane to run based on whether the `DEVELOPER_ID_CERT_P12` secret is set:

| | **Free / unsigned lane** | **Signed lane** |
| --- | --- | --- |
| Apple Developer Program ($99/yr) | not required | required |
| Required setup steps | **Step 3 + Step 5 only** | Steps 1–5 |
| Secrets needed | `SPARKLE_ED_PRIVATE_KEY` only | all seven |
| First-launch UX | macOS Gatekeeper blocks once → user clicks **Open Anyway** in System Settings → Privacy & Security | clean, no warning |
| Sparkle auto-update | ✅ works (EdDSA, Apple-independent) | ✅ works |

**You can ship today with only the free lane.** Do **Step 3** (Sparkle keys) and confirm **Step 5** (Pages), skip Steps 1, 2, and 4. The workflow ad-hoc-signs the app so Sparkle's helper XPCs launch; the download is un-notarized so Gatekeeper prompts the user once.

When you later enroll in the Apple Developer Program, do Steps 1, 2, 4, add the secrets, and the **same workflow auto-upgrades** to the signed/notarized lane on the next tag — no workflow edits.

> Steps 1, 2, and 4 below are marked **(signed lane only)**. Skip them for a free release.

> **Sources:** all commands and secret names are verified against the Phase 6 research at [`.planning/phases/06-distribution-sign-notarize-dmg-sparkle-oss-hygiene/06-RESEARCH.md`](../.planning/phases/06-distribution-sign-notarize-dmg-sparkle-oss-hygiene/06-RESEARCH.md). When in doubt, that file is canonical.

## Prerequisites

- macOS 14+ developer machine with Xcode 16.x installed.
- Active **Apple Developer Program** membership (paid).
- An **Apple ID** with the **Account Holder** or **Admin** role on the Apple Developer team (required to create an App Store Connect API key).
- Administrative access (Settings → Secrets and variables → Actions) on the GitHub repository.
- The [`gh` CLI](https://cli.github.com) installed and authenticated (`gh auth status`) — optional but every step below has a `gh` command alongside the web-UI equivalent.

## The seven secrets at a glance

The release workflow reads exactly these GitHub repository secrets. Names are case-sensitive and must match verbatim.

| Secret name                       | Content                                              | Source step | Lane |
| --------------------------------- | ---------------------------------------------------- | ----------- | ---- |
| `DEVELOPER_ID_CERT_P12`           | Base64-encoded `.p12` (Developer ID Application cert + private key) | Step 1 | signed only |
| `DEVELOPER_ID_CERT_PASSWORD`      | The password you set when exporting the `.p12`       | Step 1 | signed only |
| `ASC_API_KEY_P8`                  | Raw text content of the `AuthKey_<KeyID>.p8` file    | Step 2 | signed only |
| `ASC_API_KEY_ID`                  | 10-character Key ID from App Store Connect           | Step 2 | signed only |
| `ASC_API_ISSUER_ID`               | UUID Issuer ID from App Store Connect (above the keys table) | Step 2 | signed only |
| `SPARKLE_ED_PRIVATE_KEY`          | Ed25519 (EdDSA) private key text emitted by `generate_keys -x` | Step 3 | **both** |
| `DEVELOPMENT_TEAM`                | 10-character Apple Developer team ID (Tab characters: alphanumeric) | Step 4 | signed only |

The free/unsigned lane needs only `SPARKLE_ED_PRIVATE_KEY`. The `DEVELOPER_ID_CERT_P12` secret is the lane switch: present → signed lane, absent → unsigned lane.

`SPARKLE_ED_PRIVATE_KEY` is the private half; the **public** half is pinned in [`Info.plist`](../AgentsUsageBar/Resources/Info.plist) as `SUPublicEDKey` (see Step 3).

`DEVELOPMENT_TEAM` is referenced from `ExportOptions.plist` as `$(DEVELOPMENT_TEAM)` so Xcode's "automatic" Developer ID signing knows which team's cert to use.

You **also** need to enable **GitHub Pages** so the `appcast.xml` Sparkle reads is served — see Step 5.

> **None** of these secrets should ever be committed to the repo, pasted into a chat log, or written to a shell history that is shared. Use the explicit `rm -f` cleanup commands shown after each export.

---

## Step 1 — Developer ID Application certificate (`DEVELOPER_ID_CERT_P12` + `DEVELOPER_ID_CERT_PASSWORD`) — *(signed lane only)*

> **Skip this step for a free/unsigned release.** It requires the paid Apple Developer Program.

### 1a. Create the certificate (if you don't already have it)

If you have a `Developer ID Application: <YOUR NAME> (TEAMID)` identity in Keychain Access already, skip to **1b**.

Otherwise: follow Apple's official flow at [developer.apple.com/account/resources/certificates/add](https://developer.apple.com/account/resources/certificates/add), choose **Developer ID Application**, upload a Certificate Signing Request (CSR) generated by Keychain Access (`Keychain Access → Certificate Assistant → Request a Certificate from a Certificate Authority → Save to disk`), then download the issued `.cer` and double-click to import it. The matching private key is generated on your Mac by the CSR step, so the imported cert pairs with it automatically.

### 1b. Export the cert + private key as a `.p12`

The `.p12` (PKCS#12) file bundles **both** the public certificate and the private key, encrypted with a password.

```bash
# Pick a strong export password. You will need it again as DEVELOPER_ID_CERT_PASSWORD.
EXPORT_PW='REPLACE_WITH_A_STRONG_RANDOM_PASSWORD'

# Replace the -n value with the EXACT common name shown in Keychain Access.
# It typically looks like: Developer ID Application: Your Name (ABCDE12345)
security export \
  -k ~/Library/Keychains/login.keychain-db \
  -t identities \
  -f pkcs12 \
  -o /tmp/developer_id.p12 \
  -P "$EXPORT_PW" \
  -n 'Developer ID Application: REPLACE WITH YOUR NAME (REPLACE_TEAMID)'
```

`security export` prompts via the Keychain UI for permission to access the private key — click **Always Allow** if you want the export to complete non-interactively in CI on this machine (this prompt is local-only; CI never sees Keychain).

### 1c. Base64-encode for GitHub secret storage

GitHub secrets are stored as opaque strings, so the binary `.p12` is base64-encoded.

```bash
# Encode and copy to clipboard (newline-stripped).
base64 -i /tmp/developer_id.p12 | tr -d '\n' | pbcopy
```

### 1d. Load into GitHub secrets

Web UI: **Settings → Secrets and variables → Actions → New repository secret**, name `DEVELOPER_ID_CERT_P12`, paste the clipboard.

Or with `gh`:

```bash
pbpaste | gh secret set DEVELOPER_ID_CERT_P12
echo -n "$EXPORT_PW" | gh secret set DEVELOPER_ID_CERT_PASSWORD
```

### 1e. Clean up local artifacts

```bash
rm -f /tmp/developer_id.p12
unset EXPORT_PW
```

---

## Step 2 — App Store Connect API key (`ASC_API_KEY_P8` + `ASC_API_KEY_ID` + `ASC_API_ISSUER_ID`) — *(signed lane only)*

> **Skip this step for a free/unsigned release.** Notarization requires the paid Apple Developer Program.

`notarytool` accepts either an app-specific password or an ASC API key. **Use the API key in CI** — app-specific passwords are tied to a single human's Apple ID, rotate per device, and violate least-privilege.

### 2a. Generate the key in App Store Connect

1. Go to [appstoreconnect.apple.com/access/integrations/api](https://appstoreconnect.apple.com/access/integrations/api) → **Keys** tab → **Team Keys**.
2. Click the **+** (Generate API Key) button.
3. Name: `agents-usage-bar notarization` (descriptive — your future self will thank you).
4. Access: **Developer** is the minimum role that lets the key sign in via `notarytool`. Do **not** grant Admin if you can avoid it.
5. Click **Generate**, then **Download API Key**. Apple lets you download the `.p8` exactly **once** — store it somewhere safe (a password manager works). If you lose it you'll have to revoke the key and create a new one.

The download is a file named `AuthKey_<KEY_ID>.p8`, where `<KEY_ID>` is a 10-character alphanumeric string.

### 2b. Grab the three values

| Value | Where to find it |
| --- | --- |
| `.p8` content | Open `AuthKey_<KEY_ID>.p8` in a text editor — copy the entire content including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` markers and any newlines between them. |
| Key ID | The 10-character string in the filename (also shown in the column on the Keys page). |
| Issuer ID | The UUID-format string shown **above** the Keys table on the same page, labeled "Issuer ID". |

### 2c. Load into GitHub secrets

Web UI: add three secrets named `ASC_API_KEY_P8`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`. Paste the values from 2b.

Or with `gh`:

```bash
# Replace path with where you saved the downloaded .p8
gh secret set ASC_API_KEY_P8 < ~/Downloads/AuthKey_REPLACE_KEY_ID.p8
echo -n 'REPLACE_KEY_ID' | gh secret set ASC_API_KEY_ID
echo -n 'REPLACE_ISSUER_UUID' | gh secret set ASC_API_ISSUER_ID
```

### 2d. Clean up local artifacts (optional but recommended)

Move the `.p8` from your `~/Downloads` folder into an encrypted password manager and `rm -f` the original. Don't leave it in your home directory unencrypted.

---

## Step 3 — Sparkle EdDSA key pair (`SPARKLE_ED_PRIVATE_KEY` + `SUPublicEDKey`)

Sparkle 2.x signs the DMG with an Ed25519 (EdDSA) private key in CI; the matching public key is pinned in the app's `Info.plist`. The app refuses to install any update whose appcast `sparkle:edSignature` does not verify against the pinned public key — this is what makes the auto-update channel tamper-evident.

### 3a. Get the Sparkle bin tools

Sparkle's helper binaries (`generate_keys`, `sign_update`, `generate_appcast`) ship in the SPM release ZIP rather than in your built app.

```bash
# Replace 2.9.2 with the version pinned in your Package.swift / .xcodeproj.
SPARKLE_VERSION='2.9.2'

curl -fsSL \
  "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-for-Swift-Package-Manager.zip" \
  -o /tmp/sparkle-spm.zip

unzip -q /tmp/sparkle-spm.zip -d /tmp/sparkle
```

The tools you need are at `/tmp/sparkle/bin/`.

### 3b. Generate the key pair

```bash
/tmp/sparkle/bin/generate_keys
```

The tool prints the **public** key (base64) to stdout and stores the **private** key in your macOS Keychain under the item name `https://sparkle-project.org`. Copy the public-key line that looks like:

```
A new keypair has been generated and stored in your keychain.
Add the following to your Info.plist:
<key>SUPublicEDKey</key>
<string>BASE64_PUBLIC_KEY_VALUE</string>
```

Paste `BASE64_PUBLIC_KEY_VALUE` into [`AgentsUsageBar/Resources/Info.plist`](../AgentsUsageBar/Resources/Info.plist) under the `SUPublicEDKey` key (Phase 6 Plan 06-02 wires this).

### 3c. Export the private key for CI

```bash
/tmp/sparkle/bin/generate_keys -x /tmp/sparkle_ed_private_key.txt
# Prompts y/n to confirm. Type y.
```

The exported file contains the EdDSA private key as text. Load it as a GitHub secret:

```bash
gh secret set SPARKLE_ED_PRIVATE_KEY < /tmp/sparkle_ed_private_key.txt
```

(Or web UI: paste the file content into a new secret named `SPARKLE_ED_PRIVATE_KEY`.)

### 3d. Clean up

```bash
rm -f /tmp/sparkle_ed_private_key.txt
rm -rf /tmp/sparkle /tmp/sparkle-spm.zip
```

**Important:** if you lose the private key from both the Keychain and CI, future releases cannot be auto-updated by existing installs — users would have to manually download a new DMG to bridge the gap. Back up the exported file to a password manager before you `rm -f` it.

---

## Step 4 — Developer Team ID (`DEVELOPMENT_TEAM`) — *(signed lane only)*

> **Skip this step for a free/unsigned release.** The unsigned lane ad-hoc-signs and never reads `ExportOptions.plist`.

`ExportOptions.plist` consumes this so Xcode's automatic signing knows which team's Developer ID cert to use.

### 4a. Find your team ID

It's a 10-character alphanumeric string. Either:

- Apple Developer portal: [developer.apple.com/account](https://developer.apple.com/account) → **Membership details** → "Team ID".
- Keychain Access: open your Developer ID Application cert, the common name is `Developer ID Application: Your Name (TEAMID)`. The string in parentheses is the team ID.
- Command line:
  ```bash
  security find-identity -p codesigning -v | grep 'Developer ID Application'
  # output ends with: "Developer ID Application: Your Name (ABCDE12345)"
  ```

### 4b. Load into GitHub secrets

```bash
echo -n 'REPLACE_TEAMID' | gh secret set DEVELOPMENT_TEAM
```

---

## Step 5 — Enable GitHub Pages for the appcast

Sparkle reads the `appcast.xml` over HTTPS from your GitHub Pages site. Without Pages enabled, the URL pinned in `Info.plist` (`SUFeedURL`) returns 404 and auto-update silently does nothing.

1. **Settings → Pages** on the repo.
2. Build and deployment **Source**: **Deploy from a branch**.
3. **Branch**: `gh-pages` (the release workflow creates and pushes to this branch; Phase 6 Plan 06-04 scaffolds it with an empty appcast so the URL resolves before the first release).
4. **Folder**: `/ (root)`.
5. Click **Save**.

Verify the published URL — it will be `https://<owner>.github.io/<repo>/`. The appcast will live at `https://<owner>.github.io/<repo>/appcast.xml`. Confirm this matches `SUFeedURL` in [`Info.plist`](../AgentsUsageBar/Resources/Info.plist) (Phase 6 Plan 06-02 sets it).

---

## Verification

**Free/unsigned lane:** you only need `SPARKLE_ED_PRIVATE_KEY` set and Pages enabled. `gh secret list` should show that one name; the workflow takes the unsigned lane automatically because `DEVELOPER_ID_CERT_P12` is absent.

**Signed lane:** once all seven secrets are loaded and Pages is enabled:

```bash
# List the configured secret names (values are write-only by design).
gh secret list
```

Expected (order may vary):

```
ASC_API_ISSUER_ID
ASC_API_KEY_ID
ASC_API_KEY_P8
DEVELOPER_ID_CERT_P12
DEVELOPER_ID_CERT_PASSWORD
DEVELOPMENT_TEAM
SPARKLE_ED_PRIVATE_KEY
```

If `gh secret list` shows all seven names exactly, and **Settings → Pages** shows your Pages site is published from `gh-pages`, the release pipeline is ready. Cutting a release is just:

```bash
git tag v0.2.0
git push origin v0.2.0
# The release.yml workflow runs unattended from this point.
```

## Cadence and rotation

| Credential | Rotation guidance |
| --- | --- |
| Developer ID cert | Apple-issued certs are valid ~5 years. Rotate when expiry approaches; export a fresh `.p12` (Step 1) and update `DEVELOPER_ID_CERT_P12` + `DEVELOPER_ID_CERT_PASSWORD`. |
| ASC API key | Rotate annually or whenever team membership changes. Revoke the old key in App Store Connect after the new one is loaded. |
| Sparkle EdDSA key | **Do not rotate** unless the private key is compromised. Rotating breaks update continuity for every installed app version that pins the old public key. |
| Team ID | Effectively permanent. |
| GitHub Pages | One-time toggle. |

If a secret is leaked, treat it as compromised: revoke + reissue + reload the GitHub secret immediately. For the Sparkle EdDSA key specifically, a compromise means an attacker who also controls the appcast URL could push a malicious update — rotate the key, force-push a new appcast signed with the new key, and accept that pre-rotation installs are stranded on the version they currently have.

## Related documents

- [`docs/entitlements.md`](entitlements.md) — what the signed binary actually requests at runtime
- [`SECURITY.md`](../SECURITY.md) — vulnerability disclosure policy
- [`.planning/phases/06-distribution-sign-notarize-dmg-sparkle-oss-hygiene/06-RESEARCH.md`](../.planning/phases/06-distribution-sign-notarize-dmg-sparkle-oss-hygiene/06-RESEARCH.md) — full research (notarytool flags, create-dmg pinning, appcast XML shape, pitfalls)
