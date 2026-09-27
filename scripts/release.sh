#!/bin/bash
#
# 发布：Release 构建 → 校验签名 → 公证 → 装订 → 打包 zip/dmg。
#
# 只有在用 Developer ID Application 证书签名并公证之后，别人下载才不需要手动放行
# （`spctl -a -t exec -vv` 会输出 accepted / source=Notarized Developer ID）。
#
# 前置条件（只需做一次）：
#   1. 钥匙串里有 Developer ID Application 证书：
#      Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application。
#      只有付费 Apple Developer Program 的 Account Holder（个人）或 Account Holder / Admin
#      （组织）能签出这张证书；免费的 Apple ID 只有 Apple Development，做不了公证。
#   2. 公证凭据存进钥匙串：
#      xcrun notarytool store-credentials mbu-notary --keychain ~/Library/Keychains/login.keychain-db \
#        --apple-id <Apple ID> --team-id 55L6785UNH --password <App 专用密码>
#
# 用法：
#   bash scripts/release.sh                   # 完整流程
#   bash scripts/release.sh --skip-notarize   # 只构建 + 校验 + 打包（验证签名配置用，产物不能分发）
#
# 可覆盖的环境变量：
#   MBU_TEAM_ID / MBU_SIGN_IDENTITY / MBU_NOTARY_PROFILE / MBU_NOTARY_KEYCHAIN / MBU_DIST_DIR
# 例：MBU_TEAM_ID= bash scripts/release.sh --skip-notarize   # 用 base 里的自签名身份构建

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="MacBleUnlock"
TEAM_ID="${MBU_TEAM_ID-55L6785UNH}"
NOTARY_PROFILE="${MBU_NOTARY_PROFILE-mbu-notary}"
# 显式给 notarytool 指定钥匙串：不给的话它有时找不到自己存过的那条凭据（本机实测：
# 同一个 profile 直接 `notarytool history` 报 no item，带上 --keychain 就能用）。
NOTARY_KEYCHAIN="${MBU_NOTARY_KEYCHAIN-$(security default-keychain -d user | tr -d ' \"')}"
DIST_DIR="${MBU_DIST_DIR-dist}"
DERIVED_DATA="build/release-derived-data"
APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"

SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    *) echo "错误：未知参数 ${arg}（只支持 --skip-notarize）" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
die() { printf '\n错误：%s\n' "$*" >&2; exit 1; }

# ---- 1. 前置检查 -----------------------------------------------------------

for tool in xcodegen xcodebuild xcrun security plutil; do
  command -v "$tool" >/dev/null || die "找不到 $tool"
done

IDENTITY="${MBU_SIGN_IDENTITY-}"
if [[ -z "$IDENTITY" ]]; then
  [[ -n "$TEAM_ID" ]] || die "MBU_TEAM_ID 为空且未指定 MBU_SIGN_IDENTITY，无法解析签名身份。"
  CERT_LINE="$(security find-identity -v -p codesigning \
    | grep -F '"Developer ID Application: ' | grep -F "($TEAM_ID)" | head -1 || true)"
  [[ -n "$CERT_LINE" ]] || die "钥匙串里没有 team $TEAM_ID 的 Developer ID Application 证书。
去 Xcode → Settings → Accounts → Manage Certificates → + 签一张，
或 developer.apple.com → Certificates（需要 Account Holder / Admin 角色）。"
  # 取引号里的证书全名，后面用它做精确的签名身份（同名多张证书时也不会签错）。
  IDENTITY="$(sed -E 's/^[^"]*"(.*)".*$/\1/' <<<"$CERT_LINE")"
fi

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  [[ "$IDENTITY" == "Developer ID Application: "* ]] \
    || die "身份「${IDENTITY}」不是 Developer ID Application，公证必然被拒。"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --keychain "$NOTARY_KEYCHAIN" >/dev/null 2>&1 \
    || die "取不到公证凭据「${NOTARY_PROFILE}」。先执行：
xcrun notarytool store-credentials $NOTARY_PROFILE --keychain $NOTARY_KEYCHAIN \\
  --apple-id <Apple ID> --team-id ${TEAM_ID:-<TEAM_ID>} --password <App 专用密码>"
fi

echo "签名身份：$IDENTITY"
echo "Team ID：${TEAM_ID:-（未指定）}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mbu-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- 2. 构建 ---------------------------------------------------------------

step "生成工程（xcodegen）"
xcodegen generate

step "Release 构建"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
  build

[[ -d "$APP" ]] || die "构建产物不存在：$APP"

# ---- 3. 校验签名 -----------------------------------------------------------

step "校验签名"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

SIGN_INFO="$(codesign -dvvv "$APP" 2>&1)"
AUTHORITY="$(sed -n 's/^Authority=//p' <<<"$SIGN_INFO" | head -1)"
SIGNED_TEAM="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGN_INFO" | head -1)"
FLAGS="$(sed -n 's/^CodeDirectory .* flags=//p' <<<"$SIGN_INFO" | head -1)"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"

echo "    Authority=$AUTHORITY"
echo "    TeamIdentifier=$SIGNED_TEAM"
echo "    flags=$FLAGS"
echo "    version=$VERSION"

[[ "$AUTHORITY" == "$IDENTITY" ]] || die "签名身份不符：期望「${IDENTITY}」，实际「${AUTHORITY}」"
[[ "$FLAGS" == *runtime* ]] || die "没有 hardened runtime（公证强制要求）：flags=$FLAGS"
if [[ -n "$TEAM_ID" ]]; then
  [[ "$SIGNED_TEAM" == "$TEAM_ID" ]] || die "TeamIdentifier=${SIGNED_TEAM}，与期望的 ${TEAM_ID} 不符"
fi
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  die "产物带 get-task-allow（可被 task_for_pid 附加），检查 CODE_SIGN_INJECT_BASE_ENTITLEMENTS。"
fi

# 时间戳是签名本身的属性，公证强制要求它存在。
[[ "$SIGN_INFO" == *"Timestamp="* ]] || die "签名没有安全时间戳，公证会被拒。"

# ---- 4. 公证 + 装订 --------------------------------------------------------

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
  step "跳过公证（--skip-notarize）"
  echo "    产物未公证，别人下载后仍会被 Gatekeeper 拦，只能自己验证签名配置。"
else
  step "提交公证（notarytool --wait，通常 1–5 分钟）"
  SUBMIT_ZIP="$WORK/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
  RESULT="$(xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" \
    --keychain "$NOTARY_KEYCHAIN" --wait --output-format json)"
  STATUS="$(plutil -extract status raw - <<<"$RESULT")"
  SUBMISSION="$(plutil -extract id raw - <<<"$RESULT")"
  if [[ "$STATUS" != "Accepted" ]]; then
    echo "---- notarytool log ----" >&2
    xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" \
      --keychain "$NOTARY_KEYCHAIN" >&2 || true
    die "公证未通过：${STATUS}（submission ${SUBMISSION}）"
  fi
  echo "    公证通过（submission ${SUBMISSION}）"

  step "装订票据（stapler staple）"
  xcrun stapler staple -v "$APP"
  xcrun stapler validate "$APP"
fi

# ---- 5. 打包分发产物 -------------------------------------------------------

step "打包"
mkdir -p "$DIST_DIR"
ZIP="$DIST_DIR/$APP_NAME-$VERSION.zip"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$ZIP" "$DMG"

# 用 ditto 而不是 cp -R：拷贝已签名/已装订的包时保留扩展属性等元数据。
# 票据是否随包生效由下面第 6 步回验兜底（stapler validate + spctl 逐个产物验）。
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

ditto -c -k --keepParent "$APP" "$ZIP"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

# ---- 6. 校验真正交付给用户的那两个文件 -------------------------------------

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  step "回验分发产物（解压 zip / 挂载 dmg 后过 spctl）"
  for artifact in "$ZIP" "$DMG"; do
    rm -rf "$WORK/verify" && mkdir -p "$WORK/verify"
    MOUNT=""
    if [[ "$artifact" == *.zip ]]; then
      ditto -x -k "$artifact" "$WORK/verify"
      CANDIDATE="$WORK/verify/$APP_NAME.app"
    else
      MOUNT="$WORK/mnt"
      mkdir -p "$MOUNT"
      hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT" "$artifact"
      CANDIDATE="$MOUNT/$APP_NAME.app"
    fi
    OUT="$(spctl -a -t exec -vv "$CANDIDATE" 2>&1 || true)"
    xcrun stapler validate "$CANDIDATE" >/dev/null 2>&1 \
      || die "$artifact 里的 App 过不了 stapler validate"
    grep -q ": accepted" <<<"$OUT" || die "$artifact 里的 App 被 Gatekeeper 拒绝：$OUT"
    grep -q "source=Notarized Developer ID" <<<"$OUT" \
      || die "$artifact 来源不对：$OUT"
    echo "    $(basename "$artifact"): accepted / Notarized Developer ID"
    [[ -n "$MOUNT" ]] && hdiutil detach -quiet "$MOUNT"
  done
fi

step "完成"
shasum -a 256 "$ZIP" "$DMG" | sed "s|$PWD/||" | sed 's/^/    /'
cat <<EOF

产物：
  $ZIP
  $DMG

上传到 GitHub Releases 即可直传分发。上不了 Mac App Store（沙盒与私有 API 冲突），
原因见 README「分发」。用户首次启动仍要自己做：蓝牙授权 → 辅助功能授权 → 选设备 → 设登录密码。
EOF
