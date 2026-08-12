#!/bin/bash
set -euo pipefail

TABLESPACE_DIR="/home/docker-data/postgres18-tablespaces/neon_vertex_tbs"

mkdir -p "$TABLESPACE_DIR"
chown -R 999:999 "$TABLESPACE_DIR"

docker compose up -d
