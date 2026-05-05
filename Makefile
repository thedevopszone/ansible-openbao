SHELL := /bin/bash

# CLUSTER selects which OpenBao instance Terraform talks to.
#   single (default) → 172.16.0.107 (single-node), workspace `default`,
#                      var-file terraform.tfvars, skip_tls_verify=true.
#   ha               → 172.16.0.143 (HA cluster), workspace `ha`,
#                      var-file ha.tfvars, VAULT_CACERT=./.openbao-ca/ca.crt.
CLUSTER ?= single

TF_DIR := terraform
REPO_ROOT := $(abspath .)

ifeq ($(CLUSTER),ha)
  TF_WORKSPACE  := ha
  TF_VAR_FILE   := ha.tfvars
  TF_ENV        := VAULT_CACERT=$(REPO_ROOT)/.openbao-ca/ca.crt
  CLUSTER_LABEL := HA cluster (172.16.0.143/120/69, workspace=ha)
else ifeq ($(CLUSTER),single)
  TF_WORKSPACE  := default
  TF_VAR_FILE   := terraform.tfvars
  TF_ENV        :=
  CLUSTER_LABEL := single-node (172.16.0.107, workspace=default)
else
  $(error unsupported CLUSTER='$(CLUSTER)' — use 'single' or 'ha')
endif

.PHONY: help deps install install-ha backup ping \
        tf-init tf-fmt tf-validate tf-workspace tf-plan tf-apply tf-destroy \
        deploy check-token

help:
	@echo "Targets:"
	@echo "  deps         - Install ansible collections (requirements.yml) and python deps (requirements.txt) into .venv"
	@echo "  install      - Install OpenBao on managed hosts (ansible)"
	@echo "  install-ha   - Install OpenBao 3-node HA cluster (raft, group: openbao_ha_servers)"
	@echo "  backup       - Pull a Raft snapshot from the cluster to ./backups/ (requires VAULT_TOKEN)"
	@echo "  ping         - Ping ansible hosts"
	@echo "  tf-init      - terraform init"
	@echo "  tf-fmt       - terraform fmt -recursive"
	@echo "  tf-validate  - terraform validate"
	@echo "  tf-plan      - terraform plan (CLUSTER=single|ha, requires VAULT_TOKEN)"
	@echo "  tf-apply     - terraform apply (CLUSTER=single|ha, requires VAULT_TOKEN)"
	@echo "  tf-destroy   - terraform destroy (CLUSTER=single|ha, requires VAULT_TOKEN)"
	@echo "  deploy       - install + tf-init + tf-apply (single-node)"
	@echo ""
	@echo "Env:"
	@echo "  CLUSTER      = $(CLUSTER)   →  $(CLUSTER_LABEL)"
	@echo "  VAULT_TOKEN  must be exported for terraform targets"
	@echo ""
	@echo "Examples:"
	@echo "  make tf-plan                  # single-node (default)"
	@echo "  make tf-apply CLUSTER=ha      # HA cluster"

PYTHON ?= python3
VENV   := .venv
VENV_PIP := $(VENV)/bin/pip

$(VENV):
	$(PYTHON) -m venv $(VENV)
	$(VENV_PIP) install --upgrade pip

deps: $(VENV)
	ansible-galaxy collection install -r requirements.yml
	$(VENV_PIP) install -r requirements.txt

install:
	ansible-playbook playbooks/install-openbao.yml

install-ha:
	ansible-playbook playbooks/install-openbao-ha.yml

backup: check-token
	ansible-playbook playbooks/backup-openbao.yml

ping:
	ansible openbao_servers -m ping

tf-init:
	cd $(TF_DIR) && terraform init

tf-fmt:
	cd $(TF_DIR) && terraform fmt -recursive

tf-validate:
	cd $(TF_DIR) && terraform validate

tf-workspace:
	cd $(TF_DIR) && terraform workspace select -or-create $(TF_WORKSPACE)

tf-plan: check-token tf-workspace
	cd $(TF_DIR) && $(TF_ENV) terraform plan -var-file=$(TF_VAR_FILE)

tf-apply: check-token tf-workspace
	cd $(TF_DIR) && $(TF_ENV) terraform apply -var-file=$(TF_VAR_FILE)

tf-destroy: check-token tf-workspace
	cd $(TF_DIR) && $(TF_ENV) terraform destroy -var-file=$(TF_VAR_FILE)

deploy: install tf-init tf-apply

check-token:
	@if [ -z "$$VAULT_TOKEN" ]; then \
		echo "ERROR: VAULT_TOKEN ist nicht gesetzt."; \
		echo "Beispiel: export VAULT_TOKEN=<root-token>"; \
		exit 1; \
	fi
