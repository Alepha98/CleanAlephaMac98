#!/bin/sh
# Read-only inspection of the root user's otherwise invisible Trash.
set -u
root_trash="/private/var/root/.Trash"
if [ "$(/usr/bin/id -u)" -ne 0 ]; then
    echo "root privileges required" >&2
    exit 3
fi

echo "ROOT_TRASH_AUDIT_VERSION\t1"
/usr/bin/du -skx "$root_trash" 2>/dev/null | /usr/bin/sed 's/^/TOTAL\t/'
echo "SECTION\tCOUNTS"
echo "DIRECTORIES\t$(/usr/bin/find -x "$root_trash" -type d -print 2>/dev/null | /usr/bin/awk 'END {print NR+0}')"
echo "FILES\t$(/usr/bin/find -x "$root_trash" -type f -print 2>/dev/null | /usr/bin/awk 'END {print NR+0}')"
echo "LINKS\t$(/usr/bin/find -x "$root_trash" -type l -print 2>/dev/null | /usr/bin/awk 'END {print NR+0}')"

echo "SECTION\tTOP_LEVEL"
/usr/bin/find -x "$root_trash" -mindepth 1 -maxdepth 2 -print 2>/dev/null \
    | /usr/bin/head -300 \
    | /usr/bin/sed 's/^/ENTRY\t/'

echo "SECTION\tLARGEST_FILES"
/usr/bin/find -x "$root_trash" -type f -exec /usr/bin/stat -f '%z\t%b\t%Sm\t%N' -t '%Y-%m-%d %H:%M:%S' {} + 2>/dev/null \
    | /usr/bin/sort -t '	' -k1,1nr \
    | /usr/bin/head -200 \
    | /usr/bin/sed 's/^/FILE\t/'

echo "SECTION\tFILE_TYPES"
/usr/bin/find -x "$root_trash" -type f -print0 2>/dev/null \
    | /usr/bin/xargs -0 /usr/bin/file -b 2>/dev/null \
    | /usr/bin/sed -E 's/,.*$//' \
    | /usr/bin/sort \
    | /usr/bin/uniq -c \
    | /usr/bin/sort -rn \
    | /usr/bin/head -100 \
    | /usr/bin/sed 's/^/TYPE\t/'
echo "ROOT_TRASH_AUDIT_DONE"
