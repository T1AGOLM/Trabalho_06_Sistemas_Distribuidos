#!/usr/bin/env bash
# Roda um cenário completo (todas as repetições) de cada vez.
# Uso: ./scripts/run_single_scenario.sh <cenario> <usuarios> <perfil>
#
# É um atalho para o runner principal (que é retomável e coleta CPU):
#   ONLY=<cenario> ./run_experiments.sh

set -uo pipefail

CENARIO="${1:?uso: $0 <cenario> <usuarios> <perfil>}"
USERS="${2:-}"
PROFILE="${3:-}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# USERS e PROFILE são derivados do nome do cenário; avisamos se divergirem.
echo "Executando o cenário ${CENARIO} (usuários/perfil definidos no run_experiments.sh)."
[[ -n "${USERS}" || -n "${PROFILE}" ]] && echo "  (argumentos recebidos: usuarios=${USERS:-?}, perfil=${PROFILE:-?})"

ONLY="${CENARIO}" exec bash "${PROJECT_DIR}/run_experiments.sh"
