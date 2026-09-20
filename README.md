# BaseiOSApp

Run iOS apps on Apple Silicon Macs by loading their (converted) binaries into
minimal iOS / Mac Catalyst runtime apps.

## Architecture

One Xcode project (`iOSAppRunner.xcodeproj`), four targets:

| Target | Platform | Role |
| --- | --- | --- |
| `BaseiOSAppHost` | macOS (unsandboxed) | Management UI + everything privileged |
| `BaseiOSAppRuntime-Catalyst` | Mac Catalyst | Headless guest runtime (Catalyst UIKit) |
| `BaseiOSAppRuntime-iOS` | iOS ("Designed for iPad") | Headless guest runtime (iPad UIKit, JIT) |
| `dylibify` | macOS CLI tool | Standalone dylibify helper (build/verification) |

- **Host** (`Host/`): imports IPAs (extract → dylibify → unquarantine →
  `RunnerFeatures.plist` provisioning → scene-manifest injection → Catalyst
  build-version retarget), stores guests in the shared runtime container at
  `~/Library/Containers/<team>.dev.ohaiibuzzle.BaseiOSApp/Data/apps`, manages
  per-app settings (hooks, runtime mode `catalyst`/`ios`/`auto`, debugger
  attach), and launches the runtimes:
  - **Catalyst runtime**: direct `posix_spawn` with argv
    (`--launch-app <installName>`), falling back to `open -n --args`.
  - **iOS runtime**: iOS-platform binaries can't be exec'd directly on
    macOS, so the runtime is *wrapped* (Mac-iOS layout: outer `.app` with
    `Wrapper/<inner>.app` + a `WrappedBundle` symlink — Xcode emits exactly
    this as the `.XCInstall` product of Designed-for-iPad builds) and
    launched via LaunchServices (`open -n --args`). Because the runtime's
    LCDyld library-validation bypass — and guest JIT — only work while the
    process carries the debugger flag, the runtime is launched with
    `--wait-for-host`, SIGSTOPs itself at startup, and the host attaches
    (`task_for_pid` + `ptrace(PT_ATTACHEXC)`) then detaches (`PT_DETACH` +
    `SIGCONT`). No debugger remains attached. Disable the per-app
    "Attach host debugger" toggle only to debug the runtime itself.
- **Runtimes** (`Runtime/`): one shared source set, two targets. Both share a
  single bundle ID (`<team>.dev.ohaiibuzzle.BaseiOSApp`), so they share one
  sandbox container and keychain identity; guest data and keychain slots are
  identical no matter which runtime launched a guest. Headless: without a
  valid `--launch-app <name>` they log and exit 1. The Catalyst build-version
  retarget is applied once at import (iOS has no problem loading
  Catalyst-platform dylibs), so switching an app's runtime mode never
  re-converts it.
- Both runtime `.app` bundles are embedded in the host's Resources at build
  time (`BASEIOSAPP_RUNTIME_DIR` overrides the lookup for dev builds).

## Building

```sh
# Everything (host + both runtimes + embed):
xcodebuild -project iOSAppRunner.xcodeproj -scheme BaseiOSAppHost \
  -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates build

# Runtimes individually:
xcodebuild -project iOSAppRunner.xcodeproj -scheme BaseiOSAppRuntime-Catalyst \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' -allowProvisioningUpdates build
xcodebuild -project iOSAppRunner.xcodeproj -scheme BaseiOSAppRuntime-iOS \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

The host's "Embed Runtimes" script phase builds missing runtime variants into
`build/runtimes/` automatically. JIT enabling requires dev-signed runtimes
with `get-task-allow` (Debug builds; the iOS target keeps it in Release via
`Runtime/Runtime-iOS.entitlements`). The host strips quarantine/xattrs from
the runtime bundles before launching so Gatekeeper doesn't flag the
unnotarized dev-signed bundles as damaged.

`litehook` is a git submodule — run `git submodule update --init` after
cloning.
