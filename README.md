# OpenMP Benchmarking Framework

Reproducible build–run–analyse pipeline for two image-processing programs (**Method A** and **Method B**) with multiple OpenMP variants (TC1–TC4).  
The framework compiles baselines and variants, runs a matrix of configurations on a Slurm cluster, validates outputs via MD5, and aggregates results to CSV + logs.

---

## ✨ Features

- One-command orchestration: `make all`
- Deterministic builds for:
  - Baselines: `a_seq`, `b_seq`
  - Variants: `a_tc*`, `b_tc*` (baked and matrix-driven)
- Reproducible runs on Slurm (`sbatch` + `srun`)
- Thread pinning and OpenMP runtime control
- Automatic MD5 validation and CSV aggregation
- Safe cleanups with result backup

---

## 📁 Repository Layout

```
.
├── Makefile
├── build.sh
├── run_all.sh
├── conf.sh
├── config.json
├── code/
│   ├── process-a.c
│   ├── process-b.c
│   ├── process-a_tc1.c  ... process-a_tc4.c
│   ├── process-b_tc1.c  ... process-b_tc4.c
│   ├── omp_sched_init.c
│   └── rawimage.h
├── outputs/             # generated artifacts (created at runtime)
│   ├── results.csv      # aggregated timings + metadata
│   ├── *.bin            # per-run binary outputs
│   └── *.stdout         # per-run logs (stdout)
└── master_results.log   # end-to-end run log (topology, Slurm IDs, summaries)
```

> `outputs/results.csv` and `master_results.log` are created by the framework during runs.

---

## 🧩 Prerequisites

- **GNU Make**
- **GCC 12+** (or compatible) with OpenMP (`-fopenmp`)
- **Slurm** (`sbatch`, `srun`)
- **jq** (Makefile reads `config.json`)
- Standard Linux tools: `bash`, `md5sum`, `numactl`, `lscpu`

---

## ⚙️ Configure

Edit `config.json`. Minimal example:

```json
{
  "inputs": {
    "dataset_root": "data/",
    "search_file": "data/search.rgb",
    "output_dir": "outputs"
  },
  "matrix": {
    "threads": [1, 2, 4, 8, 16, 32],
    "schedules": ["static", "dynamic", "guided", "auto"],
    "chunks": [64, 256, 1024]
  },
  "behaviour": {
    "verify_each_config": true,
    "strict_md5": true,
    "use_provided_golds": false,
    "stop_on_fail": false
  },
  "build": {
    "cc": "gcc",
    "cflags": "-O3 -std=c11 -Wall -Wextra -fopenmp"
  },
  "slurm": {
    "partition": "k2-medpri",
    "cpus_per_task": 32,
    "time": "02:00:00",
    "job_name": "omp-bench"
  },
  "notify": {
    "email": "",
    "on_begin": false,
    "on_end": false,
    "on_fail": true
  }
}
```

---

## 🚀 Quick Start

```bash
# One-shot pipeline: clean → build → run → summarise
make all

# Step-by-step
make clean
make build
make run
```

### Make Targets

- **`make all`** — Clean, build, submit batch run, summarise.
- **`make build`** — Compiles baselines and variants. Emits `a_tc*`, `b_tc*`.
- **`make run`** — Submits `run_all.sh` via `sbatch` using `config.json`.
- **`make clean`** — Backs up `outputs/results.csv` (timestamped) and removes binaries + generated outputs.

---

## 🧪 What Happens During `make run`

`run_all.sh`:

1. Loads configuration via `conf.sh`.
2. Captures environment snapshot (`lscpu`, `numactl`, Slurm IDs) → `master_results.log`.
3. Computes or uses gold MD5s (from `a_seq`/`b_seq` or provided).
4. Discovers `a_tc*` / `b_tc*` and classifies:
   - **Baked** variants: schedule/chunk compiled into filename (ignore `OMP_SCHEDULE`).
   - **Matrix** variants: driven by `matrix` in `config.json`.
5. Iterates configurations with `srun`, binding threads to cores:
   - Sets `OMP_NUM_THREADS` and (for matrix) `OMP_SCHEDULE`.
   - Validates MD5, times run, appends row to `outputs/results.csv`.
6. Prints summary (fastest overall + per method) to `master_results.log`.

Row schema in `results.csv`:

```
exe,tag,threads,schedule,chunk,md5_ok,time_ms
```

---

## 🧵 OpenMP Runtime Defaults

The runner enforces reproducible binding:

```bash
export OMP_PROC_BIND=close
export OMP_PLACES=cores
# OMP_SCHEDULE is set only for matrix-driven variants.
```

> Slurm CPU allocation is respected; thread counts are capped by `--cpus-per-task`.

---

## 👟 Common Workflows

### Narrow the sweep
Edit `matrix` in `config.json`, e.g.:

```json
"matrix": {
  "threads": [1, 8, 16, 32],
  "schedules": ["static", "dynamic"],
  "chunks": [256]
}
```

### Resume after timeout
The runner skips tags already in `outputs/results.csv`.  
Increase `"slurm.time"` if needed and re-run `make run`.

### Add a new test case
Add a file like:

```
code/process-a_tc5.c
```

If it uses `schedule(runtime)`, the build emits baked combos; otherwise it produces a single binary.

> Naming convention: `a_tc{N}` / `b_tc{N}`; baked files include schedule/chunk in the filename.

---

## 📊 Results

- **CSV:** `outputs/results.csv` — authoritative timing + validation table
- **Run logs:** `outputs/*.stdout` — per-execution outputs
- **Master log:** `master_results.log` — hardware snapshot & summaries

Import the CSV into Python/Excel/LaTeX for tables/plots.

---

## 🛠️ Troubleshooting

**Build ok, run fails / MD5 mismatch**
- Verify dataset paths in `config.json`.
- Set `"use_provided_golds": false` to regenerate baseline MD5s.
- Ensure matrix variants actually use `schedule(runtime)`.

**Slow or unstable at high threads**
- Reduce `"threads"` or prefer `dynamic/guided` with modest `"chunks"` (e.g., 64–256).
- Increase Slurm time (`"time": "04:00:00"`).

**“Set .slurm.partition in config.json”**
- Fill `"slurm.partition"` with a valid queue/partition and re-run.

**Outputs directory noisy**
- `make clean` backs up `outputs/results.csv` and removes generated artifacts.

---

## 🔧 Manual Single Run (Debugging)

```bash
export OMP_NUM_THREADS=16
export OMP_PROC_BIND=close
export OMP_PLACES=cores
export OMP_SCHEDULE="dynamic,256"    # ignored by baked variants

srun --cpu-bind=cores ./a_tc1_dynamic_256 input.rgb > outputs/a_tc1_t16.out
```

---

## 📈 Reproducibility Notes

- Use consistent `cc`/`cflags` in `config.json`.
- Keep `OMP_PROC_BIND` / `OMP_PLACES` for stable placement.
- The `tag` uniquely identifies (method, TC, threads, schedule, chunk).
- Record NUMA/topology from `master_results.log` for cross-node comparisons.

---


## 🙌 Acknowledgements

Developed for coursework benchmarking of OpenMP scheduling and performance on Slurm-managed AMD EPYC nodes.
