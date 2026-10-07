# Fn Mute

**Hold Fn. Mute your Mac. Release Fn. Bring your sound back.**

Fn Mute is a free, open-source macOS menu-bar app released under the [MIT License](LICENSE). It keeps music and other system audio from interfering with your microphone while you use speech-to-text apps such as Gemini.

**[Download the latest release for macOS](https://github.com/fordft/FnMute/releases/latest)**

## The problem

Push-to-talk dictation is convenient, but music playing through your speakers can be picked up by the microphone and reduce transcription accuracy. Manually muting and unmuting the Mac interrupts the workflow.

Some dictation apps also clear macOS's global Fn modifier flag after recording starts. A helper that relies on that flag can restore sound too early, while you are still holding Fn and speaking.

## The solution

Fn Mute listens for **physical Fn press and release values from the keyboard**. It keeps sound muted until you actually release Fn, even if a dictation app changes the system's modifier flags.

- Mutes the current output while Fn is held and restores the previous settings on release.
- Preserves sound that was already muted.
- Leaves Fn available to your dictation app and never mutes the microphone.
- Runs in the menu bar with pause, test, and quit controls.
- Enables **Launch at Login automatically** when opened from Applications for the first time.
- Restores sound on normal quit and sleep, with a local recovery journal for interrupted sessions.
- Works entirely locally, with no account, subscription, or network connection.

## Install

1. Download the **universal DMG** from [Releases](https://github.com/fordft/FnMute/releases/latest).
2. Open the DMG and drag **Fn Mute** into **Applications**.
3. Open Fn Mute from Applications once.
4. Follow the app's prompt to enable **Fn Mute** in **System Settings → Privacy & Security → Input Monitoring**. If macOS asks, choose **Quit & Reopen**.

The speaker + **Fn** menu-bar icon shows that the app is running. Hold Fn while speaking; release it when finished. No installer script or Terminal command is needed.

### First-launch security notice

The current release is **ad hoc signed and not notarized with an Apple Developer ID**. macOS may block the first launch. If you choose to allow this app, use **System Settings → Privacy & Security → Open Anyway**, following [Apple's instructions](https://support.apple.com/guide/mac-help/mh40616/mac).

### Automatic startup

Launch at Login is enabled by default on the first launch from Applications, using macOS's native login-item service. It starts when you sign in after restarting your Mac. You can switch it off from the app's **Launch at Login** menu item.

If macOS requires approval for the login item, select **Open Login Items Settings** from the app's menu and allow Fn Mute. macOS controls this approval; the app cannot override it. Quit closes the app for the current session; it does not turn off the next login's startup.

## Requirements

- **macOS 13 Ventura or later.**
- **Apple Silicon or Intel Mac.** One universal download supports both.
- A keyboard that reports the Apple **Fn/Globe** key to macOS.
- Input Monitoring permission for physical Fn events.

The app mutes the default sound output and the system-sound output. Some HDMI/DisplayPort or other outputs have no system mute or volume controls; these cannot be muted, and the menu shows an explanation. Audio routed by an application to a separate output device is outside these default outputs.

## Privacy

Only the Apple Fn key elements are placed in the input-value queue. The app does not collect other key presses, typed text, microphone audio, or screen content. It does not use the network.

A small local log records Fn transitions and app lifecycle events. Settings and sound recovery data are stored under `~/Library/Application Support/FnMute`.

## Troubleshooting

- **Nothing mutes:** Check Input Monitoring permission and confirm that Fn Mute is running in the menu bar. Use **Test mute for 2 seconds** to check the current output separately from the keyboard.
- **The app disappeared after granting permission:** Reopen Fn Mute from Applications if macOS did not reopen it automatically.
- **No supported Fn key is detected:** Use the Mac's built-in keyboard or a keyboard that reports the Apple Fn/Globe usage. Many third-party keyboards handle Fn internally and never send it to macOS.
- **Updating:** Quit the old version before replacing it in Applications. macOS may ask you to approve Input Monitoring again for an updated, ad hoc signed build.

To uninstall, turn off **Launch at Login**, quit Fn Mute, and move the app to Trash.

## Build from source

Install Xcode or the Xcode Command Line Tools, then run:

```sh
git clone https://github.com/fordft/FnMute.git
cd FnMute
python3 scripts/test.py
python3 scripts/build.py
```

The universal application is created at `dist/Fn Mute.app`. The app itself has no third-party runtime dependencies.

To generate the drag-and-drop DMG, app ZIP, and SHA-256 checksums:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r scripts/requirements-build.txt
.venv/bin/python scripts/package_release.py
python3 scripts/verify_release.py
```

The packaging dependencies are build tools only. GitHub Actions runs the Fn regression tests, builds both architectures, and packages the app on every push to `main` and pull request.

### Developer ID signing and notarization

Maintainers with a Developer ID Application certificate can set `FN_MUTE_SIGNING_IDENTITY` before running the build. To notarize, also set `FN_MUTE_NOTARY_PROFILE` to an existing `notarytool` Keychain profile before packaging. The packager submits the app and DMG, staples their tickets, and creates the downloadable archives and checksums.

Keep certificates, private keys, and authentication credentials out of the repository. See [Apple's distribution documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## License

[MIT](LICENSE). Free to use, modify, and share under the license's terms.
