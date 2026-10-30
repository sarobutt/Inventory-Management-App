# Beauty Souq: inventory app (Flutter + Firebase)

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

**Import products from Excel:** open a store and tap ⬆ (upload icon) to import products into **that store**. Pick an `.xlsx` or `.csv` file and you get a preview showing which rows are new, which update existing products, and any rows that will be skipped. Choose **Replace stock** (after a stock take) or **Add to stock** (for a delivery), then tap **Import**. Products already in the store are matched by **SKU**, or by **name** if there's no SKU, so they're updated rather than duplicated. Companies and stores are always created in the app, never by import.

Columns (the first row must contain the headings, in any order):

| Product | SKU | Cost Price | Wholesale Price | Retail Price | Quantity | Reorder Level | Description |
|---|---|---|---|---|---|---|---|
| Nivea Soft Cream 200ml | 4005808890507 | 9.50 | 12.75 | 21.00 | 36 | 8 | |

Only **Product** is required. Common alternative headings also work (Name, Item, Code, Barcode, Cost/Unit Cost/Purchase Price for cost, Trade for wholesale, Price/RRP for retail, Qty, Stock). Empty price cells keep the product's current price. Ready-made templates are in [`templates/`](templates/). Old `.xls` files must be re-saved as `.xlsx`.

**Currency:** all prices are in **Qatari riyal (QAR)**, e.g. *QAR 32.00*. Price boxes and Excel files also accept "QAR", "ر.ق" or plain numbers.

**Three prices per product:**

| Price | Admin | Staff |
|---|---|---|
| **Cost price** | View and change | Hidden |
| **Wholesale price** | View and change | Hidden |
| **Retail price** | View and change | **View only** (on product cards and in tables/PDFs) |

Cost and wholesale prices are stored in a separate, admin-only part of the database (`productPrices`), so staff can't read them even with technical tools. Stock value is calculated at retail price. If you used the app before this change, each product's old single price becomes its **Retail** price automatically the first time an admin opens the app.

**Stock audit (admin):** every stock change is recorded automatically, including + / − taps, typed counts, approved staff requests, new products, quantity edits, Excel imports and deleted products. Each entry records **when, who did it (and who approved it), product, store, company, the change (+/−) and stock before → after**. Open it from the **🕘 history icon** on the home screen, **Profile → Stock audit**, a store's **⋮ → Stock history**, or a product's **🕘** icon.
- **Filters:** date (Today, 7 days, 30 days, This month, or custom dates), **user**, **company**, **store**, **product**, and **Added / Removed**.
- **Totals** for the filtered view: number of movements, units added, units removed and net change.
- **Print or share as PDF** with the filters shown in the header.
- Audit entries **can't be edited or deleted** by anyone, so the history can be trusted. Only admins can view it.
- Recording starts from the version that added the audit. Earlier approved staff requests are still in **Stock requests → History**.

**Approvals audit (admin):** the full history of staff stock requests. Open it from **Profile → Approvals audit**, the ✓ icon on **Stock requests**, or the ✓ icon on **Stock audit**.
- **Filters:** date (Today, 7 days, 30 days, This month, custom), **status** (Pending, Approved, Rejected, Cancelled, each with counts), **requested by**, **approved/rejected by**, **company**, **store**, **product**.
- **Summary:** total requests, approved, rejected, pending, **average response time**, and approved units added/removed.
- Each request shows who asked and when, the staff note, who approved or rejected it and when, how long it took, the reason, and stock before → after.
- **Print or share as PDF.**

**Purchase orders (admin):** for external customers buying products from you. Open it from the **Purchase orders** button on the home screen, or from **Profile**.
1. **+ Order:** enter the customer name, phone, email, their PO/reference and any notes. An order number is created automatically (e.g. PO-261030-4821).
2. **Add product** (search) or **Scan**: pick the product and the app lists **every store that holds it, with its stock**. Choose the store it comes from, the quantity (you can't order more than that store has) and the unit price, which defaults to Wholesale. The same product can come from two stores as separate lines.
3. **Amount** is calculated from the lines, and you can type a different invoice amount. Set **Payment: Not paid / Pending / Paid**.
4. **Upload invoice** (PDF, JPG or PNG, up to 8 MB), then view, share, replace or remove it.
5. **Save draft** keeps it without touching stock. **Complete order** checks stock and **subtracts it from each chosen store** in one step, and records it in the Stock audit as "Purchase order".
- Completed orders can still have their customer details, amount, payment status and invoice updated. **⋮ → Cancel & return stock** puts the stock back, which is also recorded in the audit. Drafts and cancelled orders can be deleted.
- The orders list has a search, status and payment filters, **Total** and **Unpaid** amounts, and print/share. Each order can be shared as a PDF.

**Moving products (admin):** if products were added to the wrong store or company, you can move them.
- **One product:** open it and tap the **move icon** (folder with arrow).
- **Several products:** go to the store's **⋮ → Move products…**, tick the products (or **Select all**), and tap **Move**.
- Choose the destination store, grouped by company. The company changes automatically with the store.
- Stock, all three prices, the reorder level and any pending staff requests move with the product.
- If the destination already has a product with the **same barcode**, choose **Merge stock** (its stock is added to the existing product and the copy is removed) or **Skip**.
- Every move is recorded in the **Stock audit** as stock leaving one store and arriving in the other.

**No duplicate products:** each barcode/SKU can only be used once per store. Scanning or typing a barcode that already exists in that store shows **"Product already exists"**, with an option to open the existing product, and saving a duplicate is blocked. The same product can still exist in different stores, each with its own stock. Excel imports update the existing product instead of creating a copy.

**Low stock and reordering:** each product has a **Reorder level** (default 5 if left empty).
- Stock **at or below** the level: the product card turns **amber**, labelled **"Needs ordering"**.
- Stock at **0**: the card turns **red**, labelled **"Out of stock: order now"**.
- The home screen, company pages and store pages show "**N products need ordering**". Tap it to see just those items.
- In **Tables → Products**, turn on **Needs ordering only** to get a reorder list you can print or share as a PDF. Low and out-of-stock rows are highlighted, with a **Stock status** column.

**Barcode scanning:** when adding or editing a product, tap **Scan barcode** (or the scan icon in the SKU field). The barcode number goes into **SKU**, and the product name is looked up automatically, in this order:
1. **Your own products** in any store (also fills in price and description). This has no limit.
2. [Open Beauty Facts](https://world.openbeautyfacts.org): a free database of cosmetics and personal-care products, with no limit.
3. [UPCitemdb](https://www.upcitemdb.com): general retail. The free tier allows about 100 lookups a day, and it's only used if the first two don't know the barcode.

If the barcode is already a product in the same store, the app offers to open that product instead of creating a duplicate. If nobody knows the barcode, type the name once, and every future scan of it fills in from your own products.

**Refresh:** pull down on any list or table to reload the latest data from the server.

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
flutter pub add firebase_core cloud_firestore pdf printing file_picker archive xml mobile_scanner http firebase_auth

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

## Branding (Beauty Souq)

The app is called **Beauty Souq**. Its logo is a souq (market) archway framing a lipstick, in plum, rose and gold. Source files are in [`branding/`](branding/).

- **Inside the app** (sign-in screen, home screen, PDF headers, colours): this is already part of the code.
- **Phone home-screen icon and name**: run this once on the Mac, from the project folder:
  ```bash
  ./scripts/apply_branding.sh
  ```
  It installs the icon on Android (including the round "adaptive" style) and iOS, and renames the app to "Beauty Souq". Then rebuild the app.

## Accounts and roles

The app now requires signing in with a **username and password**. Each account also has an email attached behind the scenes, which is used for "Forgot password".

| | **Admin** | **Staff** |
|---|---|---|
| View companies, stores, products, stock | ✅ | ✅ |
| See prices and stock value | ✅ | ❌ (hidden in the app, tables and PDFs) |
| Add, edit or delete companies, stores and products | ✅ | ❌ |
| Import from Excel | ✅ | ❌ |
| Change stock | ✅ directly | 📝 **Request**, which an admin approves or rejects |
| Print or share tables | ✅ | ✅ (without prices) |
| Approve requests, manage users | ✅ | ❌ |
| Own profile and change password | ✅ | ✅ |

**Stock requests:** staff tap a product (or scan it) and choose **Add stock** or **Remove stock**, a quantity and an optional note. The admin sees a badge on the home screen, opens **Stock requests**, and taps **Approve** (stock updates) or **Reject**. The **History** tab is a full record of who asked, who approved, and the stock before and after. Staff see their own requests and can cancel pending ones.

**Managing users (admin):** go to **Profile → Manage users → + User** and enter their name, username, email, starting password and role. From the same screen you can disable an account (it's blocked immediately), change a role, or send a password-reset email.

### One-time setup for accounts (do these in order)
1. **Turn on sign-in:** in Firebase Console, go to **Build → Authentication → Get started → Sign-in method → Email/Password → Enable → Save**.
2. **Publish the new rules:** copy [`firestore.rules`](firestore.rules) into **Firestore Database → Rules** and click **Publish**. Older copies of the app (without sign-in) will stop working from this point, which is intended.
3. **Update the app on the Mac:**
   ```bash
   git pull
   flutter pub add firebase_auth
   flutter run
   ```
4. On the sign-in screen, tap **Create admin account** (it only appears until the first admin exists). Your existing companies, stores and products are kept.
5. Add your staff under **Profile → Manage users**.

> Prices are hidden from staff everywhere in the app. Someone with technical skills could still read them from the database directly. If prices must be strictly secret, they can be moved to an admin-only collection later.

## Sending Android updates (no cable)

Use **Firebase App Distribution**. It's free and already part of your Firebase project.

**One-time setup**
1. In Firebase Console, go to **Release & Monitor → App Distribution** and click **Get started**. Choose the Android app.
2. Open the **Testers & Groups** tab, click **Add group**, and name it exactly `testers`. Add your email (and anyone else's).
3. On each phone, open the invite email, tap **Get started**, sign in with the same Google account, and follow the prompts. This installs the App Tester app, which notifies you of updates.
4. On the Mac, sign in once with `firebase login`.

**Every update**
```bash
./scripts/release_android.sh "Added Excel import"
```
This builds the APK, uploads it, and notifies everyone in the `testers` group. They tap **Update** on their phone, and their data stays as it is.

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
lib/brand.dart                             Beauty Souq name, colours and logo
lib/auth.dart                              sign-in, profiles, roles, user management
lib/orders.dart                            purchase orders, stock deduction, invoice files
lib/screens/orders_screen.dart             purchase orders list, filters, totals
lib/screens/order_form_screen.dart         create/complete order, store picker, invoice
lib/audit.dart                             stock audit trail (records every stock change)
lib/screens/audit_screen.dart              audit screen: filters, totals, print/PDF
lib/requests.dart                          staff stock requests + admin approval
lib/barcode.dart                           barcode lookup (own DB → Open Beauty Facts → UPCitemdb)
lib/screens/scanner_screen.dart            camera barcode scanner
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
flutter pub add pdf printing file_picker archive xml mobile_scanner http firebase_auth
flutter run
```

Then publish the new `firestore.rules` in Firebase Console → Firestore → Rules. Products created with the old version have no store, so delete them in Firebase Console → Firestore → Data → `products`.

## Security note

Without sign-in, anyone who has the app's Firebase config can read and change the data. The included rules only check that records are well-formed. This is fine for personal or internal use. Before a public release, add Firebase Authentication and tighten the rules.
