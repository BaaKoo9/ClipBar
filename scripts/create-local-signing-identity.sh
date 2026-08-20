#!/bin/bash
set -euo pipefail

# 一次性创建长期固定的本地代码签名身份。私钥只进入专用钥匙串，
# 临时 PEM/P12 会在脚本退出时清理，不会进入仓库或发布包。

IDENTITY="${CLIPBAR_SIGNING_IDENTITY:-ClipBar Local Distribution}"
KEYCHAIN="${CLIPBAR_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/clipboard-dev.keychain-db}"
VALID_DAYS="${CLIPBAR_SIGNING_VALID_DAYS:-3650}"

if [[ ! "$IDENTITY" =~ ^[A-Za-z0-9._\ -]+$ ]]; then
    echo "错误：签名身份包含不支持的字符: $IDENTITY" >&2
    exit 1
fi
if [[ ! "$VALID_DAYS" =~ ^[0-9]+$ ]] || [ "$VALID_DAYS" -lt 365 ]; then
    echo "错误：CLIPBAR_SIGNING_VALID_DAYS 必须是至少 365 的整数" >&2
    exit 1
fi

if [ -x /opt/homebrew/bin/openssl ]; then
    OPENSSL_BIN=/opt/homebrew/bin/openssl
elif command -v openssl >/dev/null 2>&1; then
    OPENSSL_BIN=$(command -v openssl)
else
    echo "错误：未找到 OpenSSL" >&2
    exit 1
fi

if [ ! -f "$KEYCHAIN" ]; then
    mkdir -p "$(dirname "$KEYCHAIN")"
    security create-keychain -p "" "$KEYCHAIN"
fi
security unlock-keychain -p "" "$KEYCHAIN"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
    | grep -Fq "\"$IDENTITY\""; then
    security set-key-partition-list \
        -S apple-tool:,apple: \
        -s \
        -k "" \
        "$KEYCHAIN" >/dev/null
    echo "签名身份已存在: $IDENTITY"
    exit 0
fi

umask 077
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/clipbar-signing.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT

PRIVATE_KEY="$TEMP_DIR/private-key.pem"
CERTIFICATE="$TEMP_DIR/certificate.pem"
IDENTITY_P12="$TEMP_DIR/identity.p12"
P12_PASSWORD=$("$OPENSSL_BIN" rand -hex 24)

"$OPENSSL_BIN" req \
    -new \
    -newkey rsa:3072 \
    -nodes \
    -x509 \
    -sha256 \
    -days "$VALID_DAYS" \
    -keyout "$PRIVATE_KEY" \
    -out "$CERTIFICATE" \
    -subj "/CN=$IDENTITY/O=ClipBar Personal Distribution" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "subjectKeyIdentifier=hash"

"$OPENSSL_BIN" pkcs12 \
    -export \
    -legacy \
    -name "$IDENTITY" \
    -inkey "$PRIVATE_KEY" \
    -in "$CERTIFICATE" \
    -out "$IDENTITY_P12" \
    -passout "pass:$P12_PASSWORD"

echo "正在导入签名身份…"
security import "$IDENTITY_P12" \
    -k "$KEYCHAIN" \
    -f pkcs12 \
    -P "$P12_PASSWORD"

# 仅在当前用户域信任该证书的代码签名用途；Gatekeeper 仍会把它视为非 Developer ID。
echo "正在设置代码签名信任…"
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN" \
    "$CERTIFICATE"

echo "正在设置专用钥匙串的签名访问权限…"
security set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -k "" \
    "$KEYCHAIN" >/dev/null

if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
    | grep -Fq "\"$IDENTITY\""; then
    echo "错误：证书已导入，但未成为有效代码签名身份" >&2
    exit 1
fi

echo "已创建本地签名身份: $IDENTITY"
echo "钥匙串: $KEYCHAIN"
echo "有效期: $VALID_DAYS 天"
