SHELL := /bin/bash
PROJECT_ID ?= $(shell gcloud config get-value project 2>/dev/null)
REGION     ?= us-central1
ZONE       ?= us-central1-c

.PHONY: help test-local tf-init tf-apply bootstrap-substrate build-images seed-db run-showcase run-meta-gate window-close teardown

help:
	@echo "SwarmRSI + pi-mono + Harness2 + Harbor on Google Cloud (GA MVP)"
	@echo "  make test-local          Run local unit & 4-gate sabotage tests (zero cloud credentials needed)"
	@echo "  make tf-init             Initialize Terraform in infra/terraform"
	@echo "  make tf-apply            Provision VPC, AR mirrors, UBLA GCS, AlloyDB PG17, GKE 1.37+, Tasks, Pub/Sub & WIF"
	@echo "  make bootstrap-substrate Deploy Agent Substrate v1.0.1 + WorkerPools (microVM & gVisor) on GKE"
	@echo "  make build-images        Build & digest-pin control-plane, verifier, and pi-mono guest images via Cloud Build"
	@echo "  make seed-db             Apply sql/001_swarm_schema.sql and register ActorTemplates"
	@echo "  make run-showcase        Run the 4-slice SwarmRSI campaign (H/P/Rebase/Crossover + Gemma 3 Observer)"
	@echo "  make run-meta-gate       Run Harness2 bundle discovery -> Cold Harbor (--n-samples 1) microVM Docker gate"
	@echo "  make window-close        Suspend active actors (--mode=sync) and scale bare-metal pool to 0 ($0/hr)"
	@echo "  make teardown            Cleanly remove ate-system 500GiB PD first, then terraform destroy"

test-local:
	PYTHONPATH=. python3 -m unittest discover -s tests -v

tf-init:
	cd infra/terraform && terraform init

tf-apply:
	cd infra/terraform && terraform apply

bootstrap-substrate:
	./scripts/01_bootstrap_substrate.sh

build-images:
	./scripts/02_build_and_seed.sh --images-only

seed-db:
	./scripts/02_build_and_seed.sh --db-and-templates

run-showcase:
	./scripts/03_run_showcase.sh

run-meta-gate:
	./meta_loop/run_cold_harbor_gate.sh

window-close:
	./scripts/04_window_and_teardown.sh --close-window

teardown:
	./scripts/04_window_and_teardown.sh --destroy-all
