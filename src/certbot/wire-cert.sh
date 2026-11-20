#!/usr/bin/env bash
# Wire a certbot certificate into nginx or Apache:
# find the server on port 443, repoint its cert/key lines, test, reload, add a renewal hook.
# Usage: sudo ./wire-cert.sh [domain]     (domain optional if certbot holds only one cert)
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"

LIVE=/etc/letsencrypt/live
domain=${1:-}
if [ -z "$domain" ]; then
  mapfile -t found < <(find "$LIVE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
  [ "${#found[@]}" -eq 1 ] || die "usage: $0 <domain>   (${#found[@]} certs in $LIVE, cannot guess)"
  domain=${found[0]}
fi
# domain goes into paths and sed, so allow hostname characters only
[[ $domain =~ ^[A-Za-z0-9.-]+$ ]] || die "bad domain: $domain"

CERT=$LIVE/$domain/fullchain.pem
KEY=$LIVE/$domain/privkey.pem
[ -r "$CERT" ] && [ -r "$KEY" ] || die "missing $CERT or $KEY (run certbot first)"

[ "$(openssl x509 -noout -pubkey -in "$CERT" | openssl sha256)" = \
  "$(openssl pkey -pubout -in "$KEY" | openssl sha256)" ] || die "cert and key do not match"

# --- which server owns 443? ---
listeners=$(ss -tlnpH 'sport = :443' || true)
case $listeners in
  *'"nginx"'*)
    svc=nginx
    test_cmd="nginx -t"
    reload_cmd="nginx -s reload"
    name_re='server_name'
    cert_kw=ssl_certificate
    loaded=$(nginx -T 2>/dev/null | sed -n 's/^# configuration file \(.*\):$/\1/p')
    rewrite=(-e "s#^([[:space:]]*ssl_certificate[[:space:]]+)[^;]+;#\1$CERT;#"
             -e "s#^([[:space:]]*ssl_certificate_key[[:space:]]+)[^;]+;#\1$KEY;#")
    ;;
  *'"apache2"'*|*'"httpd"'*)
    svc=apache
    ctl=$(command -v apache2ctl || command -v apachectl) || die "apachectl not found"
    test_cmd="$ctl configtest"
    reload_cmd="$ctl graceful"
    name_re='Server(Name|Alias)'
    cert_kw=SSLCertificateFile
    loaded=$("$ctl" -t -D DUMP_INCLUDES 2>/dev/null | sed -n 's/^ *([^)]*) //p')
    # shortcut: directive names matched case-sensitively, fix by hand if config uses odd case
    rewrite=(-e "s#^([[:space:]]*SSLCertificateFile[[:space:]]+).*#\1$CERT#"
             -e "s#^([[:space:]]*SSLCertificateKeyFile[[:space:]]+).*#\1$KEY#")
    ;;
  *) die "neither nginx nor Apache is listening on port 443" ;;
esac
echo "Server on 443: $svc"

# --- which config files? only files the server really loads, symlinks resolved ---
mapfile -t cands < <(
  while IFS= read -r f; do [ -f "$f" ] && readlink -f "$f"; done <<<"$loaded" | sort -u |
    while IFS= read -r f; do
      grep -qE "^[[:space:]]*${cert_kw}[[:space:]]" "$f" && echo "$f"
    done
)
[ "${#cands[@]}" -gt 0 ] || die "no loaded $svc config has a $cert_kw line; add the HTTPS site by hand first"

dom_re="(^|[[:space:]])${domain//./\\.}([[:space:];]|\$)"
targets=()
if [ "${#cands[@]}" -eq 1 ]; then
  targets=("${cands[@]}")
else
  for f in "${cands[@]}"; do
    names=$(grep -E "^[[:space:]]*${name_re}[[:space:]]" "$f" || true)
    grep -qE "$dom_re" <<<"$names" || continue
    # a file that also serves other hostnames would get their cert lines overwritten too
    if grep -vE "$dom_re" <<<"$names" | grep -q .; then
      die "$f serves other hostnames besides $domain; edit that one by hand"
    fi
    targets+=("$f")
  done
fi
[ "${#targets[@]}" -gt 0 ] || die "several SSL configs loaded, none names $domain; edit by hand"

# --- back up, rewrite, test, roll back on failure ---
backup=/root/wire-cert-backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$backup"
restore() {
  for f in "${targets[@]}"; do cp -p "$backup/${f//\//_}" "$f"; done
  echo "Config restored from $backup" >&2
}
for f in "${targets[@]}"; do
  cp -p "$f" "$backup/${f//\//_}"
  tmp=$(mktemp)
  sed -E "${rewrite[@]}" "$f" >"$tmp"
  cat "$tmp" >"$f" # keeps owner and mode of the original
  rm -f "$tmp"
  echo "Updated: $f"
  if [ "$svc" = apache ] && grep -qE '^[[:space:]]*SSLCertificateChainFile' "$f"; then
    echo "WARNING: $f still has SSLCertificateChainFile; fullchain.pem makes it unneeded, remove it by hand" >&2
  fi
done

if ! $test_cmd; then
  restore
  die "$svc config test failed, nothing reloaded"
fi
$reload_cmd
echo "Reloaded $svc"

# --- reload again after every future renewal ---
hook=/etc/letsencrypt/renewal-hooks/deploy/reload-$svc.sh
mkdir -p "$(dirname "$hook")"
printf '#!/bin/sh\n%s\n' "$reload_cmd" >"$hook"
chmod 755 "$hook"
echo "Renewal hook: $hook"

# --- prove the live server hands out the new cert ---
sleep 2
want=$(openssl x509 -noout -fingerprint -sha256 -in "$CERT")
got=$(openssl s_client -connect localhost:443 -servername "$domain" </dev/null 2>/dev/null |
  openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)
if [ "$want" = "$got" ]; then
  echo "OK: $domain now serves the new certificate"
  openssl x509 -noout -issuer -enddate -in "$CERT"
  echo "Backup of old config: $backup"
else
  die "reloaded, but port 443 serves a different cert for $domain. Backup: $backup"
fi
