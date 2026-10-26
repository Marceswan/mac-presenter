# Presenter Automatic Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Presenter on each of Marc's Macs downloads new releases in the background and installs them on quit, and one local command publishes a release.

**Architecture:** Sparkle 2.10.0 runs in the sandboxed app through its Installer and Downloader XPC services, so the app gets no network entitlement. A small `AppUpdater` owns the Sparkle controller and holds back any update window while Presenter is in prompt mode or listening. `scripts/ship.sh` wraps the existing `scripts/release.sh`, signs a one-item `appcast.xml` with a Presenter-only EdDSA key, and publishes both to GitHub Releases.

**Tech Stack:** Swift, SwiftUI, XcodeGen, Sparkle 2.10.0 (SPM), Swift Testing, bash, `gh`, `xcrun notarytool`.

**Spec:** `docs/superpowers/specs/2026-10-26-sparkle-auto-update-design.md`

## Global Constraints

- Sparkle: `https://github.com/sparkle-project/Sparkle`, `exactVersion: 2.10.0`. Tools tarball `Sparkle-2.10.0.tar.xz`, SHA-256 `c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c`.
- `SUFeedURL` = `https://github.com/Marceswan/mac-presenter/releases/latest/download/appcast.xml`
- `SUEnableAutomaticChecks` = YES, `SUAutomaticallyUpdate` = YES, `SUScheduledCheckInterval` = 3600, `SUEnableInstallerLauncherService` = YES, `SUEnableDownloaderService` = YES.
- Entitlement `com.apple.security.temporary-exception.mach-lookup.global-name` = [`$(PRODUCT_BUNDLE_IDENTIFIER)-spks`, `$(PRODUCT_BUNDLE_IDENTIFIER)-spki`]. Never add `com.apple.security.network.client`. The sandbox stays on.
- EdDSA key account: `presenter`. Pass `--account presenter` to every Sparkle tool. Do not use the default account (that key belongs to Conduit).
- No `--deep` in any signing command or in `OTHER_CODE_SIGN_FLAGS`.
- Tags: annotated `vX.Y.Z` with a `build=<n>` line. First Sparkle release: 0.3.0, build 3.
- No update window, alert, or relaunch while `model.mode == .prompt` or `model.isActive`.
- Do not publish anything (push to `main`, tag push, GitHub Release) without Marc's explicit go. Task 6 is gated on that.
- `codex-validation/` must never be committed: the repository is public and the folder names internal hosts.

## Review Focus

1. A downloaded update is deferred, then the speaker toggles prompt mode and listening several times. Expected: the reminder appears once, only after the app reaches edit mode with listening off. Test: Task 3, `deferredReminderWaitsThroughSeveralStateChanges`.
2. `ship.sh` runs again after it pushed the version bump but failed later. Expected: same version, no second bump commit. Test: Task 5, step "dry run after a bump".
3. The computed tag already exists (an earlier run pushed the tag and then failed). Expected: stop before any build, print the recovery commands. Test: Task 5, step "existing tag".
4. The Mac that runs `ship.sh` has no `presenter` key, or a key that differs from `SUPublicEDKey`. Expected: stop before any build. Test: Task 5, step "wrong key account".
5. The first scheduled check runs with no network. Expected: no window. Test: Task 6, manual step with Wi-Fi off.

---

### Task 1: New base branch with review fixes 1 and 2 and the MIT license

The old branch `fix/sol-review-1-2-5-8` is based on a stale local `main` and has uncommitted changes. Fixes 5 and 8 are already on the new base (`activate()` calls `stopListening()`; `a956a3a` sets the version keys). Port only fixes 1 and 2.

**Files:**
- Modify: `PresenterCore/Sources/PresenterCore/ScriptFollower.swift`, `PresenterCore/Sources/PresenterCore/TranscriptBuffer.swift`, and their two test files (from the patch)
- Modify: `Presenter/PrompterModel.swift` (`startListening()`)
- Create: `LICENSE`
- Add: `docs/superpowers/specs/2026-10-26-sparkle-auto-update-design.md`, `docs/superpowers/plans/2026-10-26-sparkle-auto-update.md`

**Interfaces:**
- Produces: `TranscriptBuffer.startSession()` (public, mutating). Drops volatile words and sets the baseline to the finalized word count.

- [ ] **Step 1: Save the core patch from the old branch (main checkout)**

```bash
cd /Users/marcswan/Documents/Code/presenter
git diff -- PresenterCore/ > "$SCRATCH/review-fixes-core.patch"   # $SCRATCH = the session scratchpad
grep -q '^codex-validation/$' .git/info/exclude || echo 'codex-validation/' >> .git/info/exclude
```

- [ ] **Step 2: Create the worktree on the new base**

```bash
git fetch origin
git worktree add .claude/worktrees/sparkle -b feat/sparkle-updates origin/main
cd .claude/worktrees/sparkle
git merge --no-edit origin/pr/spry-walrus
git merge-base --is-ancestor a956a3a HEAD && echo BASE-OK
```

Expected: `BASE-OK`.

- [ ] **Step 3: Apply the patch, change `startListening()`, and copy the docs**

```bash
git apply "$SCRATCH/review-fixes-core.patch"
mkdir -p docs/superpowers/specs docs/superpowers/plans
cp ../../../docs/superpowers/specs/2026-10-26-sparkle-auto-update-design.md docs/superpowers/specs/
cp ../../../docs/superpowers/plans/2026-10-26-sparkle-auto-update.md docs/superpowers/plans/
```

In `PrompterModel.startListening()`, replace `transcript.markBaseline()` with `transcript.startSession()`. Leave the call in `jump(to:)` as it is.

- [ ] **Step 4: Run all tests**

Run: `make test && make test-app`
Expected: all PresenterCore tests pass, including `finalTextMatchingVolatileTextDoesNotSkipRepeatedPhrase`, `speakingRepeatedPhraseAgainAdvances`, and `newSessionDropsUnfinishedTextWithoutHidingNewWords`. All PresenterTests pass.

- [ ] **Step 5: Add `LICENSE`**

Standard MIT text, copyright line `Copyright (c) 2026 Marc Swan`.

- [ ] **Step 6: Commit**

```bash
git add PresenterCore Presenter/PrompterModel.swift
git commit -m "Follow repeated phrases and keep new speech after a restart"
git add LICENSE docs
git commit -m "Add MIT license and the automatic updates design and plan"
```

---

### Task 2: Sparkle package, feed settings, sandbox entitlements, and the signing key

**Files:**
- Modify: `project.yml` (package, target dependency, `info.properties`, `entitlements.properties`)
- Regenerated by XcodeGen: `Presenter/Info.plist`, `Presenter/Presenter.entitlements`
- Create: `scripts/sparkle-tools.sh`
- Test: `PresenterTests/UpdateConfigurationTests.swift`

**Interfaces:**
- Produces: `scripts/sparkle-tools.sh`. It downloads `Sparkle-2.10.0.tar.xz` into `build/sparkle/2.10.0/` if absent, checks the SHA-256 from Global Constraints (deletes the file and exits 1 on mismatch), extracts it, and prints the absolute `bin` folder path on stdout. Task 5 uses it.

- [ ] **Step 1: Write the failing tests** in `PresenterTests/UpdateConfigurationTests.swift` (Swift Testing, `@MainActor struct UpdateConfigurationTests`, `@testable import Presenter`). Read `Bundle.main.infoDictionary`; the test host is the app.

```swift
@Test func feedAndPolicyKeys() {
    #expect(info["SUFeedURL"] as? String == "https://github.com/Marceswan/mac-presenter/releases/latest/download/appcast.xml")
    #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
    #expect(info["SUAutomaticallyUpdate"] as? Bool == true)
    #expect((info["SUScheduledCheckInterval"] as? NSNumber)?.intValue == 3600)
    #expect(info["SUEnableInstallerLauncherService"] as? Bool == true)
    #expect(info["SUEnableDownloaderService"] as? Bool == true)
}

@Test func publicKeyIsA32ByteBase64Key() throws {
    let key = try #require(info["SUPublicEDKey"] as? String)
    let data = try #require(Data(base64Encoded: key))
    #expect(data.count == 32)
}

@Test func sandboxEntitlementsAllowSparkleWithoutNetwork() throws {
    // Read with SecTaskCreateFromSelf + SecTaskCopyValueForEntitlement.
    #expect(entitlement("com.apple.security.app-sandbox") as? Bool == true)
    #expect(entitlement("com.apple.security.network.client") == nil)
    let names = try #require(entitlement("com.apple.security.temporary-exception.mach-lookup.global-name") as? [String])
    #expect(Set(names) == ["com.marcswan.Presenter-spks", "com.marcswan.Presenter-spki"])
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `make test-app`
Expected: the three tests fail (keys and entitlements missing).

- [ ] **Step 3: Write `scripts/sparkle-tools.sh`, then make the key**

```bash
BIN="$(scripts/sparkle-tools.sh)"
"$BIN/generate_keys" --account presenter        # first time only; prints the public key
"$BIN/generate_keys" --account presenter -p     # prints the public key again
```

macOS can ask for keychain access. Marc approves it.

- [ ] **Step 4: Change `project.yml`**

- `packages:` add `Sparkle: { url: https://github.com/sparkle-project/Sparkle, exactVersion: 2.10.0 }`. The `Presenter` target `dependencies:` add `- package: Sparkle`.
- `info.properties`: the six keys from Global Constraints, plus `SUPublicEDKey: <output of generate_keys -p>`. Use YAML `true` and `3600` so that the plist gets a boolean and an integer.
- `entitlements.properties`: add the mach-lookup array with the two `$(PRODUCT_BUNDLE_IDENTIFIER)` names.

Run `xcodegen generate`. Check the diff of `Presenter/Info.plist` and `Presenter/Presenter.entitlements`.

- [ ] **Step 5: Run the tests to see them pass**

Run: `make test && make test-app`
Expected: all pass.

- [ ] **Step 6: Marc backs up the key (manual, Marc only)**

```bash
"$(scripts/sparkle-tools.sh)/generate_keys" --account presenter -x ~/presenter-sparkle-key
# Store the file in the password manager, then:
rm ~/presenter-sparkle-key
```

Ask Marc to do this step. Do not continue to Task 6 before he confirms it.

- [ ] **Step 7: Commit**

```bash
git add project.yml Presenter/Info.plist Presenter/Presenter.entitlements scripts/sparkle-tools.sh PresenterTests/UpdateConfigurationTests.swift
git commit -m "Add Sparkle 2.10.0 with sandboxed installer and downloader services"
```

---

### Task 3: Updater, Check for Updates menu item, and no update UI during a presentation

**Files:**
- Create: `Presenter/AppUpdater.swift`
- Modify: `Presenter/PresenterApp.swift` (own the updater, add the menu item, report mode and listening changes)
- Test: `PresenterTests/AppUpdaterTests.swift`

**Interfaces:**
- Consumes: `PrompterModel.Mode` (`.edit`, `.prompt`), `PrompterModel.isActive`.
- Produces:
  - `@MainActor final class AppUpdater: NSObject` that conforms to `SPUUpdaterDelegate` and `SPUStandardUserDriverDelegate` and is `@Observable`.
  - `init(startingUpdater: Bool = !AppUpdater.isRunningTests, showDeferredUpdate: (() -> Void)? = nil)`. When `showDeferredUpdate` is nil, it calls the controller's `checkForUpdates(nil)`.
  - `static var isRunningTests: Bool`: `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`
  - `let started: Bool`, `private(set) var canCheckForUpdates: Bool` (KVO on `updater.canCheckForUpdates`)
  - `nonisolated static func mayShowUpdateUI(mode: PrompterModel.Mode, isListening: Bool) -> Bool`: true only for `.edit` and not listening.
  - `func checkForUpdates()`
  - `func presentationStateChanged(mode: PrompterModel.Mode, isListening: Bool)`. It stores the state. If a reminder is pending and the gate is now true, it clears the pending flag and calls `showDeferredUpdate`.
  - `func noteDeferredUpdate()` (internal). It marks a reminder as pending.
  - Sparkle delegate: `supportsGentleScheduledUpdateReminders` returns true. `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)` returns the gate for the stored state. When the gate is false, call `noteDeferredUpdate()`. Check the exact method signatures in the Sparkle 2.10.0 headers.

- [ ] **Step 1: Write the failing tests** in `PresenterTests/AppUpdaterTests.swift`

```swift
@Test func updateUIOnlyInEditModeWhenNotListening() {
    #expect(AppUpdater.mayShowUpdateUI(mode: .edit, isListening: false))
    #expect(!AppUpdater.mayShowUpdateUI(mode: .edit, isListening: true))
    #expect(!AppUpdater.mayShowUpdateUI(mode: .prompt, isListening: false))
    #expect(!AppUpdater.mayShowUpdateUI(mode: .prompt, isListening: true))
}

@Test func updaterDoesNotStartUnderTests() {
    #expect(AppUpdater.isRunningTests)
    #expect(!AppUpdater().started)
}

@Test func deferredReminderWaitsThroughSeveralStateChanges() {
    var shown = 0
    let updater = AppUpdater(startingUpdater: false, showDeferredUpdate: { shown += 1 })
    updater.presentationStateChanged(mode: .prompt, isListening: true)
    updater.noteDeferredUpdate()
    updater.presentationStateChanged(mode: .prompt, isListening: false)
    updater.presentationStateChanged(mode: .edit, isListening: true)
    #expect(shown == 0)
    updater.presentationStateChanged(mode: .edit, isListening: false)
    #expect(shown == 1)
    updater.presentationStateChanged(mode: .prompt, isListening: false)
    updater.presentationStateChanged(mode: .edit, isListening: false)
    #expect(shown == 1)
}

@Test func checkForUpdatesIsInTheAppMenuAfterAbout() throws {
    let appMenu = try #require(NSApp.mainMenu?.items.first?.submenu)
    let titles = appMenu.items.map(\.title)
    let check = try #require(titles.firstIndex(of: "Check for Updates\u{2026}"))
    let about = try #require(titles.firstIndex { $0.hasPrefix("About") })
    #expect(check > about)
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `make test-app`
Expected: compile failure, because `AppUpdater` does not exist.

- [ ] **Step 3: Implement `Presenter/AppUpdater.swift`** with the Interfaces above. Create `SPUStandardUpdaterController(startingUpdater:updaterDelegate:userDriverDelegate:)` with `self` as both delegates.

- [ ] **Step 4: Wire it in `PresenterApp.swift`**

- `@State private var updater = AppUpdater()` in `PresenterApp`.
- In `.commands`: `CommandGroup(after: .appInfo) { Button("Check for Updates\u{2026}") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates) }`
- In `MainWindowContent`, pass the updater. Call `updater.presentationStateChanged(mode: model.mode, isListening: model.isActive)` in `.onAppear` and in `.onChange` of `model.mode` and of `model.isActive`.

- [ ] **Step 5: Run the tests to see them pass**

Run: `make test && make test-app`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Presenter/AppUpdater.swift Presenter/PresenterApp.swift PresenterTests/AppUpdaterTests.swift
git commit -m "Add the updater and Check for Updates, and hold update windows during a presentation"
```

---

### Task 4: Release build exported through Xcode, with checks on Sparkle's signatures

**Files:**
- Create: `scripts/export-options.plist`
- Modify: `scripts/release.sh` (step 2 export, step 3 extra checks)

**Interfaces:**
- Produces: `scripts/release.sh` still writes `build/release/Presenter-<version>.dmg` and keeps its arguments (`[--skip-notarize]`). Task 5 calls it.

- [ ] **Step 1: Write `scripts/export-options.plist`**

Keys: `method` = `developer-id`, `signingStyle` = `manual`, `signingCertificate` = `Developer ID Application`, `teamID` = `58XKRG9VMA`. Reference: `~/Documents/Code/conduit-macos/scripts/mac-export-options.plist`.

- [ ] **Step 2: Change step 2 of `release.sh`**

After `xcodebuild archive`, run `xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/export-options.plist -exportPath "$OUT/export"`. Then `ditto "$OUT/export/Presenter.app" "$APP"`. This replaces the copy out of the archive.

- [ ] **Step 3: Add the Sparkle check to step 3 of `release.sh`**

For each of these paths under `$APP/Contents/Frameworks/Sparkle.framework/Versions/B/`: `XPCServices/Installer.xpc`, `XPCServices/Downloader.xpc`, `Autoupdate`, `Updater.app`:
- run `codesign -dvv` and capture the output before `grep` (the pipefail note that is already in the script applies);
- require `Authority=$IDENTITY` and `flags=0x10000(runtime)`;
- otherwise `fail "<component> is not signed with $IDENTITY and the hardened runtime"`.

- [ ] **Step 4: Run the unsigned pipeline**

Run: `scripts/release.sh --skip-notarize`
Expected: all checks pass and the script prints the DMG path.

- [ ] **Step 5: Run the full pipeline once (Apple notarization only; nothing is published)**

Run: `scripts/release.sh`
Expected: both notarizations end `Accepted`, and both Gatekeeper checks show `source=Notarized Developer ID`. This proves that Apple accepts the Sparkle XPC services before the first real ship.

- [ ] **Step 6: Commit**

```bash
git add scripts/export-options.plist scripts/release.sh
git commit -m "Export the release through Xcode and check Sparkle's signatures"
```

---

### Task 5: One-command ship script

**Files:**
- Create: `scripts/ship.sh`
- Modify: `Makefile` (target `ship: ; scripts/ship.sh`), `README.md` (automatic updates, the one-time manual install, the release steps, the key backup)

**Interfaces:**
- Consumes: `scripts/sparkle-tools.sh` (Task 2), `scripts/release.sh` (Task 4).
- Produces: `scripts/ship.sh [--minor|--major] [--dry-run]`. The environment variable `SPARKLE_ACCOUNT` defaults to `presenter`.

Behavior, in order (progress lines `::progress::<n>/6 <label>`, failures `ship: <reason>` to stderr with exit 1):

1. **Preconditions.**
   - Not dry run only: the branch is `main`, the tree is clean, and `HEAD` equals `origin/main` after `git fetch`.
   - Always: `gh auth status` works, `xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-conduit-notary}"` works, and `generate_keys --account "$SPARKLE_ACCOUNT" -p` succeeds and equals the `SUPublicEDKey` value in `project.yml`.
2. **Version.**
   - The previous tag is the newest `v*` tag (`sort -V`). The next version bumps the patch by default, or the minor or major with the flag.
   - The build number is the `CURRENT_PROJECT_VERSION` in `git show <prevtag>:project.yml`, plus 1.
   - If tag `v<next>` exists locally or on origin, fail and print: `git push origin :refs/tags/v<next> && git tag -d v<next>`, or "ship a higher version".
   - Dry run: print `ship: next version <v> (build <n>)` and whether `project.yml` already has these values, then exit 0.
3. **Bump.** If `project.yml` already has the version and build, skip this step. Otherwise update both lines, commit `Release <v> (build <n>)`, and push to `origin main`.
4. **Build.** Run `scripts/release.sh` and require `build/release/Presenter-<v>.dmg`.
5. **Feed.**
   - Stage the DMG and `Presenter-<v>.html`. The HTML is `<p>` lines of the HTML-escaped commit subjects since the previous tag, and has no external content.
   - Run `generate_appcast --account "$SPARKLE_ACCOUNT" --embed-release-notes --download-url-prefix "https://github.com/Marceswan/mac-presenter/releases/download/v<v>/" -o <stage>/appcast.xml <stage>`.
   - Require that the feed names `sparkle:version` `<n>`.
6. **Publish and check.**
   - `git tag -a v<v> -m "Presenter <v>" -m "build=<n>"`, then push the tag.
   - `gh release create v<v> <dmg> <stage>/appcast.xml -R Marceswan/mac-presenter --title "Presenter <v>" --notes-file <md> --latest`. If this fails, print the retry and abandon commands.
   - Poll the feed URL and the DMG URL 12 times at 5-second intervals until both serve build `<n>`. If they do not, leave the release in place and fail with what the feed lists. Reference: `~/Documents/Code/conduit-macos/scripts/mac-ship.sh`.

- [ ] **Step 1: Write `scripts/ship.sh`, the `Makefile` target, and the README sections**

- [ ] **Step 2: Dry run**

Run: `scripts/ship.sh --minor --dry-run`
Expected: `ship: next version 0.3.0 (build 3)`, exit 0.

- [ ] **Step 3: Dry run after a bump (Review Focus 2)**

Temporarily set `MARKETING_VERSION: "0.3.0"` and `CURRENT_PROJECT_VERSION: "3"` in `project.yml`, then run `scripts/ship.sh --minor --dry-run`.
Expected: the output says that `project.yml` already has 0.3.0 (build 3). Then `git checkout project.yml`.

- [ ] **Step 4: Existing tag (Review Focus 3)**

Run: `git tag v0.3.0 && scripts/ship.sh --minor --dry-run; git tag -d v0.3.0`
Expected: exit 1, with a message that names the tag and the recovery commands.

- [ ] **Step 5: Wrong key account (Review Focus 4)**

Run: `SPARKLE_ACCOUNT=no-such-account scripts/ship.sh --minor --dry-run`
Expected: exit 1, `ship:` message about the missing key, no build output.

- [ ] **Step 6: Run the full test suite and commit**

```bash
make test && make test-app
git add scripts/ship.sh Makefile README.md
git commit -m "Add one-command ship with a signed Sparkle feed"
```

---

### Task 6: Merge, ship 0.3.0, and test on real Macs (gated on Marc's go)

- [ ] **Step 1: Run the remote review** with the `codex-validation` skill (`remote-review.sh base origin/main`). Confirm each finding against the code. Fix the confirmed ones.
- [ ] **Step 2: Ask Marc for the go** to push `feat/sparkle-updates`, merge it into `main`, and ship. Do not continue without it. Also confirm that Marc backed up the key (Task 2, Step 6).
- [ ] **Step 3: Merge and ship.** Use the merge method Marc chooses (a PR as for PR #1, or a direct merge). Then on `main`: `scripts/ship.sh --minor`.
  Expected: `Shipped Presenter 0.3.0 (build 3)` and a live feed.
- [ ] **Step 4: Remove the worktree** after the merge: `git worktree remove .claude/worktrees/sparkle`, then `git branch -d feat/sparkle-updates`. Also delete `fix/sol-review-1-2-5-8` after Marc decides about its uncommitted `.gitignore` change.
- [ ] **Step 5: Manual checks (Marc, on real Macs)**
  1. On each Mac, install 0.3.0 from the DMG once.
  2. With Wi-Fi off, launch Presenter and wait 1 minute. No update or error window appears (Review Focus 5).
  3. Later, run `scripts/ship.sh` to make 0.3.1. On a Mac with 0.3.0: within an hour, or after **Check for Updates...**, the update downloads with no window.
  4. Quit Presenter. The next launch shows 0.3.1 in About.
  5. During a prompt-mode session, no update window appears.
