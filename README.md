# Inventory Management (Flutter + Firebase)

A native Android and iOS app for managing **companies → stores → products**, with stock counting. Data is stored online in **Firebase Cloud Firestore** and syncs live across devices. No sign-in required.

```
App
└── Companies          (many)
    └── Stores         (many per company)
        └── Products   (many per store, each with a stock quantity)
```

| | Companies | Stores | Products |
|---|---|---|---|
| **Create** | "+ Company" on home | "+ Store" on a company | "+ Product" on a store |
| **Read** | Home list with search and totals | Company page | Store page, with search by name or SKU |
| **Update** | ✏️ on a company page | ✏️ on a store page | Tap a product |
| **Delete** | 🗑 (also deletes its stores and products) | 🗑 (also deletes its products) | Long-press, or "Delete product" in the form |

**Stock counting:** on a store page, each product has **−  qty  +** buttons. Tap the number to type an exact count. Stock value (price × quantity) is totalled per store and per company.

**View mode and printing:** tap the 📊 table icon on the home screen (or the icon on a company or store page) to see **Companies**, **Stores** and **Products** as tables with totals. Filter by company or store, then:
- 🖨 **Print**: opens the Android/iOS print dialog, which also offers **Save as PDF**.
- **Share**: sends the table as a PDF by email, WhatsApp, Drive and so on.

---|---|---|
| **Create** | "+ Company" button | "+ Product" on a company page |
| **Read** | Searchable list with product counts, detail page | Listed on the company page |
| **Update** | ✏️ icon on a company page | Tap a product |
| **Delete** | 🗑 icon on a company page (also deletes its products) | ⊖ on the product row, or "Delete product" in the form |

**Import from Excel:** tap ⬆ (upload icon) on the home screen to import a whole spreadsheet, or on a store page to import straight into that store. Pick an `.xlsx` or `.csv` file and you get a preview showing which rows are new, which update existing products, and any rows that will be skipped. Choose **Replace stock** (after a stock take) or **Add to stock** (for a delivery), then tap **Import**. Missing companies and stores are created automatically. Existing products are matched by **SKU**, or by **name** if there's no SKU, within the same store.

Columns (the first row must contain the headings, in any order):

| Company | Store | Store Address | Product | SKU | Price | Quantity | Description |
|---|---|---|---|---|---|---|---|
| Acme Ltd | Hull City Centre | 12 Whitefriargate | Blue Widget | AC-001 | 4.99 | 120 | |

Only **Product** is always required. Common alternative headings also work (Qty, Stock, Name, Item, Code, Barcode, Cost, Shop, Branch). Ready-made templates are in [`templates/`](templates/). Old `.xls` files must be re-saved as `.xlsx`.

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
flutter pub add firebase_core cloud_firestore pdf printing file_picker archive xml

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
companies/{id}  name, description
stores/{id}     companyId → companies/{id}, name, address
products/{id}   companyId, storeId → stores/{id}, name, sku, price, quantity, description
```
Every record also has `createdAt` and `updatedAt`.

## Code layout

```
lib/main.dart                              app start + Firebase init
lib/data.dart                              models + all Firestore CRUD + stock counting
lib/report.dart                            table building + PDF print/share
lib/importer.dart                          Excel/CSV reading, matching, bulk writes
lib/screens/import_screen.dart             import: pick file, preview, import
lib/widgets.dart                           dialogs, stats, formatting
lib/screens/companies_screen.dart          home: company list + search + totals
lib/screens/company_detail_screen.dart     company + its stores
lib/screens/company_form_screen.dart       add / edit company
lib/screens/store_detail_screen.dart       store + its products + stock counter
lib/screens/store_form_screen.dart         add / edit store
lib/screens/product_form_screen.dart       add / edit / delete product
lib/screens/tables_screen.dart             view mode: tables, filters, print
firestore.rules                            database security rules
```

## Updating from the previous version

If you already cloned the earlier companies-and-products version:

```bash
git pull
flutter pub add pdf printing file_picker archive xml
flutter run
```

Then publish the new `firestore.rules` in Firebase Console → Firestore → Rules. Products created with the old version have no store, so delete them in Firebase Console → Firestore → Data → `products`.

## Security note

Without sign-in, anyone who has the app's Firebase config can read and change the data. The included rules only check that records are well-formed. This is fine for personal or internal use. Before a public release, add Firebase Authentication and tighten the rules.
