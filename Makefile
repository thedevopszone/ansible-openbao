SHELL := /bin/bash

VAULT_ADDR ?= https://172.16.0.107:8200
TF_DIR     := terraform

.PHONY: help deps install ping tf-init tf-plan tf-apply tf-destroy tf-fmt tf-validate deploy check-token

help:
	@echo "Targets:"
	@echo "  deps         - Install ansible collections (requirements.yml) and python deps (requirements.txt) into .venv"
	@echo "  install      - Install OpenBao on managed hosts (ansible)"
	@echo "  ping         - Ping ansible hosts"
	@echo "  tf-init      - terraform init"
	@echo "  tf-fmt       - terraform fmt -recursive"
	@echo "  tf-validate  - terraform validate"
	@echo "  tf-plan      - terraform plan (requires VAULT_TOKEN)"
	@echo "  tf-apply     - terraform apply (requires VAULT_TOKEN)"
	@echo "  tf-destroy   - terraform destroy (requires VAULT_TOKEN)"
	@echo "  deploy       - install + tf-init + tf-apply"
	@echo ""
	@echo "Env:"
	@echo "  VAULT_ADDR   = $(VAULT_ADDR)"
	@echo "  VAULT_TOKEN  must be exported for terraform targets"

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

ping:
	ansible openbao_servers -m ping

tf-init:
	cd $(TF_DIR) && terraform init

tf-fmt:
	cd $(TF_DIR) && terraform fmt -recursive

tf-validate:
	cd $(TF_DIR) && terraform validate

tf-plan: check-token
	cd $(TF_DIR) && VAULT_ADDR=$(VAULT_ADDR) terraform plan

tf-apply: check-token
	cd $(TF_DIR) && VAULT_ADDR=$(VAULT_ADDR) terraform apply

tf-destroy: check-token
	cd $(TF_DIR) && VAULT_ADDR=$(VAULT_ADDR) terraform destroy

deploy: install tf-init tf-apply

check-token:
	@if [ -z "$$VAULT_TOKEN" ]; then \
		echo "ERROR: VAULT_TOKEN ist nicht gesetzt."; \
		echo "Beispiel: export VAULT_TOKEN=<root-token>"; \
		exit 1; \
	fi
