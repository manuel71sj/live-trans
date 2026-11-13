#!/bin/bash
# 무료 Apple 계정 서명은 7일 뒤 만료된다. 마지막 설치본 만료가 2일 안쪽으로 다가오면
# 새 프로파일로 다시 빌드해 iPhone에 덮어 설치한다(설정과 API 키는 유지된다).
# launchd(scripts/kr.manuel71.livetrans.refresh.plist)가 매일 실행한다.
#   LIVETRANS_DEVICE  설치할 iPhone UDID (xcrun devicectl list devices)
set -euo pipefail

: "${LIVETRANS_DEVICE:?LIVETRANS_DEVICE(iPhone UDID)를 지정하세요}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="$HOME/Library/Logs/LiveTrans"
STAMP="$STATE_DIR/installed-expiry"
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
APP="$REPO/build/ios/Build/Products/Debug-iphoneos/LiveTrans.app"
BUNDLE_ID="kr.manuel71.LiveTrans"
RENEW_BEFORE=$((2 * 24 * 3600))

# launchd는 셸 프로필을 읽지 않으므로 빌드 도구(xcodegen) 경로를 직접 잡는다.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$STATE_DIR"
log() { echo "[$(date '+%F %T')] $*"; }

# 프로파일 파일의 만료 시각(epoch 초)
profile_expiry() {
  local d
  d=$(security cms -D -i "$1" | plutil -extract ExpirationDate raw -o - -)
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$d" +%s
}

now=$(date +%s)
if [[ -f "$STAMP" ]] && (( $(cat "$STAMP") - now > RENEW_BEFORE )); then
  log "건너뜀: 설치본 만료 $(date -r "$(cat "$STAMP")" '+%F %T')"
  exit 0
fi

# Xcode는 아직 유효한 프로파일을 재사용하므로, 이 앱의 캐시 프로파일을 지워 새로 발급받는다.
shopt -s nullglob
for p in "$PROFILES"/*.mobileprovision; do
  if security cms -D -i "$p" | plutil -extract Entitlements.application-identifier raw -o - - | grep -q "\.$BUNDLE_ID$"; then
    rm "$p"
  fi
done

cd "$REPO"
log "빌드 시작"
xcodegen generate --quiet
xcodebuild -project LiveTrans.xcodeproj -scheme LiveTrans-iOS -configuration Debug \
  -destination "id=$LIVETRANS_DEVICE" -derivedDataPath build/ios \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build
xcrun devicectl device install app --device "$LIVETRANS_DEVICE" "$APP"

expiry=$(profile_expiry "$APP/embedded.mobileprovision")
echo "$expiry" > "$STAMP"
log "설치 완료: 만료 $(date -r "$expiry" '+%F %T')"
