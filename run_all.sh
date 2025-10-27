#!/usr/bin/env bash
#SBATCH -J csc4010-batch
# (partition optional) pick one of your valid partitions or let Slurm choose:
# #SBATCH -p k2-medpri
# #SBATCH -p k2-lowpri
# #SBATCH -p k2-hipri
#SBATCH -N 1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --time=02:00:00
#SBATCH -o slurm.%j.out
#SBATCH -e slurm.%j.err

set -euo pipefail

# --- Prevent "unbound variable" when OMP_SCHEDULE isn't set ---
: "${OMP_SCHEDULE:=}"     # default empty is fine; or use: dynamic / static,64 etc.
export OMP_SCHEDULE

# ---------- CLI helpers ----------
DRYRUN=0; LISTONLY=0; RESUME=1
for a in "$@"; do
  [[ "$a" == "--dry-run"   ]] && DRYRUN=1
  [[ "$a" == "--list"      ]] && LISTONLY=1
  [[ "$a" == "--no-resume" ]] && RESUME=0
done
do_srun() { ((DRYRUN)) && { echo "[DRY] srun $*"; return 0; }; srun "$@"; }

# ---------- Load config & inputs ----------
source ./conf.sh
load_config
if declare -F validate_config >/dev/null 2>&1; then validate_config; fi
resolve_inputs

CONFIG="${CONFIG:-config.json}"

# Reproducible thread placement
export OMP_PROC_BIND=close
export OMP_PLACES=cores

# ---- Case selection & provided golds toggles from config.json ----
if command -v jq >/dev/null 2>&1 && [[ -f "$CONFIG" ]]; then
  CASE_SEL="$(jq -r '.inputs.case // "all"' "$CONFIG")"
  USE_GOLDS="$(jq -r '.inputs.use_provided_golds // false' "$CONFIG")"
else
  CASE_SEL="${CASE_SEL:-all}"
  USE_GOLDS="${USE_GOLDS:-false}"
fi
CASE_SEL="${CASE_SEL,,}"
[[ "$CASE_SEL" =~ ^(a|b|all)$ ]] || CASE_SEL="all"

# ---- Email notifications from config.json (BEGIN/END/FAIL) ----
_can_mail() {
  [[ -n "${SLURM_NOTIFY_EMAIL:-}" ]] && {
    command -v mailx >/dev/null || command -v mail >/dev/null || command -v sendmail >/dev/null
  }
}
if [[ -n "${SLURM_NOTIFY_EMAIL:-}" ]] && ! _can_mail; then
  echo "[notify] Email set to '$SLURM_NOTIFY_EMAIL' but no mailer found (mailx/mail/sendmail). Notifications disabled."
fi
_send_mail() {
  local subj="$1" body="$2" to="${SLURM_NOTIFY_EMAIL:-}"
  [[ -z "$to" ]] && return 0
  if command -v mailx >/dev/null 2>&1; then
    printf "%s" "$body" | mailx -s "$subj" "$to" || true
  elif command -v mail >/dev/null 2>&1; then
    printf "%s" "$body" | mail -s "$subj" "$to" || true
  elif command -v sendmail >/dev/null 2>&1; then
    { echo "To: $to"; echo "Subject: $subj"; echo; printf "%s" "$body"; } | sendmail -t || true
  fi
}

# Cap THREADS by Slurm allocation (de-dup if capped)
MAX_CPUS=${SLURM_CPUS_PER_TASK:-${SLURM_CPUS_ON_NODE:-0}}
if [[ "${MAX_CPUS:-0}" -gt 0 ]]; then
  tmp=()
  for t in "${THREADS[@]}"; do
    (( t > MAX_CPUS )) && tmp+=("$MAX_CPUS") || tmp+=("$t")
  done
  mapfile -t THREADS < <(printf "%s\n" "${tmp[@]}" | awk '!seen[$0]++')
fi

# ---- Job traps for email on END/FAIL ----
JOB_STATUS="SUCCESS"
trap 'JOB_STATUS="FAIL"' ERR
trap '
  if _can_mail; then
    jid="${SLURM_JOB_ID:-N/A}"; node="$(hostname)"; when="$(date)"
    body="Job: ${SLURM_JOB_NAME:-csc4010-batch} (ID: $jid)
Node: $node
When: $when
Dataset: $DATASET
Inputs: $(basename "$INFILE") / $(basename "$SEARCH")
Log: $(realpath "$LOG" 2>/dev/null || echo "$LOG")
Status: $JOB_STATUS"
    if [[ "$JOB_STATUS" == "FAIL" && "${SLURM_NOTIFY_FAIL:-true}" == "true" ]]; then
      _send_mail "[SLURM][FAIL] ${SLURM_JOB_NAME:-csc4010-batch} (ID: $jid)" "$body"
    elif [[ "${SLURM_NOTIFY_END:-true}" == "true" ]]; then
      _send_mail "[SLURM][END] ${SLURM_JOB_NAME:-csc4010-batch} (ID: $jid)" "$body"
    fi
  fi
' EXIT

if _can_mail && [[ "${SLURM_NOTIFY_BEGIN:-false}" == "true" ]]; then
  _send_mail "[SLURM][BEGIN] ${SLURM_JOB_NAME:-csc4010-batch} (ID: ${SLURM_JOB_ID:-N/A})" \
             "Job started on $(hostname) at $(date)
Dataset: $DATASET
Inputs: $(basename "$INFILE") / $(basename "$SEARCH")
Log: $(realpath "$LOG" 2>/dev/null || echo "$LOG")"
fi

# ---------------------------------------------------------------
STOP_ON_TESTCASE_FAIL=${STOP_ON_TESTCASE_FAIL:-1}

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1"; exit 1; }; }
require md5sum; require srun; require awk; require grep

mkdir -p "$OUTDIR"
: > "$LOG"

# Config + environment into the log
print_config_summary | tee -a "$LOG"
echo "[cfg] case=${CASE_SEL}   use_provided_golds=${USE_GOLDS}" | tee -a "$LOG"
echo "[cfg] infile=$INFILE"    | tee -a "$LOG"
echo "[cfg] search=$SEARCH"    | tee -a "$LOG"
echo "=== CSC4010 Batch Start: $(date) ===" | tee -a "$LOG"
echo "Node: $(hostname)  JobID: ${SLURM_JOB_ID:-N/A}" | tee -a "$LOG"
echo "OpenMP: OMP_PROC_BIND=${OMP_PROC_BIND:-} OMP_PLACES=${OMP_PLACES:-} OMP_SCHEDULE=${OMP_SCHEDULE:-unset}" | tee -a "$LOG"
echo | tee -a "$LOG"

{
  echo "=== ENV SNAPSHOT ==="
  echo "SLURM: ntasks=${SLURM_NTASKS:-?} cpus-per-task=${SLURM_CPUS_PER_TASK:-?} jobid=${SLURM_JOB_ID:-?}"
  command -v lscpu  >/dev/null && lscpu  | sed 's/^/lscpu: /'
  command -v numactl>/dev/null && numactl --hardware 2>/dev/null | sed 's/^/numactl: /'
  echo "===================="
  echo
} | tee -a "$LOG"

echo "[cfg] threads (capped to ${MAX_CPUS:-?}): ${THREADS[*]}" | tee -a "$LOG"

((LISTONLY)) && echo "[LIST] build skipped (listing only)" || ./build.sh
[[ "$CASE_SEL" == "b" || -x a_seq ]] || { echo "Baseline a_seq missing"; exit 1; }
[[ "$CASE_SEL" == "a" || -x b_seq ]] || { echo "Baseline b_seq missing"; exit 1; }

RESULTS_CSV="$OUTDIR/results.csv"
if (( !LISTONLY && !DRYRUN )); then
  [[ -f "$RESULTS_CSV" ]] || echo "exe,tag,threads,schedule,chunk,md5_ok,time_ms" >"$RESULTS_CSV"
fi

# already_done <tag>  -> exit 0 if tag present in results.csv
already_done() {
  local tag="$1"
  [[ -f "$RESULTS_CSV" ]] || return 1
  awk -F',' -v t="$tag" 'NR>1 && $2==t {found=1; exit} END{exit !found}' "$RESULTS_CSV"
}

# --- Run one config; return 0 on MD5 match, 1 on mismatch ---
run_case_md5 () {
  local exe="$1" method="$2" tag="$3" gold="$4"
  local out="$OUTDIR/${tag}.bin"
  local sout="$OUTDIR/${tag}.stdout"
  rm -f "$out" "$sout" 2>/dev/null || true

  local t0 t1 ms
  t0=$(date +%s%N)
  do_srun --cpu-bind=cores --ntasks=1 --cpus-per-task="${OMP_NUM_THREADS:-1}" \
          "./$exe" "$INFILE" "$out" "$SEARCH" >"$sout" 2>>"$LOG"
  t1=$(date +%s%N); ms=$(( (t1 - t0)/1000000 ))

  local md5; md5=$(md5sum "$out" | awk '{print $1}')

  {
    echo "=== TESTCASE $exe | tag=$tag | OMP_NUM_THREADS=${OMP_NUM_THREADS} OMP_SCHEDULE=${OMP_SCHEDULE:-unset} ==="
    echo "MD5: $md5  (gold: $gold)"
    echo "Time_ms: $ms"
    grep -E '^\*\* ' "$sout" || echo "(no '**' lines found)"
    echo
  } >> "$LOG"

  # CSV line (safe even if OMP_SCHEDULE is unset due to set -u)
  if (( !DRYRUN && !LISTONLY )); then
    local schedule chunk
    if [[ -n "${OMP_SCHEDULE-}" ]]; then
      schedule="${OMP_SCHEDULE%%,*}"
      if [[ "${OMP_SCHEDULE-}" == *","* ]]; then
        chunk="${OMP_SCHEDULE##*,}"
      else
        chunk="baked"
      fi
    else
      schedule="baked"
      chunk="baked"
    fi
    echo "$exe,$tag,${OMP_NUM_THREADS},$schedule,$chunk,$([[ "$md5" == "$gold" ]] && echo 1 || echo 0),$ms" >> "$RESULTS_CSV"
  fi

  if [[ "$md5" == "$gold" ]]; then
    rm -f "$out" "$sout"
    return 0
  else
    mv "$out"  "${out%.bin}_FAIL_${md5}.bin"
    mv "$sout" "${sout%.stdout}_FAIL.stdout"
    return 1
  fi
}

# ---------- Baselines or Provided Golds ----------
GOLD_A="<unknown>"; GOLD_B="<unknown>"
USE_GOLD_A=0; USE_GOLD_B=0

if (( !LISTONLY && !DRYRUN )); then
  if [[ "${USE_GOLDS}" == "true" ]]; then
    data_dir="$(dirname "$INFILE")"

    if [[ "$CASE_SEL" != "b" ]]; then
      GOLD_A_FILE=$(find "$data_dir" -maxdepth 1 -iregex '.*(output.*-a|.*-a\.raw|.*-a\.bin)$' -print | head -n1 || true)
      if [[ -n "${GOLD_A_FILE:-}" ]]; then
        GOLD_A=$(md5sum "$GOLD_A_FILE" | awk '{print $1}')
        USE_GOLD_A=1
        echo "[gold] Using provided A gold: $(basename "$GOLD_A_FILE") -> $GOLD_A" | tee -a "$LOG"
      fi
    fi
    if [[ "$CASE_SEL" != "a" ]]; then
      GOLD_B_FILE=$(find "$data_dir" -maxdepth 1 -iregex '.*(output.*-b|.*-b\.raw|.*-b\.bin)$' -print | head -n1 || true)
      if [[ -n "${GOLD_B_FILE:-}" ]]; then
        GOLD_B=$(md5sum "$GOLD_B_FILE" | awk '{print $1}')
        USE_GOLD_B=1
        echo "[gold] Using provided B gold: $(basename "$GOLD_B_FILE") -> $GOLD_B" | tee -a "$LOG"
      fi
    fi
  fi

  echo "== Baselines (sequential) ==" | tee -a "$LOG"
  export OMP_NUM_THREADS=1
  unset OMP_SCHEDULE

  if [[ "$CASE_SEL" != "b" && "$USE_GOLD_A" -eq 0 ]]; then
    BASE_A="$OUTDIR/A_baseline.bin"
    do_srun --cpus-per-task=1 ./a_seq "$INFILE" "$BASE_A" "$SEARCH" > "$OUTDIR/A_baseline.stdout"
    GOLD_A=$(md5sum "$BASE_A" | awk '{print $1}')
    echo "GOLD_A: $GOLD_A" | tee -a "$LOG"
    grep -E '^\*\* ' "$OUTDIR/A_baseline.stdout" >> "$LOG" || true
    rm -f "$OUTDIR/A_baseline.stdout"
  fi

  if [[ "$CASE_SEL" != "a" && "$USE_GOLD_B" -eq 0 ]]; then
    BASE_B="$OUTDIR/B_baseline.bin"
    do_srun --cpus-per-task=1 ./b_seq "$INFILE" "$BASE_B" "$SEARCH" > "$OUTDIR/B_baseline.stdout"
    GOLD_B=$(md5sum "$BASE_B" | awk '{print $1}')
    echo "GOLD_B: $GOLD_B" | tee -a "$LOG"
    grep -E '^\*\* ' "$OUTDIR/B_baseline.stdout" >> "$LOG" || true
    rm -f "$OUTDIR/B_baseline.stdout"
  fi
  echo >> "$LOG"
fi

# ---------- Discover built executables ----------
shopt -s nullglob
mapfile -t ALL_A < <(ls -1 a_tc* 2>/dev/null | grep -E '^(a_tc[0-9]+(_[A-Za-z0-9]+)*)$' | sort -V || true)
mapfile -t ALL_B < <(ls -1 b_tc* 2>/dev/null | grep -E '^(b_tc[0-9]+(_[A-Za-z0-9]+)*)$' | sort -V || true)
shopt -u nullglob

# Apply case filter
if [[ "$CASE_SEL" == "a" ]]; then ALL_B=(); fi
if [[ "$CASE_SEL" == "b" ]]; then ALL_A=(); fi

if (( ${#ALL_A[@]} == 0 && ${#ALL_B[@]} == 0 )); then
  echo "[warn] No built executables found (a_tc*/b_tc*). Nothing to run."
  echo "=== DONE: $(date) ===" | tee -a "$LOG"
  exit 0
fi

echo "Found built Method A executables: ${#ALL_A[@]} -> ${ALL_A[*]:-(none)}" | tee -a "$LOG"
echo "Found built Method B executables: ${#ALL_B[@]} -> ${ALL_B[*]:-(none)}" | tee -a "$LOG"
echo >> "$LOG"

is_baked () { [[ "$1" =~ _ ]]; }  # contains underscore after tcN

PASSED_A=(); FAILED_A=()
PASSED_B=(); FAILED_B=()

run_matrix_driven () {
  local exe="$1" method="$2" gold="$3"
  local tc="${exe##${method}_tc}"
  local fail=0
  local first_run=1

  for th in "${THREADS[@]}"; do
    ((fail)) && break
    export OMP_NUM_THREADS="$th"
    for sch in "${SCHEDULES[@]}"; do
      ((fail)) && break
      for chk in "${CHUNKS[@]}"; do
        ((fail)) && break

        # Guard: schedule(auto) ignores chunk sizes
        if [[ "$sch" == "auto" && -n "$chk" ]]; then
          continue
        fi

        if [[ -n "$chk" ]]; then
          export OMP_SCHEDULE="${sch},${chk}"
          local sched_tag="${sch}${chk}"
        else
          export OMP_SCHEDULE="${sch}"
          local sched_tag="${sch}"
        fi

        local tag
        tag="$(printf "%s_tc%s_t%s_%s" "${method^^}" "$tc" "$th" "$sched_tag")"
        echo "[${method^^}] $exe -> $tag" | tee -a "$LOG"

        # Resume: skip if tag already recorded
        if (( RESUME )) && already_done "$tag"; then
          echo "[SKIP] already in results.csv: $tag" | tee -a "$LOG"
          continue
        fi

        if (( LISTONLY )); then continue; fi
        if (( DRYRUN  )); then
          do_srun --cpu-bind=cores --ntasks=1 --cpus-per-task="$th" "./$exe" "$INFILE" /dev/null "$SEARCH" >/dev/null 2>&1
          continue
        fi

        if (( first_run || VERIFY_EACH_CONFIG )); then
          if run_case_md5 "$exe" "${method^^}" "$tag" "$gold"; then
            first_run=0
          else
            echo "[${method^^}] MD5 FAIL for $exe ($tag).$( ((STOP_ON_TESTCASE_FAIL)) && echo ' Stopping remaining configs for this testcase.' )" | tee -a "$LOG"
            ((STOP_ON_TESTCASE_FAIL)) && fail=1
            ((STRICT_MD5)) && { echo "[${method^^}] STRICT mode aborting whole job." | tee -a "$LOG"; exit 2; }
          fi
        else
          do_srun --cpu-bind=cores --ntasks=1 --cpus-per-task="$th" "./$exe" "$INFILE" /dev/null "$SEARCH" >/dev/null 2>&1
        fi
      done
    done
  done

  if [[ "$method" == "a" ]]; then
    ((fail)) && FAILED_A+=("$exe") || PASSED_A+=("$exe")
  else
    ((fail)) && FAILED_B+=("$exe") || PASSED_B+=("$exe")
  fi
}

run_baked () {
  local exe="$1" method="$2" gold="$3"
  local tc="${exe##${method}_tc}"; tc="${tc%%_*}"
  local suffix="${exe#${method}_tc${tc}_}"
  local fail=0

  for th in "${THREADS[@]}"; do
    export OMP_NUM_THREADS="$th"
    unset OMP_SCHEDULE
    local tag
    tag="$(printf "%s_tc%s_t%s_%s" "${method^^}" "$tc" "$th" "$suffix")"
    echo "[${method^^}] $exe -> $tag" | tee -a "$LOG"

    # Resume: skip if tag already recorded
    if (( RESUME )) && already_done "$tag"; then
      echo "[SKIP] already in results.csv: $tag" | tee -a "$LOG"
      continue
    fi

    if (( LISTONLY )); then continue; fi
    if (( DRYRUN  )); then
      do_srun --cpu-bind=cores --ntasks=1 --cpus-per-task="$th" "./$exe" "$INFILE" /dev/null "$SEARCH" >/dev/null 2>&1
      continue
    fi

    if run_case_md5 "$exe" "${method^^}" "$tag" "$gold"; then
      :
    else
      echo "[${method^^}] MD5 FAIL for $exe ($tag).$( ((STOP_ON_TESTCASE_FAIL)) && echo ' Stopping remaining threads for this testcase.' )" | tee -a "$LOG"
      ((STOP_ON_TESTCASE_FAIL)) && { fail=1; break; }
      ((STRICT_MD5)) && { echo "[${method^^}] STRICT mode aborting whole job." | tee -a "$LOG"; exit 2; }
    fi
  done

  if [[ "$method" == "a" ]]; then
    ((fail)) && FAILED_A+=("$exe") || PASSED_A+=("$exe")
  else
    ((fail)) && FAILED_B+=("$exe") || PASSED_B+=("$exe")
  fi
}

# --- Execute ---
for exe in "${ALL_A[@]}"; do
  [[ -x "$exe" ]] || continue
  if is_baked "$exe"; then run_baked "$exe" "a" "$GOLD_A"; else run_matrix_driven "$exe" "a" "$GOLD_A"; fi
done
for exe in "${ALL_B[@]}"; do
  [[ -x "$exe" ]] || continue
  if is_baked "$exe"; then run_baked "$exe" "b" "$GOLD_B"; else run_matrix_driven "$exe" "b" "$GOLD_B"; fi
done

# Clean baseline artifacts (skip in list mode)
if (( !LISTONLY )); then rm -f "${BASE_A:-}" "${BASE_B:-}"; fi

echo "=== DONE: $(date) ===" | tee -a "$LOG"

# -------------------------
# FASTEST CONFIGURATION (from results.csv) — in addition to the standard summary
# -------------------------
if [[ -f "$RESULTS_CSV" && "$LISTONLY" -eq 0 && "$DRYRUN" -eq 0 ]]; then
  fastest_line=$(awk -F',' 'NR>1 && $6==1 {if(min=="" || $7<min){min=$7; line=$0}} END{print line}' "$RESULTS_CSV")
  if [[ -n "$fastest_line" ]]; then
    IFS=',' read -r exe tag threads sched chunk md5_ok time_ms <<<"$fastest_line"
    echo
    echo "  Fastest configuration (overall):"
    echo "  Executable : $exe"
    echo "  Tag        : $tag"
    echo "  Threads    : $threads"
    echo "  Schedule   : $sched"
    echo "  Chunk      : $chunk"
    echo "  Time (ms)  : $time_ms"
  else
    echo
    echo "⚡ No successful timings recorded."
  fi

  fastest_A=$(awk -F',' 'NR>1 && $6==1 && $1 ~ /^a_/ {if(min=="" || $7<min){min=$7; line=$0}} END{print line}' "$RESULTS_CSV")
  if [[ -n "$fastest_A" ]]; then
    IFS=',' read -r exe tag threads sched chunk md5_ok time_ms <<<"$fastest_A"
    echo
    echo "  Fastest configuration (Method A):"
    echo "  Executable : $exe"
    echo "  Tag        : $tag"
    echo "  Threads    : $threads"
    echo "  Schedule   : $sched"
    echo "  Chunk      : $chunk"
    echo "  Time (ms)  : $time_ms"
  fi

  fastest_B=$(awk -F',' 'NR>1 && $6==1 && $1 ~ /^b_/ {if(min=="" || $7<min){min=$7; line=$0}} END{print line}' "$RESULTS_CSV")
  if [[ -n "$fastest_B" ]]; then
    IFS=',' read -r exe tag threads sched chunk md5_ok time_ms <<<"$fastest_B"
    echo
    echo "  Fastest configuration (Method B):"
    echo "  Executable : $exe"
    echo "  Tag        : $tag"
    echo "  Threads    : $threads"
    echo "  Schedule   : $sched"
    echo "  Chunk      : $chunk"
    echo "  Time (ms)  : $time_ms"
  fi
fi

# -------------------------
# End-of-job summary (stdout only; NOT written to $LOG)
# -------------------------
join_by() { local IFS="$1"; shift; echo "$*"; }
echo
echo "==================== SUMMARY (stdout only) ===================="
echo "Dataset  : $DATASET  (root: $DATA_ROOT)"
echo "Inputs   : INFILE=$(basename "$INFILE") | SEARCH=$(basename "$SEARCH")"
echo "Results  :"
echo "  Method A -> PASSED: ${#PASSED_A[@]}  FAILED: ${#FAILED_A[@]}"
(( ${#PASSED_A[@]} )) && echo "    ✓ $(join_by ' ' "${PASSED_A[@]}")"
(( ${#FAILED_A[@]} )) && echo "    ✗ $(join_by ' ' "${FAILED_A[@]}")"
echo "  Method B -> PASSED: ${#PASSED_B[@]}  FAILED: ${#FAILED_B[@]}"
(( ${#PASSED_B[@]} )) && echo "    ✓ $(join_by ' ' "${PASSED_B[@]}")"
(( ${#FAILED_B[@]} )) && echo "    ✗ $(join_by ' ' "${FAILED_B[@]}")"
echo "CSV      : $RESULTS_CSV"
echo "Log file : $LOG"
echo "=============================================================="
