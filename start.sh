#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TABLESPACE_DIR="/home/docker-data/postgres18/tablespaces/neon_vertex_tbs"

echo "Criando diretório do tablespace..."
mkdir -p "$TABLESPACE_DIR"

echo "Subindo containers..."
cd "$SCRIPT_DIR"
docker compose up -d

echo "Aguardando container ficar saudável..."
until docker inspect --format='{{.State.Health.Status}}' postgres18 2>/dev/null | grep -q healthy; do
    sleep 1
done

echo "Ajustando permissões com o UID real do usuário postgres..."
PG_UID=$(docker exec postgres18 id -u postgres)
PG_GID=$(docker exec postgres18 id -g postgres)
chown -R "${PG_UID}:${PG_GID}" "$TABLESPACE_DIR"

echo "Pronto. UID/GID aplicado: ${PG_UID}:${PG_GID}"