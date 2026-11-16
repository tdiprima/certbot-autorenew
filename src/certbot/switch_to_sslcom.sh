#!/usr/bin/env bash
# ===========================================================
# Switch existing CERTInext certs from the emSign CA to SSL.com
#
# Certbot only uses EAB keys when it registers an ACME account, so new
# keys are ignored while the old account exists. This script drops the
# old account, registers a new one with the SSL.com EAB keys, then
# re-issues every cert that came from the old server.
#
# Usage: sudo ./switch_to_sslcom.sh
# Cert still on the old Sectigo server? Name it:
#   sudo OLD_SERVER=https://acme.sectigo.com/v2/InCommonRSAOV ./switch_to_sslcom.sh
# NEW_SERVER can be overridden the same way.
# ===========================================================

set -euo pipefail

CERTINEXT=https://acme-us.certinext.io/v1/directory
OLD_SERVER="${OLD_SERVER:-$CERTINEXT}"
NEW_SERVER="${NEW_SERVER:-$CERTINEXT}"
LE_DIR=/etc/letsencrypt
ACCT_DIR="$LE_DIR/accounts/${NEW_SERVER#https://}"

[ "$(id -u)" -eq 0 ] || { echo "❌ Run as root (sudo)."; exit 1; }
command -v certbot >/dev/null || { echo "❌ certbot not found."; exit 1; }

CONFS=$(grep -lF "server = $OLD_SERVER" "$LE_DIR"/renewal/*.conf 2>/dev/null || true)
if [ -z "$CONFS" ]; then
    echo "❌ No certs found for $OLD_SERVER."
    echo "   Servers your certs actually use (file: server):"
    SERVERS=$(cd "$LE_DIR/renewal" 2>/dev/null && grep -H '^server = ' -- *.conf 2>/dev/null || true)
    if [ -n "$SERVERS" ]; then
        echo "$SERVERS" | sed 's|^|   |'
    else
        echo "   (none: no certbot renewal files in $LE_DIR/renewal, so certbot does not manage a cert here)"
    fi
    echo "   Re-run with that URL:"
    echo "   sudo OLD_SERVER=<url from above> $0"
    exit 1
fi

echo "📋 Certs to switch:"
echo "$CONFS" | sed 's|.*/||; s|\.conf$||; s|^|   |'

read -rp "💌 Enter email address: " EMAIL
read -rp "🗝 Enter your NEW (SSL.com) EAB Key ID: " EAB_KID
read -rsp "🔑 Enter your NEW (SSL.com) EAB HMAC Key: " EAB_HMAC
echo
[ -n "$EMAIL" ] && [ -n "$EAB_KID" ] && [ -n "$EAB_HMAC" ] || { echo "❌ All three values are required."; exit 1; }

BACKUP="$LE_DIR.bak.$(date +%Y%m%d-%H%M%S)"
echo "💾 Backing up $LE_DIR to $BACKUP ..."
cp -a "$LE_DIR" "$BACKUP"

# Old account is tied to the emSign EAB keys. Safe to drop: it is in the backup.
rm -rf "$ACCT_DIR"

echo "🪪 Registering new ACME account with SSL.com EAB keys..."
# shortcut: HMAC key is visible in `ps` while certbot runs, move it to a 600 cli.ini if the host has untrusted users
certbot register \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    --server "$NEW_SERVER" \
    --eab-kid "$EAB_KID" \
    --eab-hmac-key "$EAB_HMAC"

NEW_ID=$(ls "$ACCT_DIR")
[ "$(echo "$NEW_ID" | wc -l)" -eq 1 ] && [ -n "$NEW_ID" ] || { echo "❌ Expected one new account in $ACCT_DIR. Restore from $BACKUP."; exit 1; }

FAILED=0
for CONF in $CONFS; do
    NAME=$(basename "$CONF" .conf)
    echo "📜 Re-issuing $NAME ..."
    sed -i "s|^account = .*|account = $NEW_ID|; s|^server = .*|server = $NEW_SERVER|" "$CONF"
    # Renew keeps the cert's saved plugin and deploy hook, so the web server reloads as before.
    certbot renew --cert-name "$NAME" --force-renewal --non-interactive || { echo "❌ $NAME failed."; FAILED=1; continue; }

    ISSUERS=$(openssl crl2pkcs7 -nocrl -certfile "$LE_DIR/live/$NAME/fullchain.pem" | openssl pkcs7 -print_certs -noout | grep '^issuer' || true)
    echo "$ISSUERS" | sed 's/^/   /'
    if [ -z "$ISSUERS" ] || echo "$ISSUERS" | grep -qi emsign; then
        echo "❌ $NAME still chains to emSign (or chain unreadable). Check the EAB keys are for SSL.com."
        FAILED=1
    else
        echo "✅ $NAME no longer chains to emSign."
    fi
done

if [ "$FAILED" -ne 0 ]; then
    echo "⚠ Some certs failed. To roll back: rm -rf $LE_DIR && mv $BACKUP $LE_DIR, then restart the web server."
    exit 1
fi

echo "🎉 Done! Auto-renewal now uses the new account. Backup is at $BACKUP."
