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

# Require a responding emulator as well as the absence of the regular app.
# A failed adb command must not be mistaken for an empty package listing.
assert_isolated_device() {
  local state packages
  state=$(adb -s "$device" get-state)
  test "${state//$'\r'/}" = device
  packages=$(adb -s "$device" shell pm list packages dev.catatuang.catat_uang)
  packages=${packages//$'\r'/}
  if grep -Fxq 'package:dev.catatuang.catat_uang' <<< "$packages"; then
    echo 'Refusing an emulator containing the regular app' >&2
    exit 1
  fi
}
assert_isolated_device
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
# flutter drive may uninstall its integration package after a successful run.
# Package identity was checked in each prebuilt APK; the regular app must stay
# absent both before and after execution.
assert_isolated_device
