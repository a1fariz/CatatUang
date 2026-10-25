# Catat Uang

Flutter mobile app for offline-first personal expense tracking.

## Run

Flutter SDK managed by Puro. Open a new terminal after setup so `flutter` and `dart` resolve from PATH.

```powershell
flutter pub get
flutter run
```

Android SDK and an emulator are installed on the development machine. An Android debug APK has been built and launched in the emulator; see `../riwayat.md` for device verification and remaining checks. On a new machine, install Android SDK Platform, Build-Tools, Platform-Tools, and an emulator from Android Studio SDK Manager.

Run checks:

```powershell
flutter analyze
flutter test
```

## Structure

- `lib/main.dart`: navigation, period summary, transaction list and form
- `lib/bill.dart`: bill model and recurrence date rules
- `lib/bills_screen.dart`: bill list, form, payment and deletion flows
- `lib/money_format.dart`: locale-aware currency input and display
- `lib/reminder_service.dart`: local notification permissions and scheduling
- `lib/settings.dart`, `lib/settings_screen.dart`: currency, period, notification and light/dark preferences; data controls
- `lib/transaction.dart`: transaction model
- `lib/transaction_repository.dart`: SQLite schema, migrations, and local persistence
- `lib/auth/`: HTTP akun, controller sesi, secure storage, dan layar daftar/login/logout
- `lib/sync/`: protokol transaksi, outbox SQLite, controller manual, dan pilihan konflik
- `test/`: Flutter, akun, dan SQLite tests
- `integration_test/account_backend_test.dart`: akun Android native dengan backend pengujian nyata
- `assets/`: app assets
- `android/`, `ios/`: mobile platform runners
- `web/`, `windows/`: Flutter-generated runners, not supported by current storage and notification dependencies
- `pubspec.yaml`: Flutter dependencies

Backend Go dan PostgreSQL tersedia di `../backend/`. Flutter menyediakan akun opsional serta [sinkronisasi transaksi manual](docs/transaction-sync.md) dengan persetujuan penautan. Pencatatan offline tetap tersedia; tagihan dan pembayaran masih lokal. Lihat [panduan akun](docs/account.md).

Jika pub get pada Windows meminta symlink untuk runner desktop yang bukan target proyek, gunakan environment proses `FLUTTER_WINDOWS=false` dan `FLUTTER_LINUX=false`; lihat panduan akun.

Build iOS only on macOS with Xcode.

Flutter SDK is managed in Puro's `stable` environment. If the `puro` command is unavailable in a shell opened before installation, open a new shell.

### Verification and limitations

Automated tests cover SQLite CRUD and migrations, persistence after closing and reopening a file database, calendar recurrence, notification reconciliation, and key UI flows. Reminder schedules are restored from SQLite on startup and resume without requesting notification permission. Stale schedules are cancelled; disabling reminders cancels all schedules.

Notification delivery, reboot behavior, and full offline flows still require Android device/emulator verification. Automated reminder tests use a fake service and do not prove operating-system delivery. iOS builds and device checks require macOS/Xcode.

The generated web and Windows runners are not MVP targets because the current database and notification setup is mobile-focused.

`puro create stable stable` sets up Flutter stable for this machine.
