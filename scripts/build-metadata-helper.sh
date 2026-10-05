#!/bin/bash
# Builds the self-contained metadata helper bundled inside the app:
# an unmodified, relocatable Perl runtime plus unmodified ExifTool.
# Upstream sources are pinned by version and SHA-256; any mismatch stops the build.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=metadata-helper.lock
source scripts/metadata-helper.lock

architecture="$(uname -m)"
case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
output="build/metadata-helper/$architecture/MetadataHelper"
stamp="build/metadata-helper/$architecture/.lock-$(shasum -a 256 scripts/metadata-helper.lock scripts/build-metadata-helper.sh | shasum -a 256 | cut -c1-16)"
if [[ -f "$stamp" && -x "$output/perl/bin/perl" && -f "$output/exiftool/exiftool" ]]; then
    echo "Metadata helper is current: $output"
    exit 0
fi

downloads="build/downloads"
work="build/metadata-helper/$architecture/work"
mkdir -p "$downloads"
rm -rf "$work" "$output" build/metadata-helper/"$architecture"/.lock-*
mkdir -p "$work" "$output/licenses"

fetch() {
    local file="$1" expected="$2"; shift 2
    local target="$downloads/$file"
    if [[ -f "$target" ]] && [[ "$(shasum -a 256 "$target" | cut -d' ' -f1)" == "$expected" ]]; then return; fi
    rm -f "$target"
    for url in "$@"; do
        echo "Downloading $url"
        if curl --fail --location --silent --show-error --retry 3 --max-time 600 -o "$target.download" "$url"; then
            actual="$(shasum -a 256 "$target.download" | cut -d' ' -f1)"
            if [[ "$actual" == "$expected" ]]; then mv "$target.download" "$target"; return; fi
            echo "Checksum mismatch for $url: $actual" >&2
        fi
        rm -f "$target.download"
    done
    echo "Could not obtain $file with SHA-256 $expected." >&2
    exit 1
}

perl_archive="perl-${PERL_VERSION}.tar.gz"
exiftool_archive="Image-ExifTool-${EXIFTOOL_VERSION}.tar.gz"
fetch "$perl_archive" "$PERL_SHA256" "https://www.cpan.org/src/5.0/$perl_archive"
# exiftool.org hosts only the current release; the SourceForge archive keeps every version.
fetch "$exiftool_archive" "$EXIFTOOL_SHA256" \
    "https://downloads.sourceforge.net/project/exiftool/$exiftool_archive" \
    "https://exiftool.org/$exiftool_archive" \
    "https://cpan.metacpan.org/authors/id/E/EX/EXIFTOOL/$exiftool_archive"

tar -xzf "$downloads/$perl_archive" -C "$work"
tar -xzf "$downloads/$exiftool_archive" -C "$work"

# Relocatable Perl: @INC is derived from the perl executable's location, so the
# runtime works from inside the app bundle without absolute build paths.
# Local/Homebrew library paths are excluded so the runtime links only to macOS.
prefix="$(pwd)/$work/install"
(
    cd "$work/perl-${PERL_VERSION}"
    export MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin
    unset PERL5LIB PERL5OPT PERLLIB PERL_MM_OPT PERL_MB_OPT
    ./Configure -des -Dprefix="$prefix" -Duserelocatableinc \
        -Dcc=clang -Dlocincpth=' ' -Dloclibpth=' ' -Dglibpth='/usr/lib' \
        -Dman1dir=none -Dman3dir=none -Dsiteman1dir=none -Dsiteman3dir=none \
        -Dnoextensions='DB_File GDBM_File NDBM_File ODBM_File' \
        -Accflags="-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET" \
        -Aldflags="-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET" \
        -Alddlflags="-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET" >../configure.log
    make -j"$(sysctl -n hw.ncpu)" >../make.log 2>&1 || { tail -40 ../make.log >&2; exit 1; }
    make install >../install.log 2>&1 || { tail -40 ../install.log >&2; exit 1; }
)

# Copy only the runtime: the interpreter and its library. Documentation pods,
# build headers, the static libperl archive, and auxiliary scripts are omitted.
mkdir -p "$output/perl/bin"
cp "$prefix/bin/perl" "$output/perl/bin/perl"
cp -R "$prefix/lib" "$output/perl/lib"
find "$output/perl/lib" \( -name '*.pod' -o -name '.packlist' \) -delete
find "$output/perl/lib" -type d \( -name pod -o -name CORE \) -prune -exec rm -rf {} +

mkdir -p "$output/exiftool"
cp "$work/Image-ExifTool-${EXIFTOOL_VERSION}/exiftool" "$output/exiftool/exiftool"
cp -R "$work/Image-ExifTool-${EXIFTOOL_VERSION}/lib" "$output/exiftool/lib"
find "$output/exiftool/lib" -name '*.pod' -delete

cp "$work/perl-${PERL_VERSION}/Artistic" "$output/licenses/Perl-Artistic-License.txt"
cp "$work/perl-${PERL_VERSION}/Copying" "$output/licenses/Perl-GNU-GPL-1.txt"
cp "$work/perl-${PERL_VERSION}/README" "$output/licenses/Perl-README.txt"
cp "$work/Image-ExifTool-${EXIFTOOL_VERSION}/README" "$output/licenses/ExifTool-README.txt"
chmod -R u+w,go-w "$output"
chmod 755 "$output/perl/bin/perl" "$output/exiftool/exiftool"

# Refuse binaries that depend on anything outside macOS system libraries.
while IFS= read -r binary; do
    if /usr/bin/otool -L "$binary" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)'; then
        echo "Non-system dependency in $binary" >&2; exit 1
    fi
    archs="$(/usr/bin/lipo -archs "$binary")"
    [[ "$archs" == "$architecture" ]] || { echo "Unexpected architecture $archs in $binary" >&2; exit 1; }
done < <(find "$output" -type f \( -name perl -o -name '*.bundle' \))

reported="$(env -i PATH=/nonexistent "$output/perl/bin/perl" "$output/exiftool/exiftool" -ver)"
[[ "$reported" == "$EXIFTOOL_VERSION" ]] || { echo "Bundled ExifTool reported $reported" >&2; exit 1; }

cat > "$output/manifest.json" <<JSON
{
  "architecture": "$architecture",
  "minimumMacOS": "$MACOS_DEPLOYMENT_TARGET",
  "components": [
    {"name": "Perl", "version": "$PERL_VERSION", "source": "https://www.cpan.org/src/5.0/$perl_archive", "sha256": "$PERL_SHA256",
     "license": "Artistic License 1.0 or GNU GPL version 1 or later", "modifications": "None. Built with -Duserelocatableinc; DB_File/GDBM_File/NDBM_File/ODBM_File extensions, documentation, headers, and auxiliary scripts omitted."},
    {"name": "ExifTool", "version": "$EXIFTOOL_VERSION", "source": "https://downloads.sourceforge.net/project/exiftool/$exiftool_archive", "sha256": "$EXIFTOOL_SHA256",
     "license": "Same terms as Perl (Artistic License or GNU GPL)", "modifications": "None. Documentation pods omitted."}
  ]
}
JSON
rm -rf "$work"
touch "$stamp"
echo "Built metadata helper (Perl $PERL_VERSION, ExifTool $EXIFTOOL_VERSION, $architecture): $output ($(du -sh "$output" | cut -f1))"
