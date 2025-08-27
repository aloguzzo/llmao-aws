#!/usr/bin/env bash
set -euo pipefail

cd /opt/app
git pull --ff-only || git fetch --all --prune
cd compose
docker compose pull
docker compose up -d
docker image prune -f