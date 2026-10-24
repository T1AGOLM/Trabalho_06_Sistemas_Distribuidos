#!/usr/bin/env bash
# Roda N repetições de um cenário.
# Uso: ./scripts/run_partial.sh <cenario> <usuarios> <perfil> <repeticoes>
#
# É um atalho para o runner principal (que é retomável e coleta CPU):
#   ONLY=<cenario> REPETITIONS=<n> ./run_experiments.sh

set -uo pipefail

CENARIO="${1:?uso: $0 <cenario> <usuarios> <perfil> <repeticoes>}"
USERS="${2:-}"
PROFILE="${3:-}"
REPETITIONS="${4:-10}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Executando ${REPETITIONS} repetição(ões) de ${CENARIO}."
[[ -n "${USERS}" || -n "${PROFILE}" ]] && echo "  (argumentos recebidos: usuarios=${USERS:-?}, perfil=${PROFILE:-?})"

ONLY="${CENARIO}" REPETITIONS="${REPETITIONS}" exec bash "${PROJECT_DIR}/run_experiments.sh"
