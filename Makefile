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
        deploy check-token check-kctx \
        k8s-prereqs k8s-install k8s-uninstall k8s-status

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
	@echo "  k8s-prereqs  - apply namespace + cert-manager internal CA to current kubectl context"
	@echo "  k8s-install  - helm install/upgrade openbao to current kubectl context (hetzner)"
	@echo "  k8s-uninstall - helm uninstall openbao (PVCs are kept)"
	@echo "  k8s-status   - show pods, PVCs, and bao status from openbao-0"
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

check-kctx:
	@ctx=$$(kubectl config current-context); \
	if [ "$$ctx" != "hetzner" ]; then \
	  echo "ERROR: kubectl context is '$$ctx', expected 'hetzner'."; \
	  echo "Run: kubectl config use-context hetzner"; \
	  exit 1; \
	fi

# ----- Kubernetes (Helm) install path -----------------------------------------
# Targets operate on the current kubectl context. The spec targets the `hetzner`
# cluster; switch context with `kubectl config use-context hetzner` before use.

K8S_NAMESPACE ?= openbao
HELM_RELEASE  ?= openbao

k8s-prereqs: check-kctx
	kubectl apply -f helm/openbao/manifests/namespace.yaml
	kubectl apply -f helm/openbao/manifests/cert-manager.yaml
	kubectl wait --for=condition=Ready certificate/openbao-ca \
	  -n cert-manager --timeout=120s
	kubectl wait --for=condition=Ready certificate/openbao-server-tls \
	  -n $(K8S_NAMESPACE) --timeout=120s

k8s-install: check-kctx k8s-prereqs
	helm repo add openbao https://openbao.github.io/openbao-helm 2>/dev/null || true
	helm repo update openbao
	helm upgrade --install $(HELM_RELEASE) openbao/openbao \
	  -n $(K8S_NAMESPACE) \
	  -f helm/openbao/values-hetzner.yaml

k8s-uninstall: check-kctx
	helm uninstall $(HELM_RELEASE) -n $(K8S_NAMESPACE)
	@echo
	@echo "PVCs are kept by design. To wipe them:"
	@echo "  kubectl -n $(K8S_NAMESPACE) delete pvc -l app.kubernetes.io/name=openbao"

k8s-status:
	@kubectl -n $(K8S_NAMESPACE) get pods,pvc,svc,ingress
	@echo
	@kubectl -n $(K8S_NAMESPACE) exec $(HELM_RELEASE)-0 -- bao status || true
