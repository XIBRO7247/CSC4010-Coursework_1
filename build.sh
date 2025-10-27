#!/usr/bin/env bash
# build.sh – builds baselines, then scans each *_tcN.c and, if schedule(runtime) is present,
# generates baked schedule/chunk executables per config.json. Otherwise builds a single exe.
set -euo pipefail

source ./conf.sh
load_config
# call validate_config only if present
if declare -F validate_config >/dev/null 2>&1; then validate_config; fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1"; exit 1; }; }
need "${CC:-gcc}"
[[ -f rawimage.h ]] || { echo "Missing rawimage.h"; exit 1; }

CC=${CC:-gcc}
CFLAGS_SEQ=${CFLAGS_SEQ:-"-O3 -std=c11"}
CFLAGS_OMP=${CFLAGS_OMP:-"-O3 -fopenmp -std=c11"}
LDFLAGS=${LDFLAGS:-}

# Sanity: does compiler accept OpenMP flags?
${CC} ${CFLAGS_OMP} -dM -E - </dev/null >/dev/null 2>&1 || {
  echo "ERROR: compiler doesn’t accept OpenMP flags: CC='${CC}' CFLAGS_OMP='${CFLAGS_OMP}'"; exit 2;
}

echo ">>> build.sh starting (pwd=$(pwd))"
echo ">>> conf.sh sourced"
echo ">>> config loaded"
echo ">>> CC=${CC}"
echo ">>> CFLAGS_SEQ=${CFLAGS_SEQ}"
echo ">>> CFLAGS_OMP=${CFLAGS_OMP}"
echo ">>> LDFLAGS=${LDFLAGS:-<empty>}"

echo "==> Building sequential baselines"
for m in a b; do
  src="process-${m}.c"
  out="${m}_seq"
  [[ -f "$src" ]] || { echo "Missing $src"; exit 1; }
  echo "  $src -> $out"
  $CC $CFLAGS_SEQ "$src" -o "$out" $LDFLAGS
done

# Compile the OpenMP schedule shim once (needed for baked variants).
if [[ -f omp_sched_init.c ]]; then
  echo "==> Compiling OpenMP schedule shim"
  $CC -c $CFLAGS_OMP omp_sched_init.c -o omp_sched_init.o
else
  : # only needed when baking; we'll error later if missing
fi

echo "==> Scanning & building variants (process-a_tc*.c / process-b_tc*.c)"
shopt -s nullglob
variants=(process-a_tc*.c process-b_tc*.c)

scan_runtime_applicability() {
  # Return 0 if file contains '#pragma omp ... schedule(runtime)' outside of comments
  awk '
    BEGIN{inblk=0}
    {
      line=$0
      sub(/\/\/.*/,"",line)                         # strip //...
      while (1) {                                   # strip /* ... */ blocks
        if (inblk) {
          if (match(line,/\*\//)) { line=substr(line,RSTART+2); inblk=0 } else { line=""; break }
        } else {
          if (match(line,/\/\*/)) { line=substr(line,1,RSTART-1); inblk=1 } else { break }
        }
      }
      if (line ~ /#pragma[[:space:]]+omp[^(]*schedule[[:space:]]*\([[:space:]]*runtime[[:space:]]*\)/) { print "HIT"; exit }
    }
  ' "$1" | grep -q HIT
}

build_single() {
  local src="$1" out="$2"
  echo "  $src -> $out  [no runtime schedule found → single build]"
  $CC $CFLAGS_OMP "$src" -o "$out" $LDFLAGS
}

build_baked() {
  local src="$1" out="$2" kind="$3" chunk="$4"
  [[ -f omp_sched_init.o ]] || {
    echo "ERROR: omp_sched_init.c is required to bake schedules/chunks for $src";
    echo "       Hint: ensure omp_sched_init.c exists and rerun ./build.sh";
    exit 1;
  }
  local defs=""
  case "$kind" in
    static|dynamic|guided|auto) defs+=" -DFIX_KIND_${kind}";;
    "" ) :;;
    *  ) echo "  !! Unknown schedule kind '$kind' for $out";;
  esac
  if [[ -n "$chunk" ]]; then
    defs+=" -DFIX_CHUNK=${chunk}"
  fi
  echo "  $src -> $out  [baked: ${kind}${chunk:+,$chunk}]"
  $CC $CFLAGS_OMP $defs "$src" omp_sched_init.o -o "$out" $LDFLAGS
}

if (( ${#variants[@]} == 0 )); then
  echo "  (no *_tc*.c variants found)"
else
  # Matrix availability (safe now that arrays are declared in conf.sh)
  local_have_scheds=${#SCHEDULES[@]}
  numeric_chunks=()
  have_empty_chunk=0
  for c in "${CHUNKS[@]}"; do
    if [[ -z "$c" ]]; then
      have_empty_chunk=1
    else
      numeric_chunks+=("$c")
    fi
  done

  built_count=0
  for src in "${variants[@]}"; do
    bn=$(basename "$src")
    if   [[ "$bn" =~ ^process-a_tc([0-9]+)\.c$ ]]; then base="a_tc${BASH_REMATCH[1]}"
    elif [[ "$bn" =~ ^process-b_tc([0-9]+)\.c$ ]]; then base="b_tc${BASH_REMATCH[1]}"
    else echo "  Skip (name not recognised): $bn"; continue
    fi

    if scan_runtime_applicability "$src"; then
      # The tc supports runtime schedule → build per config.json
      if (( local_have_scheds > 0 && ${#numeric_chunks[@]} > 0 )); then
        for sch in "${SCHEDULES[@]}"; do
          if [[ "$sch" == "auto" ]]; then
            # schedule(auto) ignores chunks – only build one variant
            build_baked "$src" "${base}_auto" "$sch" ""
            continue
          fi
          for chk in "${numeric_chunks[@]}"; do
            build_baked "$src" "${base}_${sch}_${chk}" "$sch" "$chk"
          done
          (( have_empty_chunk )) && build_baked "$src" "${base}_${sch}" "$sch" ""
        done
      elif (( local_have_scheds > 0 )); then
        # schedules only
        for sch in "${SCHEDULES[@]}"; do
          build_baked "$src" "${base}_${sch}" "$sch" ""
        done
      elif (( ${#numeric_chunks[@]} > 0 )); then
        # chunks only (leave kind to env default)
        for chk in "${numeric_chunks[@]}"; do
          build_baked "$src" "${base}_${chk}" "" "$chk"
        done
      else
        # matrix has neither → single runtime-capable build
        build_single "$src" "$base"
      fi
    else
      # No schedule(runtime) anywhere → cannot tune via env; single build
      build_single "$src" "$base"
    fi
    built_count=$((built_count+1))
  done
fi
shopt -u nullglob
echo "Built ${built_count:-0} variant executable(s)."
echo "Build complete"
