#!/bin/bash
# Uses the prepared lifecycle fixture; never builds or starts collectors.
set -euo pipefail
OUT="${1:?prepared lifecycle output directory}"
LANGUAGE_NAME="${2:?en or zh-Hans}"
APPEARANCE="${3:?light or dark}"
CAPTURE_DIR="${4:?native capture output directory}"
TEST_HOME="$(cd "$OUT/empty-home" && pwd)"
CFFIXED_USER_HOME="$TEST_HOME" VG_LIFECYCLE_NATIVE_OUTPUT="$CAPTURE_DIR" VG_LIFECYCLE_APPEARANCE="$APPEARANCE" \
    "$OUT/LifecycleCheck.app/Contents/MacOS/LifecycleCheck" "$OUT/results" "$TEST_HOME" 1.0 -AppleLanguages "($LANGUAGE_NAME)"
