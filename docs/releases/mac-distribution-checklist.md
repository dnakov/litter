# Mac Catalyst Distribution Checklist

The repo ships Mac Catalyst builds through two independent channels:

| Channel | Cert | Artifact | Destination | Run via |
|---|---|---|---|---|
| **Mac App Store** (TestFlight + ASC review) | Apple Distribution + 3rd Party Mac Developer Installer | `.pkg` | App Store Connect → Mac App Store | `make mac-testflight` / `mac-testflight.yml` / `mobile-release.yml` |
| **Direct distribution** (notarized) | Developer ID Application | `.dmg` (signed + notarized + stapled) | Anywhere (your site, GitHub Releases, etc.) | `make mac-direct-dist` / `mac-direct-dist.yml` |

Both archive from the same `LitterMac` scheme — same code, same Mac Catalyst
binary. The difference is purely signing + packaging + distribution.

You can ship via one channel, the other, or both. They don't share artifacts
because the signatures differ, but you can run both workflows on the same
commit and get equivalent functionality on both channels.

---

## Mac App Store / TestFlight flow

Scripts: `apps/ios/scripts/testflight-upload-mac.sh`
Make: `make mac-testflight` (or `make mac-release-prep` to stop after archive prep)
Manual CI: `.github/workflows/mac-testflight.yml`
Auto CI: `.github/workflows/mobile-release.yml` — `mac-release-prep` + `upload-mac-testflight`
fire on any push that triggers `release_ios`.

Both iOS and Mac platforms share one App Store Connect app record. iOS uploads
route to the iOS platform build list; the Mac `.pkg` routes to the macOS
platform build list.

### One-time App Store Connect setup

1. **Enable macOS as an additional platform** on the app record. In App Store
   Connect → your app → App Information, find the platform list and add
   "macOS". Without this, the first `.pkg` upload fails with "no platform configured."
2. **Apple Silicon Mac Availability**: leave the "Make this app available"
   checkbox checked with the dropdown on `Automatic (macOS 15.0)`
   (Distribution → Pricing and Availability). Apple uses this as the
   iPad-on-Mac fallback while your Catalyst build is in review, then
   auto-disables it the moment your first Catalyst version is approved.
   No manual cutover needed; no double listing. Only uncheck if you
   specifically want Mac users to have *no* install path during review.
3. **Create TestFlight beta groups** with the macOS platform enabled. If
   the existing groups are iOS-only, testers won't see the Mac build. Either
   toggle macOS on each group or create platform-specific ones and update
   `BETA_GROUP_NAMES`.
4. **File an export compliance declaration** for the Mac platform if your
   app uses encryption. The iOS declaration does not automatically cover Mac
   — each platform has its own.

### One-time signing setup

1. In the Developer Portal, create a **Mac App Store** provisioning profile
   for `com.sigkitten.litter`.
2. Make sure your team has both certs locally:
   - **Apple Distribution** (can be the same cert as iOS)
   - **3rd Party Mac Developer Installer** (Mac-only — required to sign
     the installer `.pkg` that App Store Connect accepts)
3. Export a single `.p12` bundle containing **both** certs + their private
   keys. `security import` installs everything in one call.

### GitHub secrets (release environment)

| Secret | Notes |
|---|---|
| `MAC_DIST_CERT_P12_B64` | base64 of the combined app+installer .p12 |
| `MAC_DIST_CERT_PASSWORD` | password set when exporting the .p12 |
| `MAC_APP_STORE_PROFILE_B64` | base64 of the `.provisionprofile` |

Reuses existing `ASC_*`, `IOS_APP_STORE_APP_ID`, `IOS_TEAM_ID`. Encode with
`base64 -i cert.p12 | pbcopy` on macOS.

---

## Direct distribution flow (Developer ID + notarization)

Scripts: `apps/ios/scripts/direct-dist-mac.sh`
Make: `make mac-direct-dist`
Manual CI: `.github/workflows/mac-direct-dist.yml`

Pipeline:
1. Archive `LitterMac` for Mac Catalyst.
2. Export with `method=developer-id` → produces a Developer ID-signed `.app`.
3. Verify the signature with `codesign` + `spctl` *before* spending minutes
   on notarization (catches missing-cert errors fast).
4. Wrap the `.app` in a `.dmg` via `hdiutil`.
5. Sign the `.dmg` itself with the Developer ID Application cert.
6. Submit the `.dmg` to Apple's notary service via `xcrun notarytool` (uses
   the same ASC API key as TestFlight — no separate Apple ID password needed).
7. Staple the notarization ticket onto the `.dmg`.
8. Final Gatekeeper assessment via `spctl` to confirm the artifact will
   actually launch offline.

Output: `apps/ios/build/direct-dist-mac/Litter-<version>-mac.dmg`.

### One-time signing setup

1. In the Developer Portal, create a **Developer ID Application** certificate.
   This is a *different* cert from anything used for App Store distribution.
2. *(Optional)* Create a **Developer ID provisioning profile** for
   `com.sigkitten.litter` if your entitlements include capabilities that
   demand a profile (APNs / iCloud / Push). Without a profile, those
   capabilities silently strip during signing and won't work in the
   notarized build. With a profile, EXPORT_SIGNING_STYLE flips to manual.
3. Export the cert + private key to a `.p12`. (No installer cert needed —
   `.dmg` is signed with the application cert, not an installer cert.)

### GitHub secrets (release environment)

| Secret | Notes |
|---|---|
| `MAC_DEVELOPER_ID_CERT_P12_B64` | base64 of the Developer ID Application .p12 |
| `MAC_DEVELOPER_ID_CERT_PASSWORD` | password for that .p12 |
| `MAC_DEVELOPER_ID_PROFILE_B64` | (optional) base64 of the Developer ID `.provisionprofile` — only needed if you have caps that require it |

Reuses existing `ASC_*`, `IOS_TEAM_ID`. Notarization uses the ASC API key
(`ASC_PRIVATE_KEY_PATH` + `ASC_KEY_ID` + `ASC_ISSUER_ID`) — no separate
notarytool credentials needed.

### Workflow inputs

The `Mac Catalyst Direct Distribution` workflow takes two inputs:

- **`attach_to_release`** — if you provide a tag name (e.g. `v1.4.0`), the
  workflow uploads the .dmg + .sha256 to that GitHub Release using
  `gh release upload --clobber`. Empty = skip the attach (just leave the
  .dmg as a workflow artifact).
- **`skip_notarization`** — for testing the build pipeline without burning
  time on the notary service. The .dmg won't pass Gatekeeper on other Macs.

### Local usage

```bash
# Full pipeline including notarization (needs ASC API key env vars)
ASC_PRIVATE_KEY_PATH=/path/to/AuthKey.p8 \
ASC_KEY_ID=ABC123 \
ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
make mac-direct-dist

# Build but skip notarization (for testing the script itself)
SKIP_NOTARIZATION=1 make mac-direct-dist
```

---

## Version / build-number coordination

- `MARKETING_VERSION` is read once from `apps/ios/project.yml`. All three
  release flows (iOS TestFlight, Mac TestFlight, Mac direct dist) read the
  same value. The iOS script owns the auto-bump; the Mac scripts read the
  already-bumped value on the same CI cycle.
- `BUILD_NUMBER` for TestFlight flows is resolved via `asc builds list` and
  incremented (max across platforms + 1, so iOS and Mac may skip numbers
  but never collide).
- For direct distribution `BUILD_NUMBER` defaults to `date +%Y%m%d%H%M`
  since there's no upload registry to query.
- The bump commit is created by the iOS `Commit TestFlight version bump`
  step. Mac flows don't commit (avoids a race with the iOS job).

## Known surprises / first-run things to watch

### Mac App Store

- **First-ever Mac upload** takes longer to process on ASC side than iOS
  (10-30 min is normal vs. iOS's 2-5 min). `WAIT_FOR_PROCESSING=1` may
  time out on the first one; subsequent uploads are faster.
- **"Missing CFBundleVersion (Mac)"** on upload usually means you didn't
  actually archive with the `variant=Mac Catalyst` destination — double
  check the archive logs.
- **"Installer signing failed"** = the `3rd Party Mac Developer Installer`
  cert isn't in the keychain. It's a separate cert from the Application
  signing cert even if bundled in the same `.p12`.
- **Categories differ per platform** — the first time you submit Mac for
  review, App Store Connect prompts you to pick a macOS category
  independently of the iOS one.

### Direct distribution

- **Notarization can take 5-30 minutes**. The script `--wait`s with a 30m
  default timeout. If it times out, the submission usually still succeeds;
  re-run with `SKIP_NOTARIZATION=1` first to verify the build, then
  separately check status with `xcrun notarytool history`.
- **"The signature does not include a secure timestamp"** = `codesign`
  ran without `--timestamp`. The script does include it; if you see this
  error, your local network probably blocked Apple's timestamp server.
- **Stapling can fail with "could not find altool"** if Xcode CLT is
  outdated — `sudo xcode-select --install` to refresh.
- **APNs / iCloud silently broken in the notarized build** = capability
  was stripped because no Developer ID provisioning profile was attached.
  Add `MAC_DEVELOPER_ID_PROFILE_B64` and the script switches to manual
  signing with the profile embedded.
- **Gatekeeper still complains after notarization** = the ticket wasn't
  stapled, OR you notarized the .app but distributed a different .dmg
  containing it. Always notarize and staple the *exact artifact you
  distribute*. The script does this for you on the .dmg.
