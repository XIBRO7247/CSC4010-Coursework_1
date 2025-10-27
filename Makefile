.PHONY: all build run list dry local clean

PART := $(shell jq -r '.slurm.partition // ""' config.json)
CPUS := $(shell jq -r '.slurm.cpus_per_task // 32' config.json)
TIME := $(shell jq -r '.slurm.time // "02:00:00"' config.json)
NAME := $(shell jq -r '.slurm.job_name // "csc4010-batch"' config.json)

# Default: build + submit to SLURM
all: preflight build run

# Optional pre-clean before each build
preflight:
	@echo "🧹 Checking for previous build artifacts..."
	@if ls a_seq b_seq a_tc* b_tc* omp_sched_init.o 1>/dev/null 2>&1; then \
	  echo "   Found old build artifacts — cleaning first..."; \
	  $(MAKE) --no-print-directory clean; \
	else \
	  echo "   No old binaries found, skipping cleanup."; \
	fi

# Build baselines and variants
build:
	./build.sh

# Submit full batch to SLURM

run:
	@if [ -z "$(PART)" ] || [ "$(PART)" = "null" ]; then \
	  echo "Set .slurm.partition in config.json or pass PART=<partition>"; exit 1; \
	fi
	echo "Using Partiton: $(PART) with job name "
	sbatch -p $(PART) -J $(NAME) -N 1 --ntasks=1 --cpus-per-task=$(CPUS) --time=$(TIME) run_all.sh


# Optional modes
list:
	sbatch --wrap="bash run_all.sh --list"

dry:
	sbatch --wrap="bash run_all.sh --dry-run"

local:
	bash run_all.sh

# Safe cleanup — doesn't error if files are missing
clean:
	@echo "🧽 Cleaning outputs and binaries..."
	@rm -f a_seq b_seq a_tc* b_tc* omp_sched_init.o 2>/dev/null || true
	@if [ -f outputs/results.csv ]; then \
      ts=$$(date +%Y%m%d-%H%M%S); \
      cp outputs/results.csv outputs/results-$$ts.csv; \
      echo "Backed up outputs/results.csv -> outputs/results-$$ts.csv"; \
    fi
	@rm -f outputs/*.bin outputs/*.stdout outputs/results.csv 2>/dev/null || true
	@echo "Clean complete."
