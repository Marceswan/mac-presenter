# Presenter automatic updates with Sparkle: design

Date: 2026-10-26. Status: approved by Marc in chat on 2026-10-26.
Target: the Presenter macOS app, its release tooling, and the repository license.

## Intent

Marc uses Presenter on several Macs. Today, each new version means a manual download of the DMG from GitHub and a drag to Applications on each Mac. After this work, one release command publishes a version, and every Mac gets it without any action.

## Decisions made by Marc

- **Updater:** Sparkle 2 (open source, MIT license, free).
- **Hosting:** GitHub Releases on `Marceswan/mac-presenter`. The repository became public on 2026-10-26 so that release assets download without authentication. A download of `Presenter-0.2.0.dmg` without a login returned HTTP 200.
- **Install behavior:** Presenter downloads an update in the background and installs it automatically when Presenter quits. There is no prompt.
- **License:** MIT. Add a `LICENSE` file at the repository root.

## Goals

1. Presenter checks the update feed on a schedule. When a newer version is available, it downloads the update in the background and installs it when the app quits. The next launch is the new version.
2. A **Presenter > Check for Updates...** menu item, after **About Presenter**, starts a check now and shows Sparkle's standard window.
3. One local command ships a release: build, sign, notarize, a signed one-item update feed, an annotated tag, a GitHub Release with the DMG and `appcast.xml`, and a check of the live feed.
4. The repository has an MIT `LICENSE` file.

## Non-goals

- CI or GitHub Actions releases. The signing secrets stay on the release Mac.
- Beta or staged channels, delta updates, and a Settings toggle for updates. These can come later.
- Changes to Conduit or to tooling shared with Conduit.

## Anti-goals (failure even if updates work)

- **An update window, alert, or relaunch while Presenter is in prompt mode or is listening.** A popup during a live talk is the worst failure. (Builder's call, not confirmed by Marc. It follows from what the app is for.)
- **The app gets network access.** The app promises that "the audio stays on this Mac," and today it has no `com.apple.security.network.client` entitlement. Keep it that way. Sparkle's Downloader XPC service does the network work.
- **The sandbox is turned off** to make Sparkle easier.
- **A bad release that a later release cannot fix.** Sparkle never downgrades, so a bad release is fixed by shipping a higher version. Do not delete a published release automatically.

## Constraints

### Starting point

- PR #1 (`pr/spry-walrus`) was merged into `main` on 2026-10-23 (merge commit `18b182b`). After the merge, `a956a3a` was pushed to `pr/spry-walrus`. That commit is the tagged `v0.2.0` (build 2), and it is not on `origin/main`. Start from `origin/main` and merge `origin/pr/spry-walrus` so that `a956a3a` is an ancestor. (Corrected 2026-10-26: an earlier draft said that `main` did not have the PR. The local `main` had not been fetched.)
- The uncommitted branch `fix/sol-review-1-2-5-8` (from the old local `main`, `3aaf7c8`) has four review fixes. Move them onto the new base before the Sparkle work. Drop its fix #8 (the Info.plist version keys), because `a956a3a` already makes that change. PR #1 also changed `PrompterModel.swift`, so expect conflicts there.
- The new base has a `PresenterTests` app test target (Swift Testing). Put the new app tests there.

### Sparkle in a sandboxed app

Source: https://sparkle-project.org/documentation/sandboxing/

- Info.plist: `SUEnableInstallerLauncherService` = YES and `SUEnableDownloaderService` = YES.
- Entitlement `com.apple.security.temporary-exception.mach-lookup.global-name` = [`$(PRODUCT_BUNDLE_IDENTIFIER)-spks`, `$(PRODUCT_BUNDLE_IDENTIFIER)-spki`].
- Do not add `com.apple.security.network.client`.
- Do not put `--deep` in `OTHER_CODE_SIGN_FLAGS` or in a signing command. Verification with `codesign --verify --deep --strict` is fine.
- With the Downloader service, release notes fall back to the deprecated WebView. Keep the notes as plain, short HTML with no external content.

### Signing and export

- Today `scripts/release.sh` runs `xcodebuild archive` and copies the app out of the archive with `ditto`. Xcode's Code Sign on Copy re-signs `Sparkle.framework`, but not the XPC services and helpers inside it. Notarization can reject them.
- Use the method that already works in Conduit: `xcodebuild -exportArchive` with an export options plist (`method` = `developer-id`, `signingStyle` = `manual`, `signingCertificate` = `Developer ID Application`, `teamID` = `58XKRG9VMA`). Reference: `~/Documents/Code/conduit-macos/scripts/mac-release.sh` and `scripts/mac-export-options.plist`.
- Keep all of the current checks in `release.sh`: version match, Developer ID authority, hardened runtime, no `get-task-allow`, notarization of the app and the DMG, and Gatekeeper. Add a check that `Installer.xpc`, `Downloader.xpc`, `Autoupdate`, and `Updater.app` in the exported app have the Developer ID authority and the hardened runtime.

### Update feed and keys

- `SUFeedURL` = `https://github.com/Marceswan/mac-presenter/releases/latest/download/appcast.xml`. Each release uploads a one-item `appcast.xml`, so "latest" always serves the newest feed. This is the same method as Conduit.
- `SUEnableAutomaticChecks` = YES (no permission prompt on second launch). `SUAutomaticallyUpdate` = YES. `SUScheduledCheckInterval` = 3600 (builder's call, the same as Conduit).
- Signing key: a new EdDSA key only for Presenter, from `generate_keys --account presenter`. Conduit's key in the login keychain uses the default account. Do not reuse it. Pass `--account presenter` to every Sparkle tool. The public key goes into `SUPublicEDKey`.
- Key backup is a manual step for Marc: `generate_keys --account presenter -x <file>`, store the file in the password manager, then delete the file. If the key is lost, installed copies cannot accept new updates.
- Pin Sparkle 2.10.0 in `project.yml` (`exactVersion`), the same version as Conduit. 2.10.1 came out on 2026-10-25 and is too new (builder's call).
- The ship script gets `generate_appcast` and `generate_keys` from the Sparkle 2.10.0 release tarball and checks its SHA-256, as in Conduit's `mac-ship.sh`.

### The one-week reminder

- If an update is downloaded and the app does not quit for a week (`SUScheduledImpatientCheckInterval`), Sparkle can show a window that asks the user to install it.
- Presenter must not show it while in prompt mode or while listening (see the anti-goals). Use the Sparkle updater delegate and standard user driver delegate to defer this window. Show it only when the app is in edit mode and not listening, or never show it and wait for a quit. Builder's call: defer it to edit mode.
- If installation needs authorization, Sparkle downloads the update but does not install it. This is acceptable. It is not expected, because Presenter is in `/Applications` and Marc is an admin user.

### Tests and the updater

- Do not start the updater under XCTest or Swift Testing. Conduit uses the same rule.
- The first Sparkle build is 0.3.0, build 3 (builder's call). Copies of 0.1.0 and 0.2.0 have no updater. On each Mac, install 0.3.0 once from the DMG. Every later version arrives through Sparkle.

## Release flow

One command, for example `scripts/ship.sh [--minor|--major]` (default: patch). The builder chooses the name and whether it wraps `release.sh` or extends it.

1. Preconditions: on the release branch, clean tree, pushed, `gh` is logged in, the notary profile works, and the keychain key for `--account presenter` equals `SUPublicEDKey` in the built app.
2. Compute the next version from the newest `v*` tag (existing tags: `v0.1.0`, `v0.2.0`), and the build number as the previous build plus 1. Write both to `project.yml`, then commit and push the change. The release command is run by Marc, so these pushes are approved.
3. Build, sign, notarize, and staple the app and the DMG.
4. Make a signed one-item `appcast.xml` with `generate_appcast --account presenter`. Check that the feed names the new build.
5. Make an annotated tag `vX.Y.Z` and push it. Create the GitHub Release with the DMG and `appcast.xml`, marked latest.
6. Check the live feed URL and the DMG URL until both serve the new build (up to 60 seconds). If the check fails, leave the release in place and report the cause.

## Testing

- **App tests (PresenterTests):**
  - Info.plist has `SUFeedURL`, `SUPublicEDKey` (non-empty base64), `SUEnableAutomaticChecks` = YES, `SUAutomaticallyUpdate` = YES, `SUScheduledCheckInterval` = 3600, `SUEnableInstallerLauncherService` = YES, and `SUEnableDownloaderService` = YES.
  - The entitlements have the two mach-lookup names and do not have `com.apple.security.network.client`.
  - The updater does not start under tests.
  - The menu has **Check for Updates...**.
- **Deferral rule:** put the "can show update UI now" decision (inputs: mode, listening) in a small function and test all of its cases.
- **Release check:** `release.sh` checks the signatures of the Sparkle XPC services and helpers (see "Signing and export").
- **End to end, on a real Mac, by Marc:**
  1. Install 0.3.0 from the DMG.
  2. Ship 0.3.1.
  3. Within an hour (or after **Check for Updates...**), the update downloads with no window.
  4. Quit Presenter. On the next launch, the app is 0.3.1.
  5. Check that no update window appears while Presenter is in prompt mode.

## Left to the builder

- The exact Sparkle delegate methods for the deferral.
- The script names and structure, and the release notes content (short and plain).
- The README update: install, automatic updates, and the release steps.
