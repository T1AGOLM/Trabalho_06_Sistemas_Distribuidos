#!/usr/bin/env bash
# ===========================================================================
# run_experiments.sh
#
# Executa os 6 cenários (2 perfis × 3 cargas) × 10 repetições = 60 execuções
# do Locust contra o Spring PetClinic Microservices e coleta, além das
# métricas do Locust, a utilização de CPU dos containers durante cada
# execução.
#
# Uso:
#   ./run_experiments.sh
#
# Variáveis de ambiente (todas opcionais):
#   RUN_TIME=6m            duração de cada execução (formato do Locust)
#   WARMUP_SECONDS=60      aquecimento descartado das estatísticas
#   REPETITIONS=10         repetições por cenário
#   START_REP=1            primeira repetição (usado pelo run_one.sh)
#   ONLY=A-Leitura-30      executa somente um cenário
#   FORCE=1                refaz repetições que já têm resultado
#   RESET_STATE=1          reinicia o customers-service entre repetições para
#                          zerar o banco em memória (default: 1)
#   CPU_CONTAINERS="..."   containers monitorados via docker stats
#   BASE_URL=...           URL do API Gateway (default: http://localhost:8080)
#   RESULTS_DIR=...        diretório de saída (default: ./results)
#
# O script é retomável: repetições que já possuem *_stats.csv são puladas,
# então basta rodar o mesmo comando novamente depois de uma interrupção.
# ===========================================================================

set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${RESULTS_DIR:-${PROJECT_DIR}/results}"
LOCUSTFILE="${PROJECT_DIR}/locustfile.py"
LOCUST="${LOCUST:-$(command -v locust || true)}"
[[ -z "${LOCUST}" ]] && LOCUST="${HOME}/.local/bin/locust"

RUN_TIME="${RUN_TIME:-6m}"
WARMUP_SECONDS="${WARMUP_SECONDS:-60}"
REPETITIONS="${REPETITIONS:-10}"
START_REP="${START_REP:-1}"
ONLY="${ONLY:-}"
FORCE="${FORCE:-0}"
RESET_STATE="${RESET_STATE:-1}"
CPU_CONTAINERS="${CPU_CONTAINERS:-api-gateway customers-service vets-service}"
CPU_SAMPLE_INTERVAL="${CPU_SAMPLE_INTERVAL:-5}"
ABORT_FAILURE_PCT="${ABORT_FAILURE_PCT:-50}"

# Performance dos cenários: (nome, usuários, perfil)
declare -a SCENARIOS=(
  "A-Leitura-30:30:read"
  "A-Escrita-30:30:write"
  "B-Leitura-80:80:read"
  "B-Escrita-80:80:write"
  "C-Leitura-150:150:read"
  "C-Escrita-150:150:write"
)

log() { echo "[$(date '+%F %T')] $*"; }
warn() { echo "[$(date '+%F %T')] AVISO: $*" >&2; }

duration_to_seconds() {
  local d="$1"
  case "${d}" in
    *s) echo $(( ${d%s} )) ;;
    *m) echo $(( ${d%m} * 60 )) ;;
    *h) echo $(( ${d%h} * 3600 )) ;;
    *)  echo "${d}" ;;
  esac
}

RUN_SECONDS=$(duration_to_seconds "${RUN_TIME}")
LOCUST_TIMEOUT=$(( RUN_SECONDS + 180 ))

# Sem sentido descartar mais aquecimento do que a própria duração da execução.
if (( RUN_SECONDS <= WARMUP_SECONDS )); then
  warn "RUN_TIME (${RUN_TIME}) menor que o aquecimento (${WARMUP_SECONDS}s): aquecimento desativado"
  WARMUP_SECONDS=0
fi

# ---------------------------------------------------------------------------
# Disponibilidade da aplicação
# ---------------------------------------------------------------------------
# Após start/reinício o API Gateway responde 405/503 por até ~30 s enquanto
# o registro Eureka e o circuit breaker se estabilizam. Por isso exigimos uma
# sequência de respostas 200 (padrão: 8 amostras a cada 2 s = 16 s estável)
# antes de iniciar a carga.
wait_for_app() {
  local required="${1:-8}" interval="${2:-2}"
  local streak=0 attempts=0 max_attempts=60
  while (( attempts < max_attempts )); do
    if curl -sf -o /dev/null --max-time 5 "${BASE_URL}/api/customer/owners" 2>/dev/null; then
      streak=$((streak + 1))
      (( streak >= required )) && return 0
    else
      streak=0
    fi
    sleep "${interval}"
    attempts=$((attempts + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Coleta de CPU durante a execução
# ---------------------------------------------------------------------------
# Cada amostra usa `docker stats --no-stream`, cujo percentual é a média do
# intervalo desde a leitura anterior — com amostras a cada 5 s, obtém-se uma
# série temporal real da carga. O arquivo gerado é <prefixo>_cpu.csv.
cpu_sampler() {
  local out="$1" stop="$2"
  local names
  read -r -a names <<< "${CPU_CONTAINERS}"

  {
    printf 'timestamp'
    for n in "${names[@]}"; do printf ',%s' "$n"; done
    printf '\n'
  } > "${out}"

  while [[ ! -f "${stop}" ]]; do
    local row stats n v line
    row="$(date +%s)"
    stats="$(timeout 8 docker stats --no-stream --format '{{.Name}},{{.CPUPerc}}' "${names[@]}" 2>/dev/null | tr -d '%')"
    for n in "${names[@]}"; do
      v="$(printf '%s\n' "${stats}" | awk -F, -v n="${n}" '$1 == n {print $2; exit}')"
      row+=",${v}"
    done
    printf '%s\n' "${row}" >> "${out}"
    sleep "${CPU_SAMPLE_INTERVAL}"
  done
}

# ---------------------------------------------------------------------------
# Reset do estado entre repetições
# ---------------------------------------------------------------------------
# O POST /owners grava no HSQLDB em memória do customers-service. Sem reset,
# a resposta de GET /owners cresce a cada repetição e o tempo de resposta
# medido passa a depender da ordem das execuções, não da carga.
reset_state() {
  [[ "${RESET_STATE}" == "1" ]] || return 0

  if ! docker inspect customers-service > /dev/null 2>&1; then
    warn "container customers-service não encontrado; reset de estado ignorado"
    return 0
  fi

  log "  Reiniciando customers-service para zerar o banco em memória..."
  if ! docker restart customers-service > /dev/null 2>&1; then
    warn "não foi possível reiniciar customers-service; seguindo sem reset"
    return 0
  fi

  if ! wait_for_app 8 2; then
    warn "aplicação não voltou a responder de forma estável após o reinício"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Resumo de uma execução
# ---------------------------------------------------------------------------
print_run_summary() {
  local stats_csv="$1" cpu_csv="$2"
  local line
  line="$(awk -F, '
    NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    $col["Name"] == "Aggregated" {
      printf "Reqs=%s  Falhas=%s  RPS=%.2f  Avg=%.1f ms  P95=%s ms",
             $col["Request Count"], $col["Failure Count"],
             $col["Requests/s"], $col["Average Response Time"], $col["95%"];
      printf "\n"
      exit
    }' "${stats_csv}" 2>/dev/null)"
  [[ -n "${line}" ]] && log "  ${line}"

  if [[ -s "${cpu_csv}" ]]; then
    # primeira e última amostras são descartadas: a primeira cobre o boot do
    # container e a última pega o instante em que o Locust já encerrou.
    line="$(awk -F, '
      NR == 1 { for (i = 2; i <= NF; i++) name[i] = $i; next }
      { rows[NR] = $0 }
      END {
        last = NR
        for (r = 3; r < last; r++) {
          split(rows[r], f, ",")
          for (i = 2; i <= NF; i++) if (f[i] != "") { sum[i] += f[i]; n[i]++ }
        }
        for (i = 2; i <= NF; i++)
          if (n[i] > 0) printf "CPU(%s)=%.1f%% ", name[i], sum[i] / n[i]
        print ""
      }' "${cpu_csv}" 2>/dev/null)"
    [[ -n "${line}" ]] && log "  ${line}"
  fi
}

stats_failure_pct() {
  awk -F, '
    NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    $col["Name"] == "Aggregated" {
      req = $col["Request Count"]; fail = $col["Failure Count"]
      if (req > 0) printf "%.2f", fail * 100 / req; else print "0"
      exit
    }' "$1" 2>/dev/null
}

has_result() {
  local scenario="$1" rep="$2"
  [[ -n "$(find "${RESULTS_DIR}" -maxdepth 1 -name "${scenario}-r${rep}-*.csv_stats.csv" -print -quit 2>/dev/null)" ]]
}

# ---------------------------------------------------------------------------
# Verificações iniciais
# ---------------------------------------------------------------------------
if [[ ! -x "${LOCUST}" ]]; then
  echo "ERRO: Locust não encontrado em ${LOCUST}." >&2
  echo "Instale com: pip install locust" >&2
  exit 1
fi
if [[ ! -f "${LOCUSTFILE}" ]]; then
  echo "ERRO: ${LOCUSTFILE} não encontrado." >&2
  exit 1
fi

mkdir -p "${RESULTS_DIR}"

if [[ -n "${ONLY}" ]] && ! printf '%s\n' "${SCENARIOS[@]}" | cut -d: -f1 | grep -qx "${ONLY}"; then
  echo "ERRO: cenário '${ONLY}' não existe. Opções:" >&2
  printf '  %s\n' "${SCENARIOS[@]}" | cut -d: -f1 >&2
  exit 1
fi

TOTAL_PENDING=0
for entry in "${SCENARIOS[@]}"; do
  IFS=: read -r name _ _ <<< "${entry}"
  [[ -n "${ONLY}" && "${name}" != "${ONLY}" ]] && continue
  for rep in $(seq "${START_REP}" "${REPETITIONS}"); do
    if [[ "${FORCE}" == "1" ]] || ! has_result "${name}" "${rep}"; then
      TOTAL_PENDING=$((TOTAL_PENDING + 1))
    fi
  done
done

if (( TOTAL_PENDING == 0 )); then
  echo "Todas as execuções já possuem resultados em ${RESULTS_DIR}."
  echo "Use FORCE=1 para refazer."
  exit 0
fi

EST_MIN=$(( TOTAL_PENDING * (RUN_SECONDS + 40) / 60 ))

log "=== Trabalho 06 — Avaliação de desempenho com Locust ==="
log "  Host: ${BASE_URL}"
log "  Execuções pendentes: ${TOTAL_PENDING} (${RUN_TIME} cada, aquecimento ${WARMUP_SECONDS}s)"
log "  Tempo estimado: ~$(( EST_MIN / 60 ))h$(( EST_MIN % 60 ))min (inclui reset de estado)"
log "  Resultados: ${RESULTS_DIR}"
log "  Interrompa com Ctrl+C e rode novamente para continuar de onde parou."

if ! wait_for_app 3 2; then
  echo "ERRO: ${BASE_URL} não está respondendo." >&2
  echo "Inicie a aplicação antes: docker compose up -d   (ou ./scripts/run_all.sh)" >&2
  exit 1
fi

for CONTAINER in ${CPU_CONTAINERS}; do
  if ! docker inspect "${CONTAINER}" > /dev/null 2>&1; then
    warn "container '${CONTAINER}' não encontrado: a coleta de CPU ficará vazia."
    warn "suba a aplicação com 'docker compose up -d' para coletar CPU por serviço."
  fi
done

# ---------------------------------------------------------------------------
# Loop principal
# ---------------------------------------------------------------------------
CURRENT_SAMPLER=""
CURRENT_STOP=""
CURRENT_PREFIX=""

cleanup() {
  [[ -n "${CURRENT_STOP}" ]] && touch "${CURRENT_STOP}"
  [[ -n "${CURRENT_SAMPLER}" ]] && kill "${CURRENT_SAMPLER}" 2>/dev/null
  if [[ -n "${CURRENT_LOCUST:-}" ]]; then
    kill -TERM "${CURRENT_LOCUST}" 2>/dev/null
    wait "${CURRENT_LOCUST}" 2>/dev/null
  fi
}

# Uma execução interrompida no meio gera CSVs parciais; apaga para que a
# repetição seja refeita na próxima vez (o log é mantido para diagnóstico).
discard_partial_run() {
  [[ -n "${CURRENT_PREFIX}" ]] || return 0
  rm -f "${CURRENT_PREFIX}"_stats.csv "${CURRENT_PREFIX}"_stats_history.csv \
        "${CURRENT_PREFIX}"_failures.csv "${CURRENT_PREFIX}"_exceptions.csv \
        "${CURRENT_PREFIX}"_cpu.csv "${CURRENT_PREFIX}".cpu.stop
}

trap 'echo; log "Interrompido. Rode o mesmo comando para continuar de onde parou."; cleanup; discard_partial_run; exit 130' INT TERM

for entry in "${SCENARIOS[@]}"; do
  IFS=: read -r SCENARIO_NAME USERS PROFILE <<< "${entry}"

  if [[ -n "${ONLY}" && "${SCENARIO_NAME}" != "${ONLY}" ]]; then
    continue
  fi

  if [[ "${PROFILE}" == "read" ]]; then
    PROFILE_CLASS="ReadProfile"
  else
    PROFILE_CLASS="WriteProfile"
  fi

  log ""
  log "============================================"
  log "  Cenário: ${SCENARIO_NAME}  (usuários=${USERS}, perfil=${PROFILE})"
  log "============================================"

  for REP in $(seq "${START_REP}" "${REPETITIONS}"); do
    RUN_ID="${SCENARIO_NAME}-r${REP}"

    if [[ "${FORCE}" != "1" ]] && has_result "${SCENARIO_NAME}" "${REP}"; then
      log "  ${RUN_ID}: já executado — pulando"
      continue
    fi

    if ! wait_for_app 3 2; then
      echo "ERRO: ${BASE_URL} parou de responder antes de ${RUN_ID}." >&2
      echo "Reinicie a aplicação e rode este script novamente: ele continua de onde parou." >&2
      cleanup
      exit 1
    fi

    if ! reset_state; then
      echo "ERRO: não foi possível preparar o estado para ${RUN_ID}." >&2
      cleanup
      exit 1
    fi

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOG_FILE="${RESULTS_DIR}/${RUN_ID}-${TIMESTAMP}.log"
    CSV_FILE="${RESULTS_DIR}/${RUN_ID}-${TIMESTAMP}.csv"
    CPU_FILE="${CSV_FILE}_cpu.csv"
    CURRENT_PREFIX="${CSV_FILE}"

    log "  ${RUN_ID}: iniciando (duração ${RUN_TIME}, ${USERS} usuários)"
    RUN_START=$(date +%s)

    CURRENT_STOP="${CSV_FILE}.cpu.stop"
    rm -f "${CURRENT_STOP}"
    cpu_sampler "${CPU_FILE}" "${CURRENT_STOP}" &
    CURRENT_SAMPLER=$!

    WARMUP_SECONDS="${WARMUP_SECONDS}" timeout --kill-after=30s "${LOCUST_TIMEOUT}s" "${LOCUST}" \
      -f "${LOCUSTFILE}" \
      --headless \
      -u "${USERS}" \
      -r 10 \
      --run-time "${RUN_TIME}" \
      --csv "${CSV_FILE}" \
      --host "${BASE_URL}" \
      "${PROFILE_CLASS}" > "${LOG_FILE}" 2>&1 &
    CURRENT_LOCUST=$!

    # Aviso de progresso: mostra que a execução está viva.
    LAST_PROGRESS=${RUN_START}
    while kill -0 "${CURRENT_LOCUST}" 2>/dev/null; do
      sleep 1
      NOW=$(date +%s)
      if (( NOW - LAST_PROGRESS >= 30 )) && kill -0 "${CURRENT_LOCUST}" 2>/dev/null; then
        log "  ${RUN_ID}: em andamento há $(( NOW - RUN_START ))s"
        LAST_PROGRESS=${NOW}
      fi
    done
    wait "${CURRENT_LOCUST}"
    LOCUST_EXIT=$?

    touch "${CURRENT_STOP}"
    wait "${CURRENT_SAMPLER}" 2>/dev/null
    CURRENT_SAMPLER=""
    CURRENT_LOCUST=""
    CURRENT_PREFIX=""
    rm -f "${CURRENT_STOP}"

    if [[ ${LOCUST_EXIT} -eq 124 || ${LOCUST_EXIT} -eq 137 ]]; then
      warn "${RUN_ID}: Locust não encerrou sozinho e foi interrompido (código ${LOCUST_EXIT}). Veja ${LOG_FILE}"
    elif [[ ${LOCUST_EXIT} -ne 0 ]]; then
      warn "${RUN_ID}: Locust saiu com código ${LOCUST_EXIT}. Veja ${LOG_FILE}"
    fi

    STATS_CSV="${CSV_FILE}_stats.csv"
    if [[ -f "${STATS_CSV}" ]]; then
      print_run_summary "${STATS_CSV}" "${CPU_FILE}"
    else
      warn "${RUN_ID}: ${STATS_CSV} não foi gerado; repetição será refeita na próxima execução"
      continue
    fi

    FAIL_PCT="$(stats_failure_pct "${STATS_CSV}")"
    if [[ -n "${FAIL_PCT}" ]] && awk -v p="${FAIL_PCT}" -v t="${ABORT_FAILURE_PCT}" 'BEGIN { exit !(p > t) }'; then
      warn "${RUN_ID}: ${FAIL_PCT}% de falhas (> ${ABORT_FAILURE_PCT}%). Interrompendo para não comprometer o experimento."
      echo "A execução inválida foi descartada; verifique ${BASE_URL} e rode novamente" >&2
      echo "(o script continua de onde parou)." >&2
      CURRENT_PREFIX="${CSV_FILE}"
      discard_partial_run
      CURRENT_PREFIX=""
      cleanup
      exit 1
    fi

    log "  ${RUN_ID}: concluída em $(( $(date +%s) - RUN_START ))s"
  done
done

echo ""
log "============================================"
log "  Execuções concluídas. Resultados em: ${RESULTS_DIR}"
log "  Agora execute: python3 generate_charts.py"
log "============================================"
