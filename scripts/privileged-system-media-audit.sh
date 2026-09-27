#!/bin/sh
# Exhaustive read-only audit of system-managed local media stores.
# The scan never removes, renames, chmods, opens databases, or hydrates cloud placeholders.
set -u

audit_uid="${1:-}"
audit_home="${2:-}"
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

data_root="/System/Volumes/Data"
darwin_base="/private/var/folders"

echo "SYSTEM_MEDIA_AUDIT_VERSION\t1"
echo "IDENTITY\tuid=$audit_uid\thome=$audit_home"
echo "SECTION\tALL_DARWIN_USER_ROOTS"

# A user can have more than one hashed Darwin root after migration, upgrades, account
# recreation, or interrupted cleanup. Audit every owned token rather than trusting
# confstr/getconf to return the only relevant one.
/usr/bin/find "$darwin_base" -mindepth 2 -maxdepth 2 -type d -user "$audit_uid" -print0 2>/dev/null \
    | while IFS= read -r -d '' root; do
        root_kb="$(/usr/bin/du -skx "$root" 2>/dev/null | /usr/bin/awk 'NR==1 {print $1+0}')"
        [ -n "$root_kb" ] || root_kb=0
        echo "DARWIN_ROOT\tkb=$root_kb\t$root"
        for area in T C 0; do
            [ -d "$root/$area" ] || continue
            area_kb="$(/usr/bin/du -skx "$root/$area" 2>/dev/null | /usr/bin/awk 'NR==1 {print $1+0}')"
            [ -n "$area_kb" ] || area_kb=0
            files="$(/usr/bin/find -x "$root/$area" -type f -print 2>/dev/null | /usr/bin/awk 'END {print NR+0}')"
            echo "DARWIN_AREA\tarea=$area\tkb=$area_kb\tfiles=$files\t$root/$area"
        done
    done

echo "SECTION\tSYSTEM_MANAGED_MEDIA"

# Scan the complete Data volume, but only retain system-managed paths. Visible user
# document roots are excluded; ~/Library remains in scope. Telegram is intentionally
# excluded because this audit is looking for the independent system store.
/usr/bin/find -x "$data_root" -type f -size +65535c -print0 2>/dev/null \
    | /usr/bin/perl -0ne '
        chomp;
        my $path = $_;
        our ($home, $data_home, $uid);
        BEGIN {
            $home = $ARGV[0];
            $data_home = "/System/Volumes/Data$home";
            $uid = $ARGV[1];
            splice(@ARGV, 0, 2);
        }

        next if $path =~ m{/(?:Telegram Desktop|[^/]*Telegram[^/]*|[^/]*keepcoder[^/]*)/}i;
        next if index($path, "$home/Desktop/") == 0;
        next if index($path, "$data_home/Desktop/") == 0;
        next if index($path, "$home/Documents/") == 0;
        next if index($path, "$data_home/Documents/") == 0;
        next if index($path, "$home/Downloads/") == 0;
        next if index($path, "$data_home/Downloads/") == 0;
        next if index($path, "$home/Movies/") == 0;
        next if index($path, "$data_home/Movies/") == 0;
        next if index($path, "$home/Music/") == 0;
        next if index($path, "$data_home/Music/") == 0;
        next if index($path, "$home/Pictures/") == 0;
        next if index($path, "$data_home/Pictures/") == 0;
        next if index($path, "$home/Public/") == 0;
        next if index($path, "$data_home/Public/") == 0;
        next if $path =~ m{/Users/[^/]+/Library/(?:Mobile Documents|CloudStorage|Application Support/CloudDocs|Application Support/FileProvider)/};

        my @st = stat($path);
        my $logical = $st[7] || 0;
        my $allocated = ($st[12] || 0) * 512;
        next if $allocated <= 0;
        next unless open(my $fh, "<", $path);
        binmode($fh);
        my $h = "";
        my $n = read($fh, $h, 64);
        close($fh);
        next unless defined($n) && $n >= 3;
        my $kind = "";
        $kind = "png" if substr($h,0,8) eq "\x89PNG\x0d\x0a\x1a\x0a";
        $kind = "jpeg" if substr($h,0,3) eq "\xff\xd8\xff";
        $kind = "gif" if substr($h,0,4) eq "GIF8";
        $kind = "webp" if substr($h,0,4) eq "RIFF" && substr($h,8,4) eq "WEBP";
        $kind = "tiff" if substr($h,0,4) eq "II*\x00" || substr($h,0,4) eq "MM\x00*";
        $kind = "bmp" if substr($h,0,2) eq "BM";
        $kind = "iso-media" if substr($h,4,4) eq "ftyp";
        $kind = "webm" if substr($h,0,4) eq "\x1a\x45\xdf\xa3";
        next if $kind eq "";

        my $dimensions = "";
        if ($kind eq "png" && length($h) >= 24) {
            my ($w, $hh) = unpack("NN", substr($h,16,8));
            $dimensions = "${w}x${hh}" if $w > 0 && $hh > 0;
        }

        my $group = "";
        if ($path =~ m{^/System/Volumes/Data/private/var/folders/([^/]+)/([^/]+)/(T|C|0)(?:/([^/]+))?}) {
            $group = "/private/var/folders/$1/$2/$3" . (defined($4) ? "/$4" : "");
        } elsif ($path =~ m{^/System/Volumes/Data/Users/[^/]+/Library/(Application Support|Containers|Group Containers|Caches|WebKit)(?:/([^/]+))?}) {
            $group = "$home/Library/$1" . (defined($2) ? "/$2" : "");
        } elsif ($path =~ m{^/System/Volumes/Data/(\.[^/]+)}) {
            $group = "/System/Volumes/Data/$1";
        } elsif ($path =~ m{^/System/Volumes/Data/Library/([^/]+)(?:/([^/]+))?}) {
            $group = "/Library/$1" . (defined($2) ? "/$2" : "");
        } elsif ($path =~ m{^/System/Volumes/Data/private/([^/]+)(?:/([^/]+))?}) {
            $group = "/private/$1" . (defined($2) ? "/$2" : "");
        } elsif ($path =~ m{^/System/Volumes/Data/Users/[^/]+/Library/([^/]+)}) {
            $group = "$home/Library/$1";
        } else {
            my $parent = $path;
            $parent =~ s{/[^/]+$}{};
            $group = $parent;
        }

        my $capture = ($path =~ m{(?:screenshot|screen shot|screen.?capture|screen.?record|снимок экрана|запись экрана|NSIRD_|TemporaryItems|Autosave Information|DocumentRevisions|QuickLook)}i) ? 1 : 0;
        my $key = "$group\t$kind";
        our (%count, %physical, %logical_sum, %largest, %capture_count, @capture_rows, @largest_rows);
        $count{$key}++;
        $physical{$key} += $allocated;
        $logical_sum{$key} += $logical;
        $largest{$key} = $logical if !defined($largest{$key}) || $logical > $largest{$key};
        $capture_count{$key} += $capture;
        push @largest_rows, [$allocated, $logical, $kind, $dimensions, $path];
        push @capture_rows, [$allocated, $logical, $kind, $dimensions, $path] if $capture;

        END {
            print "SUBSECTION\tGROUPS_BY_PHYSICAL_BYTES\n";
            for my $key (sort { $physical{$b} <=> $physical{$a} } keys %count) {
                print "MEDIA_GROUP\tphysical=$physical{$key}\tlogical=$logical_sum{$key}\tfiles=$count{$key}\tlargest=$largest{$key}\tcaptureEvidence=", ($capture_count{$key} || 0), "\t$key\n";
            }
            print "SUBSECTION\tLARGEST_SYSTEM_MEDIA\n";
            my @largest = sort { $b->[0] <=> $a->[0] } @largest_rows;
            $#largest = 499 if @largest > 500;
            for my $row (@largest) {
                print "MEDIA_FILE\tphysical=$row->[0]\tlogical=$row->[1]\tkind=$row->[2]\tdimensions=$row->[3]\t$row->[4]\n";
            }
            print "SUBSECTION\tCAPTURE_EVIDENCE_FILES\n";
            my @captures = sort { $b->[0] <=> $a->[0] } @capture_rows;
            $#captures = 999 if @captures > 1000;
            for my $row (@captures) {
                print "CAPTURE_FILE\tphysical=$row->[0]\tlogical=$row->[1]\tkind=$row->[2]\tdimensions=$row->[3]\t$row->[4]\n";
            }
            print "SYSTEM_MEDIA_TOTAL\tfiles=", scalar(@largest_rows), "\tcaptureEvidence=", scalar(@capture_rows), "\n";
        }
    ' "$audit_home" "$audit_uid"

echo "SECTION\tDELETED_FILE_SYSTEM_STORES"
for store in \
    "$data_root/.DocumentRevisions-V100" \
    "$data_root/.TemporaryItems" \
    "$data_root/.Trashes" \
    "$data_root/.Spotlight-V100" \
    "$data_root/private/var/root/.Trash" \
    "$audit_home/.Trash" \
    "$audit_home/Library/Autosave Information" \
    "$audit_home/Library/Metadata/CoreSpotlight"
do
    [ -e "$store" ] || continue
    kb="$(/usr/bin/du -skx "$store" 2>/dev/null | /usr/bin/awk 'NR==1 {print $1+0}')"
    files="$(/usr/bin/find -x "$store" -type f -print 2>/dev/null | /usr/bin/awk 'END {print NR+0}')"
    echo "SYSTEM_STORE\tkb=${kb:-0}\tfiles=$files\t$store"
done

echo "SECTION\tAPFS_LOCAL_SNAPSHOTS"
/usr/bin/tmutil listlocalsnapshots / 2>&1 | /usr/bin/sed 's/^/TM_SNAPSHOT\t/'
/usr/sbin/diskutil apfs listSnapshots /System/Volumes/Data 2>&1 | /usr/bin/sed 's/^/DATA_SNAPSHOT\t/'
echo "SYSTEM_MEDIA_AUDIT_DONE"
