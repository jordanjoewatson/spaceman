# Spaceman

A complete UI environment built on top of MacOS spaces, including configurable Tiling Window Manager and status bars.

TODO: Explanation of status bars
TODO: Design choices
TODO: Suggested MacOS configurations to work with Spaceman

## Requirements

- macOS 14 or later
- Xcode 16 / Swift 6 (command-line tools are enough)

## Build and run

```sh
./build-app.sh          # Spaceman.app, signed
./build-app.sh --run    # rebuild, replace the running instance, launch
swift test              # unit tests (no app bundle)
```

The first launch asks for Accessibility (System Settings → Privacy & Security → Accessibility). Tiling starts as soon as it is granted.

`open Spaceman.app` will not restart an instance that is already running. Use `--run`, or quit from the menu-bar extra first.

Without a Developer ID, the script signs with Apple Development (this Mac only) or ad-hoc. Ad-hoc re-asks for Accessibility after every rebuild; if the checkbox looks ticked but tiling is paused:

```sh
tccutil reset Accessibility com.spaceman.app
```

## Deploy your own build

Anyone can build from source. Sharing a `.app` that other Macs will open without Gatekeeper warnings needs **your** Apple Developer account, a Developer ID certificate, and notarization. A paid membership is required.

1. At [developer.apple.com](https://developer.apple.com/account) create a **Developer ID Application** certificate and install it in Keychain. Confirm it is there:

   ```sh
   security find-identity -v -p codesigning
   ```

   You want a line like `Developer ID Application: Your Name (TEAMID)`. The Team ID is on the Membership page.

2. Create an [app-specific password](https://appleid.apple.com/account/manage) (not your Apple ID password) and store a notarytool profile once:

   ```sh
   xcrun notarytool store-credentials spaceman-notary \
     --apple-id you@example.com \
     --team-id TEAMID \
     --password app-specific-password
   ```

3. Notarize. The script signs with Developer ID if it is in Keychain, zips, submits, waits, staples the ticket, and re-zips:

   ```sh
   export SPACEMAN_NOTARY_PROFILE=spaceman-notary
   ./build-app.sh --notarize
   ```

   If more than one Developer ID is installed, pick one:

   ```sh
   export SPACEMAN_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
   ```

   Submission usually finishes in a few minutes. The stapled archive is `Spaceman.zip`.

## Plugins

Plugins are compiled in or out at build time. A plugin that is not selected is not in the binary.

```sh
./build-app.sh --list
./build-app.sh --plugins launcher,clipboard
./build-app.sh --without pomodoro
./build-app.sh --core-only
Spaceman.app/Contents/MacOS/Spaceman -plugins
```

## License

[MIT](LICENSE)
