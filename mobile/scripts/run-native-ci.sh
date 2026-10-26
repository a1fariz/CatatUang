#!/usr/bin/env bash
set -euo pipefail

device="${ANDROID_SERIAL:?Run only on an explicitly selected disposable emulator}"
case "$device" in emulator-*) ;; *) echo 'A disposable emulator is required'; exit 1 ;; esac
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
api_exe="${NATIVE_TEST_API_EXE:-/tmp/catatuang-native-api}"
apk_dir="${RUNNER_TEMP:?CI temporary directory required}/catatuang-native-apks"
test -f "$apk_dir/account.apk"
test -f "$apk_dir/storage.apk"
export ORG_GRADLE_PROJECT_catatUangIntegrationTest=true

# Refuse an emulator containing the regular app, even if the runner was
# accidentally pointed at a developer's existing device.
test -z "$(adb -s "$device" shell pm path dev.catatuang.catat_uang | tr -d '\r')"
"$api_exe" > "${RUNNER_TEMP:-/tmp}/catatuang-native-api.log" 2>&1 &
api_pid=$!
trap 'kill "$api_pid" 2>/dev/null || true' EXIT
for attempt in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:18089/readyz; then break; fi
  sleep 1
done
curl --fail --silent http://127.0.0.1:18089/readyz
cd "$project_root/mobile"
timeout 8m flutter drive --no-pub --driver=test_driver/account_driver.dart --target=integration_test/account_backend_test.dart --use-application-binary="$apk_dir/account.apk" -d "$device" --dart-define=AUTH_TEST_API_URL=http://10.0.2.2:18089 --dart-define=INTEGRATION_TEST=true
timeout 8m flutter drive --no-pub --driver=test_driver/account_driver.dart --target=integration_test/native_storage_test.dart --use-application-binary="$apk_dir/storage.apk" -d "$device" --dart-define=INTEGRATION_TEST=true
adb -s "$device" shell pm path dev.catatuang.catat_uang.integration | grep '^package:'
test -z "$(adb -s "$device" shell pm path dev.catatuang.catat_uang | tr -d '\r')"
