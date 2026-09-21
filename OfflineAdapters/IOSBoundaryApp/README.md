# ReceiveBoundary — isolated iPad target

This standalone iOS 17+ app compiles the exact local adapter sources from `../SyntheticInitialReceive/Sources/SyntheticInitialReceive`. It has no remote package dependency or production AppEnvironment, credential, network, editor, sync or app-group connection. The existing WriterPad project is unchanged.

The candidate bundle identifier is `com.chocos.writerpad.receiveboundary`. This is source/build configuration, not an issued App ID, signing profile or installed app. Debug and Release explicitly disable signing. Only generic iOS Debug build has been verified in this stage.

```sh
xcodebuild -project OfflineAdapters/IOSBoundaryApp/IOSBoundaryApp.xcodeproj \
  -scheme ReceiveBoundary -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/receive-boundary-build \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build
```

This is a build reference, not permission to install or launch. The app is unsigned and has not been run on a device or simulator.

Startup only observes scene/application/protected-data events. The explicit synthetic-check button prepares `Library/Application Support/WriterPadReceiveBoundary-v1` inside the OS-provided app home and writes the bundled synthetic fixture through the physical boundary. It never imports an existing project or issues a real local UUID. All baseline/execution/edit/send capabilities remain closed.

Only a single scene is allowed. Inactivity, background, termination notification or protected-data loss revokes every current lease and the displayed readiness. Returning active/unlocked requires another explicit check. Worker file operations run off the main actor and check the thread-safe lease during file creation, read, write and completion; the main actor checks the same lease before publishing success.

New dedicated directories, lock, seal and pending files receive `FileProtectionType.complete`, with readback before payload bytes. Existing weaker/missing protection is rejected, not silently upgraded. Owner seal, five-part payloads and nine-record/head integrity retain the prior physical adapter's preserve-and-block policy for ambiguous partial writes.

Host tests use a fresh fake app home and inode-based protection double. They do not demonstrate actual iOS encryption, lock/unlock, suspension or power-loss behavior. See `Docs/ipad-ios-container-lifecycle-target-result-2026-09-14.md` at repository root for verification and remaining limits.
