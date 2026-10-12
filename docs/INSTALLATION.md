# Installation Guide — iPhone (from Windows, no Mac)

## 1. Get the IPA

Every push builds the app on a GitHub-hosted macOS runner (`.github/workflows/ios.yml`).

1. Open **GitHub → wezcrypt/VeilBrowse → Actions → iOS** and select the latest green run.
2. Under **Artifacts**, download **`WezCryptSecureStudio-ipa`** (you must be signed in to GitHub). It contains:
   - `WezCryptSecureStudio-<version>-<build>-unsigned.ipa`
   - `BUILD-INFO.txt` (bundle id, version, minimum iOS, architectures, Xcode version)
   - `SHA256SUMS.txt`
3. Verify the download in PowerShell:
   ```powershell
   Get-FileHash .\WezCryptSecureStudio-*-unsigned.ipa -Algorithm SHA256
   ```
   Compare the result with `SHA256SUMS.txt`.

Tagged builds (`v*`) and manual runs with *publish* also attach the same files to a **GitHub Release**.

## 2. Sign and install

The IPA is **unsigned**: iOS will not install it until it is signed. CI verifies that it contains no signature, an `arm64` binary, `MinimumOSVersion 17.0` and bundle id `com.wezcrypt.securestudio`.

**KravaSigner (or any re-signing tool):**
1. Import the unsigned IPA.
2. Choose your certificate (`.p12`) and provisioning profile (`.mobileprovision`).
3. Keep the bundle id `com.wezcrypt.securestudio` if your profile allows it. Otherwise let the signer change it. Keychain items, the background session and BGTask identifiers are per-app, so the app works under another bundle id. Re-signing under a new id creates a separate app with its own data, so keep one id.
4. Entitlements the app uses: none that require special Apple approval (no iCloud, no App Groups, no push). Background modes `fetch` and `processing` are declared in `Info.plist`.
5. Install the signed IPA and trust the profile in **Settings → General → VPN & Device Management** if your signing method requires it.

Free/7-day certificates work, but the app must be re-signed when they expire. Your data stays on the server, and the recovery key restores access.

## 3. First run

1. **Welcome** → *Get Started*.
2. **Connect Server**: address `https://studio.rextv.sbs`, username, password or API key, remote directory `iphone-backups`, timeout. Credentials go to the Keychain only.
3. **Test Connection** runs six real steps: trusted HTTPS + `/health` (with latency), authentication, account and free space (and existing vault fingerprint), uploading a 300 KB encrypted test file in two chunks verified by the server, downloading and decrypting it byte-for-byte, and deleting it. Success is shown only when every step passed. Otherwise the failing step shows the server's error.
4. **Encryption Setup**: generate a new recovery key (or enter an existing one to connect a new iPhone). Write it down offline. The app asks you to type its last group back before continuing.
5. **Permissions**: allow Photos access (*Full* is recommended; *Limited* backs up only the selected items).
6. **Start Backup**.

## 4. What to expect

- The first backup of a large library takes a long time. Keep the app open on Wi-Fi and charging for the fastest progress (screen auto-lock does not stop transfers already handed to iOS).
- In the background, iOS decides when the app may run. See *Background execution* in [ARCHITECTURE.md](ARCHITECTURE.md). **Do not swipe the app away** in the app switcher: iOS then cancels its background uploads until you open it again.
- Nothing is ever deleted from your Photos library.

## 5. Build locally (optional, needs a Mac)

```bash
open ios/WezCryptSecureStudio.xcodeproj    # Xcode 16+ (CI uses the latest stable)
# after adding/removing Swift files:
gem install xcodeproj && ruby ios/scripts/generate_xcodeproj.rb
```
