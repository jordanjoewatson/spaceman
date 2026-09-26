# Releasing Spaceman

Anyone can build Spaceman from source. Distributing an app that other Macs can
open without Gatekeeper warnings requires an Apple Developer account, a
Developer ID Application certificate, and notarization. A paid Apple Developer
Program membership is required.

## Prepare signing

Create a **Developer ID Application** certificate at
[developer.apple.com](https://developer.apple.com/account), then install it in
Keychain. Confirm that the identity is available:

```sh
security find-identity -v -p codesigning
```

The result should contain an identity such as:

```text
Developer ID Application: Your Name (TEAMID)
```

Create an [app-specific password](https://appleid.apple.com/account/manage),
then save the notarization credentials once:

```sh
xcrun notarytool store-credentials spaceman-notary \
  --apple-id you@example.com \
  --team-id TEAMID \
  --password app-specific-password
```

## Build and notarize

Set the stored profile and build the release:

```sh
export SPACEMAN_NOTARY_PROFILE=spaceman-notary
./build-app.sh --notarize
```

If more than one Developer ID identity is installed, select one explicitly:

```sh
export SPACEMAN_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
./build-app.sh --notarize
```

The build script signs the app, creates an archive, submits it for notarization,
staples the resulting ticket, and recreates `Spaceman.zip` for distribution.
