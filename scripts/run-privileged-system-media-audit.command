#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
audit_uid="$(id -u)"
audit_home="$HOME"
report="/private/tmp/cleanalepha-system-media-audit-${audit_uid}.tsv"

echo "Read-only system media audit. No files will be deleted or changed."
echo "macOS may ask for the administrator password."
sudo /bin/sh "$script_dir/privileged-system-media-audit.sh" "$audit_uid" "$audit_home" > "$report"
sudo /usr/sbin/chown "$audit_uid":staff "$report"
/bin/chmod 600 "$report"
echo "AUDIT_REPORT=$report"
echo "Audit complete. You can close this Terminal window."
