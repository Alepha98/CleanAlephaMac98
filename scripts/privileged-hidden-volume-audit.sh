#!/bin/sh
# Full Data-volume hidden-storage audit. Read-only except for stdout.
set -u

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
    echo "root privileges required" >&2
    exit 3
fi

data_root="/System/Volumes/Data"
echo "HIDDEN_AUDIT_VERSION\t1"
echo "SECTION\tOUTERMOST_HIDDEN_TREES"

# `find` yields parents before descendants. Keep only the first hidden directory
# on each branch so `du` does not count nested hidden trees twice.
/usr/bin/find -x "$data_root" -type d -name '.*' -print0 2>/dev/null \
    | /usr/bin/perl -0ne '
        chomp;
        my $path = $_;
        our @roots;
        for my $root (@roots) {
            next unless index($path, "$root/") == 0;
            $path = "";
            last;
        }
        next if $path eq "";
        push @roots, $path;
        print "$path\0";
    ' \
    | /usr/bin/xargs -0 /usr/bin/du -skx 2>/dev/null \
    | /usr/bin/sort -rn \
    | /usr/bin/head -400 \
    | /usr/bin/sed 's/^/HIDDEN_TREE\t/'

echo "SECTION\tALL_HIDDEN_MEDIA_MAGIC"

# Walk every regular file on the Data volume. Only files inside a dot-directory
# are opened, and only their first 32 bytes are read. Results are grouped by the
# outermost hidden owner tree to keep the report bounded.
/usr/bin/find -x "$data_root" -type f -size +65535c -print0 2>/dev/null \
    | /usr/bin/perl -0ne '
        chomp;
        my $path = $_;
        next unless $path =~ m{/(\.[^/]+)(?:/|$)};
        our $skipped;
        # FileProvider reads can hydrate iCloud placeholders. Never open them in a
        # read-only audit, even if stat reports stale allocated blocks.
        if ($path =~ m{/Users/[^/]+/Library/(?:Mobile Documents|CloudStorage|Application Support/CloudDocs)/}) {
            $skipped++;
            next;
        }
        my @st = stat($path);
        my $logical = $st[7] || 0;
        my $allocated = ($st[12] || 0) * 512;
        # SF_DATALESS files normally have no local blocks. This also conservatively
        # skips APFS clones whose physical ownership cannot be attributed per file.
        if ($allocated == 0) {
            $skipped++;
            next;
        }
        next unless open(my $fh, "<", $path);
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
        my @parts = split(m{/}, $path);
        my $owner = "";
        for my $part (@parts) {
            next if $part eq "";
            $owner .= "/$part";
            last if $part =~ /^\./;
        }
        my $key = "$owner\t$kind";
        our (%count, %logical, %allocated, %largest, %capture);
        $count{$key}++;
        $logical{$key} += $logical;
        $allocated{$key} += $allocated;
        $largest{$key} = $logical if !defined($largest{$key}) || $logical > $largest{$key};
        $capture{$key}++ if $path =~ m{(?:screen(?:shot|capture|record)|capture|upload|output|artifact|temporaryitems|\.trash)}i;
        END {
            print "0\t0\t", ($skipped || 0), "\t0\t0\t/COVERAGE\tlocal-blocks-zero-or-cloud-skipped\n";
            for my $group (keys %count) {
                print "$allocated{$group}\t$logical{$group}\t$count{$group}\t$largest{$group}\t", ($capture{$group} || 0), "\t$group\n";
            }
        }
    ' \
    | /usr/bin/sort -rn \
    | /usr/bin/head -500 \
    | /usr/bin/sed 's/^/HIDDEN_MEDIA\t/'

echo "HIDDEN_AUDIT_DONE"
