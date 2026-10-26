#!/usr/bin/env bash
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${RUNNER_TEMP:?CI temporary directory required}/catatuang-native-apks"
mkdir -p "$output"
export ORG_GRADLE_PROJECT_catatUangIntegrationTest=true

build_target() {
  local target="$1" name="$2"
  shift 2
  flutter build apk --debug --no-pub --target-platform android-x64 --target "$target" --dart-define=INTEGRATION_TEST=true "$@"
  cp build/app/outputs/flutter-apk/app-debug.apk "$output/$name"
  local aapt
  aapt="$(find "${ANDROID_HOME:?}/build-tools" -mindepth 2 -maxdepth 2 -name aapt2 -type f | sort -V | tail -n 1)"
  "$aapt" dump badging "$output/$name" | grep -F "package: name='dev.catatuang.catat_uang.integration' "
  unzip -p "$output/$name" assets/flutter_assets/kernel_blob.bin > "$output/kernel-check.bin"
  grep -aFq "$target" "$output/kernel-check.bin"
  rm -f "$output/kernel-check.bin"
}

build_target integration_test/account_backend_test.dart account.apk --dart-define=AUTH_TEST_API_URL=http://10.0.2.2:18089
build_target integration_test/native_storage_test.dart storage.apk
# Release build memory before QEMU starts. Only this job's Gradle home is used.
(cd android && ./gradlew --stop)
