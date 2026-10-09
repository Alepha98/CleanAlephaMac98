#!/bin/sh
# Privileged storage audit. Every command below is read-only: no chmod/chown/rm,
# no xattr writes, no database opens in write mode, and no traversal across mounts.
set -u

audit_uid="${1:-}"
audit_home="${2:-}"
requested_darwin_root="${3:-}"
case "$audit_uid" in
    ''|*[!0-9]*) echo "invalid uid" >&2; exit 2 ;;
esac
case "$audit_home" in
    /Users/*) ;;
    *) echo "invalid home" >&2; exit 2 ;;
esac
if [ "$(/usr/bin/id -u)" -ne 0 ]; then
    echo "root privileges required" >&2
    exit 3
fi

revision_root="/System/Volumes/Data/.DocumentRevisions-V100"
revision_user="$revision_root/PerUID/$audit_uid"
data_temporary="/System/Volumes/Data/.TemporaryItems"
data_trashes="/System/Volumes/Data/.Trashes"
case "$requested_darwin_root" in
    /private/var/folders/*|/var/folders/*) darwin_root="$requested_darwin_root" ;;
    *) darwin_root="" ;;
esac
if [ -z "$darwin_root" ] || [ ! -d "$darwin_root" ]; then
    darwin_root="$(/usr/bin/find /private/var/folders -mindepth 2 -maxdepth 2 -type d -user "$audit_uid" -print 2>/dev/null | /usr/bin/head -1)"
fi
darwin_temp="${darwin_root%/}/T"

echo "AUDIT_VERSION\t2"
echo "AUDIT_IDENTITY\tuid=$audit_uid\thome=$audit_home\tdarwin=$darwin_root"
echo "SECTION\tROOT_SUMMARY"

summarize_root() {
    audit_path="$1"
    audit_label="$2"
    if [ ! -e "$audit_path" ]; then
        echo "ROOT\t$audit_label\tMISSING\t$audit_path"
        return
    fi
    audit_meta="$(/usr/bin/stat -f 'mode=%Sp uid=%u gid=%g nlink=%l size=%z blocks=%b dev=%d inode=%i' "$audit_path" 2>&1 || true)"
    audit_kb="$(/usr/bin/du -skx "$audit_path" 2>/dev/null | /usr/bin/awk 'NR==1 {print $1}')"
    [ -n "$audit_kb" ] || audit_kb="unknown"
    echo "ROOT\t$audit_label\tkb=$audit_kb\t$audit_meta\t$audit_path"
}

summarize_root "$revision_root" "DocumentRevisions"
summarize_root "$revision_user" "DocumentRevisionsUser"
summarize_root "$data_temporary" "DataTemporaryItems"
summarize_root "$data_trashes" "DataTrashes"
summarize_root "/System/Volumes/Data/.Spotlight-V100" "Spotlight"
summarize_root "/System/Volumes/Data/.fseventsd" "FSEvents"
summarize_root "/System/Volumes/VM" "SwapVolume"
summarize_root "/private/var/vm" "SleepImage"
summarize_root "/private/var/db/diagnostics" "Diagnostics"
summarize_root "/private/var/db/powerlog" "Powerlog"
summarize_root "/private/var/db/uuidtext" "UUIDText"
summarize_root "$darwin_temp" "DarwinTemporary"
summarize_root "/private/tmp" "SharedTemporary"
summarize_root "/private/var/root/.Trash" "RootTrash"
summarize_root "$audit_home/.Trash" "UserTrash"
summarize_root "$audit_home/Library/Autosave Information" "UserAutosave"
summarize_root "$audit_home/Library/Containers/com.apple.QuickTimePlayerX/Data/Library/Autosave Information" "QuickTimeAutosave"
summarize_root "$audit_home/Library/Group Containers/group.com.apple.screencapture" "ScreenCaptureGroup"
summarize_root "$audit_home/Library/Group Containers/group.com.apple.replayd" "ReplaydGroup"
summarize_root "$audit_home/Library/Application Support/CloudDocs" "CloudDocs"
summarize_root "$audit_home/Library/Application Support/FileProvider" "FileProvider"
summarize_root "$audit_home/Library/Metadata/CoreSpotlight" "CoreSpotlight"

echo "SECTION\tFOCUSED_COUNTS"
for focused in \
    "$revision_user" \
    "$data_temporary" \
    "$data_trashes" \
    "$darwin_temp/TemporaryItems" \
    "/private/var/root/.Trash" \
    "$audit_home/.Trash" \
    "$audit_home/Library/Autosave Information" \
    "$audit_home/Library/Containers/com.apple.QuickTimePlayerX/Data/Library/Autosave Information" \
    "$audit_home/Library/Group Containers/group.com.apple.screencapture" \
    "$audit_home/Library/Group Containers/group.com.apple.replayd"
do
    [ -d "$focused" ] || continue
    focused_dirs="$(/usr/bin/find -x "$focused" -type d -print 2>/dev/null | /usr/bin/awk 'END {print NR+0}')"
    focused_files="$(/usr/bin/find -x "$focused" -type f -print 2>/dev/null | /usr/bin/awk 'END {print NR+0}')"
    focused_links="$(/usr/bin/find -x "$focused" -type l -print 2>/dev/null | /usr/bin/awk 'END {print NR+0}')"
    echo "COUNT\tdirs=$focused_dirs\tfiles=$focused_files\tlinks=$focused_links\t$focused"
done

echo "SECTION\tDOCUMENT_REVISIONS_LAYOUT"
if [ -d "$revision_user" ]; then
    /usr/bin/find -x "$revision_user" -mindepth 1 -maxdepth 2 -type d -print 2>/dev/null \
        | /usr/bin/sed 's/^/REVISION_DIR\t/' \
        | /usr/bin/head -400
fi

echo "SECTION\tLARGEST_PROTECTED_FILES"
for focused in \
    "$revision_user" \
    "$data_temporary" \
    "$data_trashes" \
    "$darwin_temp/TemporaryItems" \
    "/private/var/root/.Trash" \
    "$audit_home/.Trash" \
    "$audit_home/Library/Autosave Information" \
    "$audit_home/Library/Containers/com.apple.QuickTimePlayerX/Data/Library/Autosave Information" \
    "$audit_home/Library/Group Containers/group.com.apple.screencapture" \
    "$audit_home/Library/Group Containers/group.com.apple.replayd"
do
    [ -d "$focused" ] || continue
    /usr/bin/find -x "$focused" -type f -exec /usr/bin/stat -f '%z\t%b\t%N' {} + 2>/dev/null
done | /usr/bin/sort -t '	' -k1,1nr | /usr/bin/head -250 | /usr/bin/sed 's/^/FILE\t/'

echo "SECTION\tPROTECTED_MEDIA_MAGIC"
for focused in \
    "$revision_user" \
    "$data_temporary" \
    "$data_trashes" \
    "$darwin_temp/TemporaryItems" \
    "/private/var/root/.Trash" \
    "$audit_home/.Trash" \
    "$audit_home/Library/Autosave Information" \
    "$audit_home/Library/Containers/com.apple.QuickTimePlayerX/Data/Library/Autosave Information" \
    "$audit_home/Library/Group Containers/group.com.apple.screencapture" \
    "$audit_home/Library/Group Containers/group.com.apple.replayd"
do
    [ -d "$focused" ] || continue
    /usr/bin/find -x "$focused" -type f -size +65535c -print0 2>/dev/null
done | /usr/bin/perl -0ne '
    chomp;
    my $p = $_;
    next unless open(my $fh, "<", $p);
    binmode($fh);
    my $h = "";
    my $n = read($fh, $h, 32);
    close($fh);
    next unless defined($n) && $n >= 3;
    my $kind = "";
    $kind = "png"  if substr($h,0,8) eq "\x89PNG\x0d\x0a\x1a\x0a";
    $kind = "jpeg" if substr($h,0,3) eq "\xff\xd8\xff";
    $kind = "gif"  if substr($h,0,4) eq "GIF8";
    $kind = "webp" if substr($h,0,4) eq "RIFF" && substr($h,8,4) eq "WEBP";
    $kind = "tiff" if substr($h,0,4) eq "II*\x00" || substr($h,0,4) eq "MM\x00*";
    $kind = "bmp"  if substr($h,0,2) eq "BM";
    $kind = "iso-media" if substr($h,4,4) eq "ftyp";
    $kind = "webm" if substr($h,0,4) eq "\x1a\x45\xdf\xa3";
    next if $kind eq "";
    my @s = stat($p);
    my $logical = $s[7] || 0;
    my $blocks = $s[12] || 0;
    print "$logical\t", ($blocks * 512), "\t$kind\t$p\n";
' | /usr/bin/sort -t '	' -k1,1nr | /usr/bin/head -500 | /usr/bin/sed 's/^/MEDIA\t/'

echo "SECTION\tALL_HIDDEN_DIRECTORY_COVERAGE"
hidden_count="$(/usr/bin/find -x /System/Volumes/Data -type d -name '.*' -print 2>/dev/null | /usr/bin/awk 'END {print NR+0}')"
echo "HIDDEN_DIRECTORIES\tcount=$hidden_count\troot=/System/Volumes/Data"
/usr/bin/find -x /System/Volumes/Data -type d -name '.*' -print 2>/dev/null \
    | /usr/bin/awk -F/ '{ depth=NF-1; count[depth]++ } END { for (d in count) print "HIDDEN_DEPTH\tdepth=" d "\tcount=" count[d] }' \
    | /usr/bin/sort -t= -k2,2n

echo "SECTION\tAPFS"
/usr/sbin/diskutil apfs listSnapshots /System/Volumes/Data 2>&1 | /usr/bin/sed 's/^/DATA_SNAPSHOT\t/'
/bin/df -k /System/Volumes/Data /System/Volumes/VM 2>&1 | /usr/bin/sed 's/^/DF\t/'
echo "AUDIT_DONE"
