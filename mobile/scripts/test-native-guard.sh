#!/usr/bin/env bash
set -euo pipefail

source_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-native-ci.sh"
if [[ ${1:-} == --probe ]]; then
  scenario=$2
  device=emulator-5554
  # All adb access is mocked: this test never contacts a real device/server.
  adb() {
    if [[ $scenario == disconnected ]]; then return 1; fi
    if [[ $3 == get-state ]]; then
      if [[ $scenario == offline ]]; then echo offline; else echo device; fi
    else
      if [[ $scenario == package-query-failed ]]; then return 1; fi
      if [[ $scenario == regular ]]; then
        printf 'package:dev.catatuang.catat_uang\r\n'
      else
        printf 'package:dev.catatuang.catat_uang.integration\r\n'
      fi
    fi
  }
  # Source only the guard; never execute the actual integration runner.
  source <(sed -n '/^assert_isolated_device()/,/^}/p' "$source_script")
  assert_isolated_device
  exit 0
fi

for scenario in integration-only regular disconnected offline package-query-failed; do
  set +e
  bash "${BASH_SOURCE[0]}" --probe "$scenario"
  result=$?
  set -e
  if [[ $scenario == integration-only ]]; then
    test "$result" -eq 0
  else
    test "$result" -ne 0
  fi
  echo "Native guard passed: $scenario"
done
