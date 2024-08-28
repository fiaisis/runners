#!/usr/bin/env bash
MANTID_VERSIONS=("6.8.0" "6.9.0"  "6.9.1")

for MANTID_VERSION in "${MANTID_VERSIONS[@]}"
do
  docker build . -f ./Mantid/Dockerfile -t ghcr.io/fiaisis/mantid:"$MANTID_VERSION" --build-arg="MANTID_VERSION=$MANTID_VERSION"
done

docker push ghcr.io/fiaisis/mantid -a