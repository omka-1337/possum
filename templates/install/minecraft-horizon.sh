#!/bin/sh
# Installs Horizon (Minecraft: Java Edition rewritten in Rust) into /data/horizon and prepares its game
# files from Mojang's own client and server jars. Runs inside eclipse-temurin:25-jre: prepare needs Java 25.
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl jq >/dev/null

work=/data/.install
rm -rf "$work"
mkdir -p "$work"

# get URL FILE [SHA1]: download, retrying, and check the file against Mojang's checksum when there is one.
get() {
    mkdir -p "$(dirname "$2")"
    curl -fsSL --retry 5 --retry-all-errors -o "$2" "$1"
    if [ -n "${3:-}" ] && [ "$(sha1sum "$2" | cut -d' ' -f1)" != "$3" ]; then
        echo "checksum mismatch: $1" >&2
        exit 1
    fi
}

echo "downloading Horizon $HORIZON_VERSION"
release="https://github.com/horizon-rust/horizon/releases/download/$HORIZON_VERSION"
archive=horizon-server-linux-x86_64.tar.gz
get "$release/$archive" "$work/$archive"
get "$release/SHA256SUMS" "$work/SHA256SUMS"
expected=$(awk -v f="$archive" '$2 == f { print $1 }' "$work/SHA256SUMS")
if [ -z "$expected" ] || [ "$(sha256sum "$work/$archive" | cut -d' ' -f1)" != "$expected" ]; then
    echo "checksum mismatch: $archive" >&2
    exit 1
fi
rm -rf /data/horizon
mkdir -p /data/horizon
tar -xzf "$work/$archive" -C /data/horizon --strip-components=1

# Horizon pins the exact Minecraft files it was checked against: fetch those, laid out as a launcher keeps them.
lock=/data/horizon/research-lock.json
version=$(jq -r .minecraft.version "$lock")
manifest_sha1=$(jq -r .minecraft.manifest_sha1 "$lock")
mc="$work/minecraft"
manifest="$mc/versions/$version/$version.json"

echo "downloading Minecraft $version from Mojang"
get "https://piston-meta.mojang.com/v1/packages/$manifest_sha1/$version.json" "$manifest" "$manifest_sha1"
get "$(jq -r .downloads.client.url "$manifest")" "$mc/versions/$version/$version.jar" "$(jq -r .downloads.client.sha1 "$manifest")"
get "$(jq -r .downloads.server.url "$manifest")" "$work/server.jar" "$(jq -r .downloads.server.sha1 "$manifest")"

# Libraries for Linux, as the launcher picks them: the last rule that matches decides.
jq -r '.libraries[]
    | select(.rules == null or (reduce .rules[] as $r (false;
        if $r.os == null or $r.os.name == "linux" then $r.action == "allow" else . end)))
    | .downloads.artifact | select(. != null) | "\(.url) \(.path) \(.sha1)"' "$manifest" |
    while read -r url path sha1; do
        get "$url" "$mc/libraries/$path" "$sha1"
    done

# Only the index: the objects are the client's sounds, fonts and languages, which a server never uses.
index_id=$(jq -r .assetIndex.id "$manifest")
get "$(jq -r .assetIndex.url "$manifest")" "$mc/assets/indexes/$index_id.json" "$(jq -r .assetIndex.sha1 "$manifest")"

echo "preparing the game files"
/data/horizon/horizon-prepare --prepare --server-jar "$work/server.jar" --minecraft-dir "$mc" --root /data/horizon

prepared="/data/horizon/.local/horizon-client/$version"
if [ ! -f "$prepared/registries.json" ]; then
    echo "prepare finished without $prepared/registries.json" >&2
    exit 1
fi
# The engine reads only the prepared resources; the rest of .local is prepare's own work (about 700 MB).
mv "$prepared" /data/horizon/resources
rm -rf /data/horizon/.local "$work"
echo "Horizon $HORIZON_VERSION installed"
