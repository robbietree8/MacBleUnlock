#!/bin/bash
#
# 创建 / 复用 MacBleUnlock 的自签名代码签名身份（幂等）。
#
# 为什么必须固定签名身份：
#   - TCC 授权（蓝牙、辅助功能）绑定在代码签名身份上，换身份即失效；
#   - 钥匙串里的登录密码条目也按签名身份做访问控制，换身份后首次读取要重新授权。
#
# 三点实测结论（macOS 27）：
#   1. PKCS#12 必须使用**非空**口令。空口令会被 Security.framework 拒绝：
#      `SecKeychainItemImport: MAC verification failed during PKCS12 import`。
#   2. 不需要 `security set-key-partition-list`。`security import -T /usr/bin/codesign`
#      已足够让 codesign 非交互取用私钥（实测通过）。
#   3. 不使用 `-A`：私钥 ACL 只授予 /usr/bin/codesign 与 /usr/bin/security，
#      而不是「任意程序」。这是能通过验证的最小授权。
#
# 用法：bash scripts/make-signing-cert.sh

set -euo pipefail

IDENTITY_NAME="${MBU_SIGNING_IDENTITY:-MacBleUnlock Dev}"
# `security default-keychain` 会带前导空白和引号。
KEYCHAIN="$(security default-keychain -d user | tr -d '"' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

if [[ ! -f "$KEYCHAIN" ]]; then
  echo "错误：找不到用户默认钥匙串：$KEYCHAIN" >&2
  exit 1
fi

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "\"$IDENTITY_NAME\""; then
  echo "签名身份已存在，无需重建。"
  security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$IDENTITY_NAME"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

P12_PASS="$(openssl rand -hex 24)"

echo "生成自签名代码签名证书：$IDENTITY_NAME"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$IDENTITY_NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE" \
  >/dev/null 2>&1

openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/cert.p12" -passout "pass:$P12_PASS" -name "$IDENTITY_NAME" \
  >/dev/null 2>&1

echo "导入钥匙串：$KEYCHAIN"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security

echo "将证书标记为受信任（用户信任域，仅 codeSign 策略）"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -qF "\"$IDENTITY_NAME\""; then
  echo "错误：身份创建后仍不可用。请检查钥匙串是否已解锁。" >&2
  exit 1
fi

echo
echo "完成。可用身份："
security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$IDENTITY_NAME"
