#!/usr/bin/env bash
# conf.sh — load config.json (if jq present), expose settings as env vars, and auto-resolve inputs.
set -euo pipefail
CONFIG="${CONFIG:-config.json}"

# Predeclare arrays so nounset won't explode on length checks
declare -a THREADS=()
declare -a SCHEDULES=()
declare -a CHUNKS=()

_have_jq() { command -v jq >/dev/null 2>&1; }

# Convert JSON array -> bash array; usage: _json_to_arr VAR 'jq_query'
_json_to_arr() {
  local __var="$1" __q="$2" __tmp
  __tmp=$(jq -r "$__q // [] | map(tostring) | @sh" "$CONFIG")
  if [[ -z "$__tmp" ]]; then
    eval "$__var=()"
  else
    eval "$__var=($__tmp)"
  fi
}

load_config() {
  if [[ -f "$CONFIG" ]]; then
    if _have_jq; then
      # Inputs
      export DATASET="$(jq -r '.inputs.dataset // "small"' "$CONFIG")"
      export DATA_ROOT="$(jq -r '.inputs.data_root // "data"' "$CONFIG")"
      export OUTDIR="$(jq -r '.inputs.outdir // "outputs"' "$CONFIG")"
      export LOG="$(jq -r '.inputs.log // "master_results.log"' "$CONFIG")"

      # Optional: whether to use provided gold outputs (A/B) instead of computing fresh baselines
      local upg; upg="$(jq -r '.inputs.use_provided_golds // false' "$CONFIG")"
      export USE_PROVIDED_GOLDS=$([[ "$upg" == "true" ]] && echo 1 || echo 0)

      # Matrix
      _json_to_arr THREADS   '.matrix.threads'
      _json_to_arr SCHEDULES '.matrix.schedules'
      mapfile -t CHUNKS < <(jq -r '.matrix.chunks // [] | map(if .==null then "" else tostring end)[]' "$CONFIG")

      # Behaviour
      local strict stopfail verifycfg
      strict="$(jq -r '.behaviour.strict_md5 // false' "$CONFIG")"
      stopfail="$(jq -r '.behaviour.stop_on_testcase_fail // true' "$CONFIG")"
      verifycfg="$(jq -r '.behaviour.verify_each_config // true' "$CONFIG")"
      export STRICT_MD5=$([[ "$strict" == "true" ]] && echo 1 || echo 0)
      export STOP_ON_TESTCASE_FAIL=$([[ "$stopfail" == "true" ]] && echo 1 || echo 0)
      export VERIFY_EACH_CONFIG=$([[ "$verifycfg" == "true" ]] && echo 1 || echo 0)

      # Build
      export CC="$(jq -r '.build.cc // "gcc"' "$CONFIG")"
      export CFLAGS_SEQ="$(jq -r '.build.cflags_seq // "-O3 -std=c11"' "$CONFIG")"
      export CFLAGS_OMP="$(jq -r '.build.cflags_omp // "-O3 -fopenmp -std=c11"' "$CONFIG")"
      export LDFLAGS="$(jq -r '.build.ldflags // ""' "$CONFIG")"

      # SLURM info (used by run logs / submission)
      export SLURM_JOB_NAME_CFG="$(jq -r '.slurm.job_name // "csc4010-batch"' "$CONFIG")"
      export SLURM_ACCOUNT_CFG="$(jq -r '.slurm.account // ""' "$CONFIG")"
      export SLURM_PARTITION_CFG="$(jq -r '.slurm.partition // "standard"' "$CONFIG")"
      export SLURM_NODES_CFG="$(jq -r '.slurm.nodes // 1' "$CONFIG")"
      export SLURM_NTASKS_CFG="$(jq -r '.slurm.ntasks // 1' "$CONFIG")"
      export SLURM_CPUS_PER_TASK_CFG="$(jq -r '.slurm.cpus_per_task // 32' "$CONFIG")"
      export SLURM_TIME_CFG="$(jq -r '.slurm.time // "02:00:00"' "$CONFIG")"
      export SLURM_STDOUT_CFG="$(jq -r '.slurm.stdout // "slurm.%j.out"' "$CONFIG")"
      export SLURM_STDERR_CFG="$(jq -r '.slurm.stderr // "slurm.%j.err"' "$CONFIG")"

      # Notifications
      export SLURM_NOTIFY_EMAIL="$(jq -r '.notify.email // ""' "$CONFIG")"
      export SLURM_NOTIFY_BEGIN="$(jq -r '.notify.on_begin // false' "$CONFIG")"
      export SLURM_NOTIFY_END="$(jq -r '.notify.on_end // true' "$CONFIG")"
      export SLURM_NOTIFY_FAIL="$(jq -r '.notify.on_fail // true' "$CONFIG")"
    else
      echo "[conf.sh] WARNING: '$CONFIG' exists but 'jq' not found; using built-in defaults/env overrides." >&2
      # Fallbacks (env may override)
      DATASET=${DATASET:-small}
      DATA_ROOT=${DATA_ROOT:-data}
      OUTDIR=${OUTDIR:-outputs}
      LOG=${LOG:-master_results.log}
      THREADS=(${THREADS:-1 2 4 8 16 32})
      SCHEDULES=(${SCHEDULES:-static dynamic guided auto})
      CHUNKS=(${CHUNKS:-} 64 256 1024)
      STRICT_MD5=${STRICT_MD5:-0}
      STOP_ON_TESTCASE_FAIL=${STOP_ON_TESTCASE_FAIL:-1}
      VERIFY_EACH_CONFIG=${VERIFY_EACH_CONFIG:-1}
      CC=${CC:-gcc}
      CFLAGS_SEQ=${CFLAGS_SEQ:-"-O3 -std=c11"}
      CFLAGS_OMP=${CFLAGS_OMP:-"-O3 -fopenmp -std=c11"}
      LDFLAGS=${LDFLAGS:-}
      SLURM_NOTIFY_EMAIL=${SLURM_NOTIFY_EMAIL:-}
      SLURM_NOTIFY_BEGIN=${SLURM_NOTIFY_BEGIN:-false}
      SLURM_NOTIFY_END=${SLURM_NOTIFY_END:-true}
      SLURM_NOTIFY_FAIL=${SLURM_NOTIFY_FAIL:-true}
    fi
  else
    # No config.json at all → pure env/defaults
    DATASET=${DATASET:-small}
    DATA_ROOT=${DATA_ROOT:-data}
    OUTDIR=${OUTDIR:-outputs}
    LOG=${LOG:-master_results.log}
    THREADS=(${THREADS:-1 2 4 8 16 32})
    SCHEDULES=(${SCHEDULES:-static dynamic guided auto})
    CHUNKS=(${CHUNKS:-} 64 256 1024)
    STRICT_MD5=${STRICT_MD5:-0}
    STOP_ON_TESTCASE_FAIL=${STOP_ON_TESTCASE_FAIL:-1}
    VERIFY_EACH_CONFIG=${VERIFY_EACH_CONFIG:-1}
    CC=${CC:-gcc}
    CFLAGS_SEQ=${CFLAGS_SEQ:-"-O3 -std=c11"}
    CFLAGS_OMP=${CFLAGS_OMP:-"-O3 -fopenmp -std=c11"}
    LDFLAGS=${LDFLAGS:-}
    SLURM_NOTIFY_EMAIL=${SLURM_NOTIFY_EMAIL:-}
    SLURM_NOTIFY_BEGIN=${SLURM_NOTIFY_BEGIN:-false}
    SLURM_NOTIFY_END=${SLURM_NOTIFY_END:-true}
    SLURM_NOTIFY_FAIL=${SLURM_NOTIFY_FAIL:-true}
  fi

  # Ensure arrays have sane defaults (works even if they’re unset/empty)
  if [[ -z ${THREADS+x} || ${#THREADS[@]} -eq 0 ]];   then THREADS=(1 2 4 8 16 32); fi
  if [[ -z ${SCHEDULES+x} || ${#SCHEDULES[@]} -eq 0 ]]; then SCHEDULES=(static dynamic guided auto); fi
  if [[ -z ${CHUNKS+x} || ${#CHUNKS[@]} -eq 0 ]];     then CHUNKS=("" 64 256 1024); fi  # "" means null

  DATASET=${DATASET:-small}
}

validate_config() {
  # threads must be positive ints
  for t in "${THREADS[@]}"; do
    [[ "$t" =~ ^[0-9]+$ && "$t" -ge 1 ]] || { echo "Invalid thread count: '$t'"; exit 2; }
  done
  # schedules limited to these
  for s in "${SCHEDULES[@]}"; do
    [[ -z "$s" || "$s" =~ ^(static|dynamic|guided|auto)$ ]] || { echo "Invalid schedule: '$s'"; exit 2; }
  done
  # chunks must be "" (means null) or positive ints
  for c in "${CHUNKS[@]}"; do
    [[ -z "$c" || ( "$c" =~ ^[0-9]+$ && "$c" -ge 1 ) ]] || { echo "Invalid chunk: '$c'"; exit 2; }
  done
}

# Choose INFILE/SEARCH by scanning dataset dir (supports .raw and .bin)
resolve_inputs() {
  local dir_small="$DATA_ROOT/rawdata"
  local dir_large="$DATA_ROOT/rawdata-large"
  local dir
  case "${DATASET,,}" in
    small) dir="$dir_small" ;;
    large) dir="$dir_large" ;;
    *) echo "ERROR: DATASET must be 'small' or 'large' (got '$DATASET')" >&2; exit 2 ;;
  esac
  [[ -d "$dir" ]] || { echo "ERROR: dataset dir not found: $dir" >&2; exit 2; }

  local infile="" search=""

  # Prefer .raw, then fall back to .bin
  infile=$(find "$dir" -type f \( -name '*.raw' -o -name '*.bin' \) -iname 'input*'   -printf '%s %p\n' 2>/dev/null | sort -nr | awk 'NR==1{print $2; exit}')
  [[ -n "$infile" ]] || infile=$(find "$dir" -type f \( -name '*.raw' -o -name '*.bin' \) -printf '%s %p\n' 2>/dev/null | sort -nr | awk 'NR==1{print $2; exit}')
  search=$(find "$dir" -type f \( -name '*.raw' -o -name '*.bin' \) -iname '*search*' -printf '%s %p\n' 2>/dev/null | sort -nr | awk 'NR==1{print $2; exit}')
  [[ -n "$search" ]] || search=$(find "$dir" -type f \( -name '*.raw' -o -name '*.bin' \) -printf '%s %p\n' 2>/dev/null | sort -n | awk 'NR==1{print $2; exit}')

  [[ -n "${infile:-}" && -n "${search:-}" ]] || {
    echo "ERROR: could not auto-detect INFILE/SEARCH in $dir" >&2
    echo "  Expected .raw or .bin files; tried largest as INFILE and '*search*' (or smallest) as SEARCH." >&2
    exit 3
  }

  export INFILE="$infile"
  export SEARCH="$search"
}

print_config_summary() {
  local tcnt=${#THREADS[@]} scnt=${#SCHEDULES[@]} ccnt=${#CHUNKS[@]}
  echo "[cfg] dataset=$DATASET data_root=$DATA_ROOT outdir=$OUTDIR log=$LOG"
  echo "[cfg] matrix: threads=$tcnt (${THREADS[*]}) schedules=$scnt (${SCHEDULES[*]}) chunks=$ccnt ($(printf '%s ' "${CHUNKS[@]}"))"
  echo "[cfg] behaviour: strict_md5=$STRICT_MD5 stop_on_testcase_fail=$STOP_ON_TESTCASE_FAIL verify_each_config=$VERIFY_EACH_CONFIG"
  echo "[cfg] notify: email=${SLURM_NOTIFY_EMAIL:-none} begin=${SLURM_NOTIFY_BEGIN} end=${SLURM_NOTIFY_END} fail=${SLURM_NOTIFY_FAIL}"
}
