#!/usr/bin/env bash

USER_IMAGE=fiaisis/mantid

TOKEN="$(
  curl "https://ghcr.io/token?scope=repository:${USER_IMAGE}:pull" |
  awk -F'"' '$0=$4'
)"

# get tags
curl -H "Authorization: Bearer ${TOKEN}" "$1" "https://ghcr.io/v2/${USER_IMAGE}/tags/list"

# get manifest of the latest image
MANTID6_8=$(curl -H "Authorization: Bearer ${TOKEN}" "$1" "https://ghcr.io/v2/${USER_IMAGE}/manifests/6.8.0" | sha256sum)
MANTID6_9=$(curl -H "Authorization: Bearer ${TOKEN}" "$1" "https://ghcr.io/v2/${USER_IMAGE}/manifests/6.9.0" | sha256sum)
MANTID6_9_1=$(curl -H "Authorization: Bearer ${TOKEN}" "$1" "https://ghcr.io/v2/${USER_IMAGE}/manifests/6.9.1" | sha256sum)

echo "6.8 sha256 = $MANTID6_8"
echo "6.9 sha256 = $MANTID6_9"
echo "6.9.1 sha256 = $MANTID6_9_1"