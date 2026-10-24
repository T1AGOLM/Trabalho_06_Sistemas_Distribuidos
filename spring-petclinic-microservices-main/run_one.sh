#!/usr/bin/env bash
# Roda UMA única repetição do Locust (útil para demonstração/vídeo).
# Uso: ./run_one.sh <nome_cenario> <usuarios> <perfil> <rid>
# Ex:  ./run_one.sh A-Leitura-30 30 read 1
#
# Para o experimento completo use ./run_experiments.sh (retomável).

set -uo pipefail

CENARIO="${1:?uso: $0 <cenario> <usuarios> <perfil> <rid>}"
USERS="${2:?}"
PROFILE="${3:?}"
RID="${4:?}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ONLY="${CENARIO}" \
START_REP="${RID}" \
REPETITIONS="${RID}" \
FORCE=1 \
  exec bash "${PROJECT_DIR}/run_experiments.sh"
