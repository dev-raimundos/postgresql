#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TABLESPACE_DIR="/home/docker-data/postgres18/tablespaces/neon_vertex_tbs"

if docker inspect postgres18 &>/dev/null; then
    PG_UID=$(docker exec postgres18 id -u postgres)
    PG_GID=$(docker exec postgres18 id -g postgres)
else
    PG_UID=999
    PG_GID=999
fi

echo "Criando diretório do tablespace..."
mkdir -p "$TABLESPACE_DIR"
chown -R "${PG_UID}:${PG_GID}" "$TABLESPACE_DIR"

echo "Subindo containers..."
cd "$SCRIPT_DIR"
docker compose up -d