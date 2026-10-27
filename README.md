# Company Products (Flutter + Firebase)

A native Android and iOS app for managing companies and their products. Data is stored online in **Firebase Cloud Firestore** and syncs live across devices. No sign-in required.

| | Companies | Products (per company) |
|---|---|---|
| **Create** | "+ Company" button | "+ Product" on a company page |
| **Read** | Searchable list with product counts, detail page | Listed on the company page |
| **Update** | ✏️ icon on a company page | Tap a product |
| **Delete** | 🗑 icon on a company page (also deletes its products) | ⊖ on the product row, or "Delete product" in the form |

---

## Setup on a Mac (one time)

1. **Install Xcode** from the Mac App Store. Open it once and accept the licence. Then in Terminal:
   ```bash
   sudo xcodebuild -runFirstLaunch
   brew install cocoapods        # install Homebrew first from https://brew.sh if needed
   ```
2. **Install Android Studio** from https://developer.android.com/studio. Open it and let it install the Android SDK. Then go to **Settings → Languages & Frameworks → Android SDK → SDK Tools** and tick **Android SDK Command-line Tools**.
3. **Install Flutter.** In VS Code, install the **Flutter** extension, press **Cmd + Shift + P**, run **Flutter: New Project**, and when it asks, click **Download SDK**. Then add Flutter to your PATH when prompted, and restart VS Code.
4. Check everything is ready:
   ```bash
   flutter doctor
   flutter doctor --android-licenses   # press y to accept all
   ```
5. **Install the Firebase tools:**
   ```bash
   npm install -g firebase-tools          # needs Node.js from nodejs.org
   dart pub global activate flutterfire_cli
   ```
   If it warns that `~/.pub-cache/bin` isn't on your PATH, run:
   ```bash
   echo 'export PATH="$PATH:$HOME/.pub-cache/bin"' >> ~/.zshrc && source ~/.zshrc
   ```

## Get the project running

In VS Code: **Cmd + Shift + P → Git: Clone**, paste this repository's URL, and open the folder. Then in the VS Code terminal (**Ctrl + `**):

```bash
# 1. Generate the android/ and ios/ folders
flutter create --org com.companyproducts --platforms=android,ios .

# 2. Add Firebase packages
flutter pub add firebase_core cloud_firestore

# 3. Connect to YOUR Firebase project (opens a browser to sign in to Google)
firebase login
flutterfire configure
```

When `flutterfire configure` asks, pick your existing Firebase project and select **android** and **ios** (use the space bar to select, Enter to confirm). This creates `lib/firebase_options.dart` and registers the Android and iOS apps in Firebase for you.

**Firestore rules:** if you haven't done this yet, open Firebase Console → Firestore Database → Rules, paste in the contents of [`firestore.rules`](firestore.rules), and click **Publish**.

## Run it

- **Android:** start an emulator (Android Studio → Device Manager → ▶), or plug in your phone with USB debugging turned on.
- **iPhone simulator:** run `open -a Simulator`.

Then pick the device in the bottom-right of VS Code and press **F5**, or run:

```bash
flutter run
```

## Build installable files

**Android APK** (installs on any Android phone):

```bash
flutter build apk --release
```

The file appears at `build/app/outputs/flutter-apk/app-release.apk`. Send it to your phone and open it.

**iOS:**

```bash
flutter build ios --release
open ios/Runner.xcworkspace
```

In Xcode, go to **Runner → Signing & Capabilities**, choose your Apple ID as the Team, plug in your iPhone and press ▶. A free Apple ID works for testing on your own phone (the app expires after 7 days). Publishing to the App Store or TestFlight requires the Apple Developer Program ($99/year): use **Product → Archive** in Xcode.

## Troubleshooting

| Problem | Fix |
|---|---|
| `minSdkVersion ... cannot be smaller than 23` | In `android/app/build.gradle.kts`, set `minSdk = 23` |
| iOS: `CocoaPods ... requires a higher minimum iOS deployment target` | In `ios/Podfile`, uncomment the line and set `platform :ios, '15.0'`, then run `cd ios && pod install --repo-update && cd ..` |
| `Target of URI doesn't exist: 'firebase_options.dart'` | You haven't run `flutterfire configure` yet |
| App shows `permission-denied` | Publish the `firestore.rules` file in Firebase Console |
| `flutterfire: command not found` | Add `~/.pub-cache/bin` to your PATH (see Setup step 5) |

## Data model

```
companies/{id}  name, description, createdAt, updatedAt
products/{id}   companyId → companies/{id}, name, price, description, createdAt, updatedAt
```

## Code layout

```
lib/main.dart                              app start + Firebase init
lib/data.dart                              models + all Firestore CRUD
lib/widgets.dart                           dialogs, empty/error states
lib/screens/companies_screen.dart          company list + search
lib/screens/company_detail_screen.dart     company info + its products
lib/screens/company_form_screen.dart       add / edit company
lib/screens/product_form_screen.dart       add / edit / delete product
firestore.rules                            database security rules
```

## Security note

Without sign-in, anyone who has the app's Firebase config can read and change the data. The included rules only check that records are well-formed. This is fine for personal or internal use. Before a public release, add Firebase Authentication and tighten the rules.
