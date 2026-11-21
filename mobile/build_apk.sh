#!/usr/bin/env bash
# Builds the release APKs and keeps only the latest ones in mobile/apk/:
#
#   ExpenseTracker-<version>-<date>-arm64.apk   ~20 MB, fits an email attachment;
#                                              installs on any 64-bit Android phone/tablet
#   ExpenseTracker-<version>-<date>.apk         universal (all CPUs), ~45 MB, for
#                                              Drive/USB or very old 32-bit devices
#
# Usage (Git Bash, from anywhere):  bash mobile/build_apk.sh
# Release builds never auto-sign in, so these are the files to install and share.
set -euo pipefail

cd "$(dirname "$0")"
FLUTTER=/c/src/flutter/bin/flutter          # 3.22.1; D:/tools/flutter breaks the build
export JAVA_TOOL_OPTIONS="-Djdk.net.unixdomain.tmpdir=$USERPROFILE\\.gradle\\uds"

version=$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' pubspec.yaml)
stamp=$(date +%Y-%m-%d)
name="ExpenseTracker-${version}-${stamp}"
out=build/app/outputs/flutter-apk

"$FLUTTER" build apk --release
cp "$out/app-release.apk" "$out/universal.tmp.apk"

"$FLUTTER" build apk --release --split-per-abi --target-platform android-arm64

mkdir -p apk
rm -f apk/*.apk
mv "$out/universal.tmp.apk" "apk/${name}.apk"
cp "$out/app-arm64-v8a-release.apk" "apk/${name}-arm64.apk"

# flutter may rewrite this file; it must stay as committed.
git checkout -- analysis_options.yaml 2>/dev/null || true

ls -l apk/*.apk
