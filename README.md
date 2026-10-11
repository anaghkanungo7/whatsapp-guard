# WhatsApp Guard

A macOS menu bar app that hides the native WhatsApp app until you unlock it with a passcode or Touch ID. Other apps keep running and the Mac stays unlocked.

## Requirements

- macOS 13 or later.
- The official WhatsApp Mac app. WhatsApp Web is not supported.
- Apple silicon or Intel Mac.
- Touch ID hardware and enrollment if you want biometric unlocking. A passcode works without Touch ID.

## Install

### From a release

1. Download `WhatsApp-Guard-macOS.zip` from this repository's **Releases** page.
2. Unzip it and move **WhatsApp Guard.app** to `/Applications`.
3. Open the app. On first launch, choose and confirm a passcode of at least six characters. No default passcode is included.
4. Click the shield icon in the menu bar and enable **Launch at login**.

Release builds are ad hoc signed. They are not signed with an Apple Developer ID or notarized. macOS may block the downloaded app. If you have reviewed and trust the source, use **System Settings > Privacy & Security > Open Anyway**, or build it locally instead. Do not disable Gatekeeper system-wide.

If macOS requests approval for the login item, approve it in **System Settings > General > Login Items**.

### Build from source

Install Xcode or the Xcode Command Line Tools first. The project has no third-party dependencies.

```sh
xcode-select --install
git clone https://github.com/anaghkanungo7/whatsapp-guard.git
cd whatsapp-guard
chmod +x scripts/*.sh
./scripts/build.sh
./scripts/install.sh
```

The build creates `build/WhatsApp Guard.app` and runs the automated checks. The installer copies it into `/Applications` and opens the setup window. Existing Keychain credentials are preserved. If an older guard is running, quit it through its shield menu before installing an update.

The default build contains both Apple silicon and Intel executables. To build only for the current machine:

```sh
GUARD_ARCHS="$(uname -m)" ./scripts/build.sh
```

## Use

Open WhatsApp normally. When it is locked, the guard hides its windows and presents an unlock prompt. Enter your passcode or use Touch ID when available.

The guard locks WhatsApp:

- When you switch away from WhatsApp.
- After five minutes without keyboard or mouse activity while WhatsApp remains in front.
- When the display sleeps, the system sleeps, or the user session becomes inactive.
- When the guard starts or restarts.

Moving the mouse after it locks does not unlock it. Closing the unlock prompt leaves WhatsApp hidden. The menu provides **Unlock WhatsApp**, **Lock WhatsApp now**, **Change passcode**, **Launch at login**, and **Quit WhatsApp Guard**. Changing the passcode and quitting through the menu require authentication.

## How it works

The app observes application, display, and session events through `NSWorkspace`. It uses `NSRunningApplication.hide()` to hide WhatsApp, and shows opaque privacy curtains during the hide transition. A timer checks application state every 200 milliseconds and uses Core Graphics input-idle time for the five-minute lock.

Passcode verification uses PBKDF2-HMAC-SHA256 with a random 16-byte salt, 600,000 iterations, and a 32-byte derived key. The verifier is stored in the local macOS Keychain. The plaintext passcode is not saved. After five failed attempts, retries are delayed. The failed-attempt counter resets when the guard restarts.

Touch ID uses `LocalAuthentication`. Startup registration uses `SMAppService`. Accessibility and Screen Recording permissions are not required.

## Privacy

- No chat contents, contacts, screenshots, or WhatsApp files are read.
- No telemetry, analytics, network requests, or persisted activity logs are included.
- The passcode verifier remains in the local Keychain. No credential is bundled with the source or release.
- Build output and local data are excluded from Git.

## Limits

This app protects against casual viewing in an unlocked macOS session. It is not a system-enforced app lock and does not encrypt WhatsApp's local data. Force-quitting the guard bypasses protection. Brief exposure during window transitions, Spaces changes, or Mission Control cannot be ruled out.

Notifications are separate from WhatsApp's windows. To suppress incoming calls, use **WhatsApp > Settings > Notifications > Call notifications > Show notifications > Always off**, and disable **Play ringtone for incoming calls**. Configure message notifications and previews separately in WhatsApp or macOS. The guard does not change notification settings or end active calls.

## Test

```sh
./scripts/build.sh
./scripts/test.sh
```

Automated checks cover passcode acceptance and rejection, a PBKDF2-SHA256 known-answer vector, salt isolation, startup locking, the exact 300-second boundary, and remaining locked after input resumes.

Manual validation should check unlocking, switching away, reopening WhatsApp while locked, five minutes of real inactivity, sleep and wake, fullscreen, multiple displays, and launch at login. Touch ID needs a real enrolled fingerprint and cannot be verified by the automated checks.

## Uninstall

1. Disable **Launch at login** from the shield menu.
2. Quit the guard through its menu.
3. Move **WhatsApp Guard.app** to Trash.
4. Optionally remove **WhatsApp Guard passcode** from Keychain Access.

## License

MIT. See [LICENSE](LICENSE). This project is independent of WhatsApp and Meta.
