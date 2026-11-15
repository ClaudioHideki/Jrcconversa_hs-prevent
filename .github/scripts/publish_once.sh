#!/usr/bin/env bash
set -euo pipefail
error_file="$(mktemp)"
trap 'rm -f "$error_file"' EXIT
if docker buildx imagetools inspect "$IMAGE_REF" > /dev/null 2> "$error_file"; then
  echo "Refusing to overwrite existing tag: $IMAGE_REF" >&2
  exit 1
elif [ "$(cat "$error_file")" != "ERROR: $IMAGE_REF: not found" ]; then
  cat "$error_file" >&2
  exit 1
fi
docker push "$IMAGE_REF"
digest="$(docker buildx imagetools inspect "$IMAGE_REF" --format '{{.Manifest.Digest}}')"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]
printf 'digest=%s\n' "$digest" >> "$GITHUB_OUTPUT"
