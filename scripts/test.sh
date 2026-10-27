#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,re,sys
best=None
for runtime,devs in json.load(sys.stdin)["devices"].items():
    m=re.search(r"iOS-(\d+)-(\d+)",runtime)
    if not m or (int(m.group(1)),int(m.group(2))) < (26,0): continue
    for dev in devs:
        if dev.get("isAvailable") and dev["name"].startswith("iPhone"):
            best=dev["udid"]; break
    if best: break
if not best: sys.exit(1)
print(best)')
rm -rf TestResults.xcresult
xcodebuild test \
  -project MoeReader.xcodeproj -scheme MoeReader \
  -destination "platform=iOS Simulator,id=$UDID" \
  -resultBundlePath TestResults.xcresult \
  CODE_SIGNING_ALLOWED=NO
