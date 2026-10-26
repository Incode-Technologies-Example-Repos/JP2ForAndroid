#!/bin/bash
set -eo pipefail

# Uploads every file of a staged Maven repo to a remote Maven repo with HTTP PUT.
# It does not build anything, so the remote repo gets the exact staged files.
#
# Usage: scripts/uploadStagedRepo.sh <staged repo dir> <remote repo url> <user key> <password key> [--immutable | --check-only]
# The user and the password come from the environment variable with that key name.
# If the variable is empty, they come from the same key in ~/.gradle/gradle.properties.
# --immutable is for an RC or a release: a file that already exists on the remote repo must keep its bytes.
# --check-only runs the --immutable check and uploads nothing, so a job can check every repo before the first upload.

if [ $# -lt 4 ] || [ $# -gt 5 ] || { [ $# -eq 5 ] && [ "$5" != "--immutable" ] && [ "$5" != "--check-only" ]; }; then
  echo "Usage: $0 <staged repo dir> <remote repo url> <user key> <password key> [--immutable | --check-only]"
  exit 1
fi

repo_dir="${1%/}"
repo_url="${2%/}"
user_key="$3"
password_key="$4"
immutable=false
check_only=false
[ "${5:-}" == "--immutable" ] && immutable=true
[ "${5:-}" == "--check-only" ] && immutable=true && check_only=true

source "$(dirname "$0")/mavenRepoCredentials.sh"

user=$(read_credential "$user_key")
password=$(read_credential "$password_key")
if [ -z "$user" ] || [ -z "$password" ]; then
  echo "Error: there are no credentials for $repo_url. Set $user_key and $password_key."
  exit 1
fi

if [ ! -d "$repo_dir" ]; then
  echo "Error: the staged repo $repo_dir does not exist."
  exit 1
fi

# Writes the .md5, .sha1, .sha256, and .sha512 files of one file, in the format that Gradle uses.
write_checksums() {
  local file="$1"
  local algorithm
  for algorithm in md5 sha1 sha256 sha512; do
    openssl dgst -"$algorithm" -r "$file" | cut -d' ' -f1 | tr -d '\n' > "$file.$algorithm"
  done
}

upload() {
  local file="$1"
  local path="${file#"$repo_dir"/}"
  if ! auth_curl --fail --silent --show-error --retry 3 --upload-file "$file" "$repo_url/$path" > /dev/null; then
    echo "Error: the upload of $path to $repo_url failed after $count files."
    exit 1
  fi
  count=$((count + 1))
}

# The staged maven-metadata.xml files list only the new versions, so the script merges them below.
staged_files=$(find "$repo_dir" -type f ! -name 'maven-metadata.xml*' | sort)

# An RC or a release version never changes after its first upload.
# Before any upload, the script compares each staged file with the file on the remote repo.
# An identical file is skipped, so a rerun after a broken upload can continue.
# A file with other bytes stops the job before any upload.
skipped=""
if [[ "$immutable" == "true" ]]; then
  remote_copy=$(mktemp)
  differ=false
  while IFS= read -r file; do
    path="${file#"$repo_dir"/}"
    status=$(auth_curl --silent --show-error --location --retry 3 --output "$remote_copy" \
      --write-out '%{http_code}' "$repo_url/$path") || status=000
    if [[ "$status" == "200" ]]; then
      if cmp -s "$file" "$remote_copy"; then
        skipped="$skipped$path"$'\n'
      else
        echo "Error: $repo_url already has $path with other content."
        differ=true
      fi
    elif [[ "$status" != "404" ]]; then
      rm -f "$remote_copy"
      echo "Error: the check of $path on $repo_url failed with HTTP $status."
      exit 1
    fi
  done <<< "$staged_files"
  rm -f "$remote_copy"
  if [[ "$differ" == "true" ]]; then
    echo "Error: an RC or a release file must not change. The script did not upload anything to $repo_url."
    exit 1
  fi
fi
if [[ "$check_only" == "true" ]]; then
  echo "Checked $repo_url: no staged file differs from a file that it already has."
  exit 0
fi

count=0
while IFS= read -r file; do
  if [ -n "$skipped" ] && grep -qxF "${file#"$repo_dir"/}" <<< "$skipped"; then
    continue
  fi
  upload "$file"
done <<< "$staged_files"
[ -n "$skipped" ] && echo "Skipped $(printf '%s' "$skipped" | grep -c .) files that $repo_url already has with the same content."

# The check before the upload cannot stop a second job that uploads the same RC or release at the same moment.
# So after the upload, the script downloads each file again. If another job replaced a file, the job fails.
if [[ "$immutable" == "true" ]]; then
  remote_copy=$(mktemp)
  while IFS= read -r file; do
    path="${file#"$repo_dir"/}"
    if ! auth_curl --fail --silent --show-error --location --retry 3 --output "$remote_copy" "$repo_url/$path" \
        || ! cmp -s "$file" "$remote_copy"; then
      rm -f "$remote_copy"
      echo "Error: $path on $repo_url is not the staged file after the upload. Another job can have uploaded the same version."
      exit 1
    fi
  done <<< "$staged_files"
  rm -f "$remote_copy"
  echo "Checked all $(printf '%s\n' "$staged_files" | grep -c .) files on $repo_url after the upload."
fi

# The maven-metadata.xml file of an artifact lists all its versions on the remote repo.
# Gradle reads it for dynamic versions (for example "+" or "latest.release").
# As Gradle does, the script adds the staged versions to the remote list and uploads the merged file.

# Downloads the maven-metadata.xml file of an artifact to <target>. Removes <target> if the file does not exist.
download_metadata() {
  local artifact_path="$1"
  local target="$2"
  local status
  status=$(auth_curl --silent --show-error --location --retry 3 --output "$target" \
    --write-out '%{http_code}' "$repo_url/$artifact_path/maven-metadata.xml") || status=000
  if [[ "$status" == "404" ]]; then
    rm -f "$target"
  elif [[ "$status" != "200" ]]; then
    echo "Error: the download of $artifact_path/maven-metadata.xml from $repo_url failed with HTTP $status."
    exit 1
  fi
}

# Writes <out> with the versions of <remote> plus the new versions. Without <remote>, it lists only the new versions.
merge_metadata() {
  python3 - "$@" <<'PY'
import os, sys, time
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

remote, out, artifact_path, *new_versions = sys.argv[1:]
parts = artifact_path.split("/")
versions = []
if os.path.exists(remote):
    versions = [v.text for v in ET.parse(remote).getroot().findall("versioning/versions/version")]
for version in new_versions:
    if version not in versions:
        versions.append(version)
newest = new_versions[-1]
lines = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    "<metadata>",
    "  <groupId>%s</groupId>" % escape(".".join(parts[:-1])),
    "  <artifactId>%s</artifactId>" % escape(parts[-1]),
    "  <versioning>",
    "    <latest>%s</latest>" % escape(newest),
    "    <release>%s</release>" % escape(newest),
    "    <versions>",
] + ["      <version>%s</version>" % escape(v) for v in versions] + [
    "    </versions>",
    "    <lastUpdated>%s</lastUpdated>" % time.strftime("%Y%m%d%H%M%S", time.gmtime()),
    "  </versioning>",
    "</metadata>",
]
with open(out, "w") as f:
    f.write("\n".join(lines) + "\n")
PY
}

# Prints each new version that <remote> does not list.
missing_versions() {
  python3 - "$@" <<'PY'
import os, sys
import xml.etree.ElementTree as ET

remote, *new_versions = sys.argv[1:]
listed = set()
if os.path.exists(remote):
    listed = {v.text for v in ET.parse(remote).getroot().findall("versioning/versions/version")}
print(" ".join(v for v in new_versions if v not in listed))
PY
}

# Two publish jobs at the same time can overwrite each other's merged file, as with Gradle.
# So after the upload, the script reads the remote file again. If a new version is missing, it merges again.
# The downloaded file stays outside the staged repo, so a rerun after a failed upload never uploads it.
remote_metadata=$(mktemp)
trap 'rm -f "$remote_metadata"' EXIT
while IFS= read -r artifact_dir; do
  artifact_path="${artifact_dir#"$repo_dir"/}"
  metadata="$artifact_dir/maven-metadata.xml"
  versions=()
  while IFS= read -r version_dir; do
    versions+=("$(basename "$version_dir")")
  done < <(find "$artifact_dir" -mindepth 1 -maxdepth 1 -type d | sort)

  attempt=1
  while :; do
    download_metadata "$artifact_path" "$remote_metadata"
    merge_metadata "$remote_metadata" "$metadata" "$artifact_path" "${versions[@]}"
    write_checksums "$metadata"
    for file in "$metadata" "$metadata".md5 "$metadata".sha1 "$metadata".sha256 "$metadata".sha512; do
      upload "$file"
    done

    download_metadata "$artifact_path" "$remote_metadata"
    missing=$(missing_versions "$remote_metadata" "${versions[@]}")
    rm -f "$remote_metadata"
    [ -z "$missing" ] && break
    if [ "$attempt" -ge 3 ]; then
      echo "Error: $artifact_path/maven-metadata.xml on $repo_url still misses: $missing"
      exit 1
    fi
    echo "Another job changed $artifact_path/maven-metadata.xml. The script merges it again."
    attempt=$((attempt + 1))
  done
done < <(find "$repo_dir" -name '*.pom' -exec dirname {} \; | xargs -n1 dirname | sort -u)

echo "Uploaded $count files to $repo_url."
