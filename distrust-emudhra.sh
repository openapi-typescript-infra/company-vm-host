#!/usr/bin/env bash
# Remove the roots behind the eMudhra intermediate key compromise (Oct 2026)
# from macOS's /etc/ssl/cert.pem, or check that a CA bundle no longer has them.
#
#   ./distrust-emudhra.sh                    patch /etc/ssl/cert.pem on this Mac
#   ./distrust-emudhra.sh --check FILE...    exit 1 if any FILE still has a root
#
# Eight eMudhra intermediates have private keys anyone can compute from the
# certificates (https://emudhra.we-have-a-problem.com/). Each key chains to
# emSign ECC Root CA - G3, and through a Sectigo cross-sign to AAA Certificate
# Services. macOS blocks the intermediates in its own trust evaluation, but the
# built-in curl, git, python3, ruby and openssl accept any chain that reaches a
# root in /etc/ssl/cert.pem, check no revocation, and Apple has not updated the
# file. They consult the system trust settings only for a chain the file
# rejects. Removing the two roots (the disclosure site's macOS workaround)
# sends the compromised chains to that system check, which blocks them.
#
# Where it runs:
#   - a runner host: run-slot.sh and dispatch.sh send the org PAT to
#     api.github.com through /usr/bin/curl. Run it there by hand:
#       scp distrust-emudhra.sh runner@runner.example.com:/tmp/
#       ssh -t runner@runner.example.com bash /tmp/distrust-emudhra.sh
#     A macOS update can put the stock file back; re-running is safe.
#   - the macvm bake: mobile-bake/scripts/05-distrust-emudhra.sh links here,
#     so every image built after it ships the patched file, and
#     10-mobile-tooling.sh calls --check on the bundles it sets up.
#
# Before replacing the file, the patched copy must reach the endpoints below
# with /usr/bin/curl. A host the stock file reaches and the patched one does
# not aborts the run. The stock file is kept as /etc/ssl/cert.pem.pre-emudhra;
# copy it back to undo.
set -euo pipefail

# SHA-256 of each root's SubjectPublicKeyInfo, the same values Homebrew's
# ca-certificates formula excludes. Matching on the key rather than the subject
# covers re-issued copies of the same root.
AFFECTED_SPKI=(
  bd153ed7b0434f6886b17bce8bbe84ed340c7132d702a8f4fa318f756ecbd6f3 # AAA Certificate Services
  8d417db2dd8bf5e3084d1e3f196d583849d81bdd4c00c70b9d39369e96b8c782 # emSign ECC Root CA - G3
)

# What the host and the bake guest fetch with /usr/bin/curl and friends:
# GitHub for the runner, JIT configs and releases; the rest for the bake.
TEST_HOSTS=(
  api.github.com github.com objects.githubusercontent.com
  release-assets.githubusercontent.com ghcr.io pkg-containers.githubusercontent.com
  raw.githubusercontent.com formulae.brew.sh dl.google.com
  registry.npmjs.org rubygems.org cdn.cocoapods.org get.maestro.mobile.dev
)

CERT_PEM=/etc/ssl/cert.pem
BACKUP="${CERT_PEM}.pre-emudhra"
OPENSSL=/usr/bin/openssl
CURL=/usr/bin/curl

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Print the subject of every certificate in <bundle> whose key is an affected
# root. Prints nothing for a clean bundle.
affected_in() { # <bundle>
  local dir cert spki
  dir="$(mktemp -d "$WORK/split.XXXXXX")"
  awk -v dir="$dir" '
    /-----BEGIN CERTIFICATE-----/ { f = sprintf("%s/%04d.pem", dir, ++n); w = 1 }
    w { print > f }
    /-----END CERTIFICATE-----/ { w = 0; close(f) }
  ' "$1"
  for cert in "$dir"/*.pem; do
    [[ -e "$cert" ]] || continue
    spki="$("$OPENSSL" x509 -pubkey -noout < "$cert" \
      | "$OPENSSL" pkey -pubin -outform der | "$OPENSSL" dgst -sha256 -r)"
    case " ${AFFECTED_SPKI[*]} " in
      *" ${spki%% *} "*) "$OPENSSL" x509 -noout -subject < "$cert" ;;
    esac
  done
}

cert_count() { grep -c -- '-----BEGIN CERTIFICATE-----' "$1"; }

if [[ "${1:-}" == "--check" ]]; then
  shift
  (( $# > 0 )) || { echo "usage: $0 --check FILE..." >&2; exit 2; }
  rc=0
  for f in "$@"; do
    [[ -r "$f" ]] || { echo "cannot read $f" >&2; rc=1; continue; }
    found="$(affected_in "$f")"
    if [[ -n "$found" ]]; then
      echo "$f still trusts an eMudhra-compromise root:" >&2
      sed 's/^/  /' <<<"$found" >&2
      rc=1
    else
      echo "$f: no eMudhra-compromise roots ($(cert_count "$f") certificates)"
    fi
  done
  exit "$rc"
fi
(( $# == 0 )) || { echo "usage: $0 [--check FILE...]" >&2; exit 2; }

if [[ -z "$(affected_in "$CERT_PEM")" ]]; then
  echo "$CERT_PEM already has neither root; nothing to do"
  exit 0
fi

# Apple's file heads each certificate with a "=== <subject>" line, and groups
# them under "### <organization>" lines. Drop a certificate's block from its
# === line until the next header (the disclosure site's awk).
PATCHED="$WORK/cert.pem"
awk '
  /^(###|===) / { skip = 0 }
  /^=== .*\/CN=(AAA Certificate Services|emSign ECC Root CA - G3)$/ { skip = 1 }
  !skip
' "$CERT_PEM" > "$PATCHED"

if left="$(affected_in "$PATCHED")" && [[ -n "$left" ]]; then
  echo "the patched copy still has an affected root, so $CERT_PEM is unchanged:" >&2
  sed 's/^/  /' <<<"$left" >&2
  exit 1
fi
before="$(cert_count "$CERT_PEM")"
after="$(cert_count "$PATCHED")"
removed="$(affected_in "$CERT_PEM" | grep -c .)"
if (( before - after != removed )); then
  echo "patching removed $((before - after)) certificates, expected ${removed}; $CERT_PEM is unchanged" >&2
  exit 1
fi

# Apple's curl and openssl fall back to the keychain's trust settings when a
# chain fails against the CA file, so without OPENSSL_X509_TEA_DISABLE every
# host passes no matter what the file holds. With it, the file is all they use.
failed=()
for host in "${TEST_HOSTS[@]}"; do
  if OPENSSL_X509_TEA_DISABLE=1 "$CURL" -sS -o /dev/null --max-time 20 --cacert "$PATCHED" "https://${host}/" 2>"$WORK/err"; then
    echo "ok        $host"
  elif OPENSSL_X509_TEA_DISABLE=1 "$CURL" -sS -o /dev/null --max-time 20 --cacert "$CERT_PEM" "https://${host}/" 2>/dev/null; then
    echo "BROKEN    $host: $(head -1 "$WORK/err")"
    failed+=("$host")
  else
    # Unreachable with either file: a network problem, not this patch.
    echo "skipped   $host (unreachable with the stock file too)"
    # The slots cannot run without this one, so it must be shown to work.
    if [[ "$host" == api.github.com ]]; then failed+=("$host"); fi
  fi
done
if (( ${#failed[@]} > 0 )); then
  echo "the patched copy failed for: ${failed[*]}; $CERT_PEM is unchanged" >&2
  exit 1
fi

[[ -e "$BACKUP" ]] || sudo cp -p "$CERT_PEM" "$BACKUP"
sudo install -m 0644 -o root -g wheel "$PATCHED" "$CERT_PEM"
[[ -z "$(affected_in "$CERT_PEM")" ]] || { echo "$CERT_PEM still has an affected root after install" >&2; exit 1; }
echo "removed ${removed} roots from $CERT_PEM (${before} -> ${after}); stock copy in $BACKUP"
