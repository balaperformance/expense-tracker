# Latest Android build

`bash mobile/build_apk.sh` rebuilds this folder. It always holds only the newest release:

| File | Size | Use |
| --- | --- | --- |
| `ExpenseTracker-<version>-<date>-arm64.apk` | about 20 MB | **Send this one by email.** Installs on any 64-bit Android phone or tablet. |
| `ExpenseTracker-<version>-<date>.apk` | about 45 MB | Universal build for every CPU type. Too big for most email providers (Gmail allows 25 MB); share it through Drive or USB. |

To install: open the APK on the device and allow "Install unknown apps" for the app that opened it. It installs over an earlier build without losing data.

The APK files are not committed (see `mobile/.gitignore`).
