# Code signing & notarization

ClaudeSync is a no-sandbox macOS menu-bar app that opens an `NWListener`
for the Bonjour control channel. macOS' **application firewall** keys its
allow-list on an app's *stable Designated Requirement (DR)* — an
**ad-hoc** signature has none, so every rebuild looks like a brand-new
app: the firewall re-prompts (or, with "Block all incoming connections"
/ stealth mode, silently RSTs inbound connections, which kills the
pairing handshake). The fix is to ship a properly-signed binary.

There are two scopes:

| Build | Who runs it | Signing | Fixes |
|-------|-------------|---------|-------|
| `scripts/install.sh` (source build) | the user, on a Mac with Xcode + their Apple ID | **Apple Development** (automatic, team `G992TM2MX7`) — done automatically by `install.sh` when a code-signing identity is present | the firewall / Local Network / TCC churn on **that Mac** |
| `scripts/package.sh` → DMG (in `release.yml` on a `v*` tag) | GitHub Actions | **Developer ID Application** + **notarization** — only when the repo secrets below are set; otherwise ad-hoc | the DMG that anyone (incl. the user's other Mac that has no Xcode) downloads — Gatekeeper-trusted, stable DR |

`install.sh` needs nothing extra — it detects an available identity via
`security find-identity` and builds with `CODE_SIGN_STYLE=Automatic
DEVELOPMENT_TEAM=G992TM2MX7 -allowProvisioningUpdates`. The notarized-DMG
path needs the following **GitHub repository secrets** (Settings → Secrets
and variables → Actions → New repository secret). Until they're all set,
`release.yml` produces an ad-hoc DMG exactly as before.

## Required secrets for the notarized DMG

| Secret | What it is | How to get it |
|--------|-----------|---------------|
| `CODESIGN_IDENTITY_NAME` | The exact name of the Developer ID Application certificate, e.g. `Developer ID Application: Sejun Kim (G992TM2MX7)` | Xcode → Settings → Accounts → select the team → Manage Certificates → if there's no "Developer ID Application", click `+` → "Developer ID Application". Then `security find-identity -v -p codesigning` shows the exact string in quotes. |
| `CODESIGN_CERT_BASE64` | That certificate **+ its private key** exported as a `.p12`, then base64-encoded | Keychain Access → My Certificates → right-click the "Developer ID Application: …" entry → Export → `.p12` (set a password). Then: `base64 -i cert.p12 \| pbcopy` (macOS) and paste as the secret value. |
| `CODESIGN_CERT_PASSWORD` | The password you set when exporting the `.p12` | — |
| `KEYCHAIN_PASSWORD` | Any throwaway string — used to create a temporary keychain on the CI runner | e.g. `openssl rand -base64 24` |
| `NOTARY_APPLE_ID` | The Apple ID email of an account on the `G992TM2MX7` team with the Developer Program membership | — |
| `NOTARY_TEAM_ID` | `G992TM2MX7` | — |
| `NOTARY_APP_PASSWORD` | An **app-specific password** for that Apple ID (not the account password) | https://account.apple.com → Sign-In and Security → App-Specific Passwords → `+` → name it "ClaudeSync notary". |

Once all seven are set, push a `v*` tag (or run the Release workflow
manually) and the DMG will be Developer-ID-signed, notarized, and
stapled — downloadable and openable without `xattr -d
com.apple.quarantine`.

## Local one-off notarized build (without CI)

```bash
xcrun notarytool store-credentials ClaudeSync \
    --apple-id you@example.com --team-id G992TM2MX7 --password <app-specific-pwd>
export CODESIGN_IDENTITY="Developer ID Application: Your Name (G992TM2MX7)"
export NOTARY_PROFILE=ClaudeSync
bash scripts/package.sh        # → dist/ClaudeSync-<version>.dmg, signed + notarized + stapled
```
