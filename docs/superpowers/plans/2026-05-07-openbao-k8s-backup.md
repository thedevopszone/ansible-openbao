# OpenBao K8s Raft-Snapshot Backup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second Ansible playbook + Makefile target that pulls a Raft snapshot from the Helm-deployed OpenBao cluster on Hetzner K8s into `./backups/`, mirroring the existing SSH-based `playbooks/backup-openbao.yml`.

**Architecture:** New `playbooks/backup-openbao-k8s.yml` runs on `localhost`, talks to the cluster via `kubernetes.core.k8s_exec` (snapshot save into a pod tempfile), uses `kubectl cp` for binary-safe transfer, then cleans up the pod tempfile. Token via `VAULT_TOKEN` env, defaults target namespace `openbao` and pod `openbao-0`. The existing SSH playbook and `make backup` target remain untouched.

**Tech Stack:** Ansible 2.x, `kubernetes.core` collection (already at 6.2.0), `kubectl`, `bao` CLI in the OpenBao pod, GNU make.

**Spec:** `docs/superpowers/specs/2026-05-07-openbao-k8s-backup-design.md`

---

## File Structure

| File | Status | Responsibility |
| --- | --- | --- |
| `playbooks/backup-openbao-k8s.yml` | **new** | Whole K8s backup flow: token-assert, snapshot save in pod, `kubectl cp`, pod cleanup, debug |
| `requirements.yml` | modify | Add `kubernetes.core` collection (used by the new playbook) |
| `Makefile` | modify | New target `k8s-backup` + help line |

No changes to `playbooks/backup-openbao.yml`, `inventory/hosts.yml`, or any helm/terraform files.

---

## Task 1: Add `kubernetes.core` to ansible collection requirements

**Files:**
- Modify: `requirements.yml`

`kubernetes.core` is already installed locally (6.2.0), but it's not declared in `requirements.yml`. The new playbook depends on `kubernetes.core.k8s_exec`, so the dependency must be declared so `make deps` installs it on a fresh checkout.

- [ ] **Step 1: Read current `requirements.yml`**

Run: `cat requirements.yml`
Expected:
```yaml
---
collections:
  - name: community.hashi_vault
  - name: community.crypto
```

- [ ] **Step 2: Append `kubernetes.core`**

Edit `requirements.yml` to:

```yaml
---
collections:
  - name: community.hashi_vault
  - name: community.crypto
  - name: kubernetes.core
```

- [ ] **Step 3: Verify the file is valid YAML and the collection is installed**

Run: `python3 -c "import yaml,sys; print(yaml.safe_load(open('requirements.yml')))"`
Expected: `{'collections': [{'name': 'community.hashi_vault'}, {'name': 'community.crypto'}, {'name': 'kubernetes.core'}]}`

Run: `ansible-galaxy collection list | grep kubernetes.core`
Expected: a line like `kubernetes.core    6.2.0` (no install needed; collection already present).

- [ ] **Step 4: Commit**

```bash
git add requirements.yml
git commit -m "chore(ansible): declare kubernetes.core dependency for k8s playbooks"
```

---

## Task 2: Skeleton of `backup-openbao-k8s.yml` (header, vars, pre_tasks)

**Files:**
- Create: `playbooks/backup-openbao-k8s.yml`

Land the playbook with header + vars + pre_tasks (token-assert, timestamp, paths, local backup dir). The actual snapshot tasks come in Task 3 — this step just makes the playbook syntactically valid and verifies the assert path with a missing token.

- [ ] **Step 1: Create the file with skeleton**

Create `playbooks/backup-openbao-k8s.yml` with exactly this content:

```yaml
---
# Take a Raft snapshot of the Helm-deployed OpenBao HA cluster on
# Kubernetes (current `kubectl` context) and pull it to the control node.
# Mirrors `playbooks/backup-openbao.yml` (SSH/VM path) but talks to the
# cluster via `kubernetes.core.k8s_exec` + `kubectl cp` instead of SSH.
#
# Required:
#   VAULT_TOKEN environment variable (or -e openbao_token=...).
#
# Defaults:
#   - namespace = openbao
#   - target pod = openbao-0
#   - local destination = ./backups/ on the control node
#   - retention = keep all snapshots (rotation kept out — wire up your own
#     backup tooling for off-site copies and cleanup)
- name: Backup OpenBao on Kubernetes (Raft snapshot)
  hosts: localhost
  gather_facts: false
  become: false
  vars:
    openbao_token: "{{ lookup('env', 'VAULT_TOKEN') }}"
    openbao_k8s_namespace: openbao
    openbao_k8s_pod: openbao-0
    openbao_k8s_addr: "https://127.0.0.1:8200"
    openbao_k8s_cacert: "/openbao/userconfig/openbao-server-tls/ca.crt"
    openbao_backup_local_dir: "{{ playbook_dir }}/../backups"

  pre_tasks:
    - name: Verify a Vault token is available
      ansible.builtin.assert:
        that:
          - openbao_token | length > 0
        fail_msg: |
          VAULT_TOKEN ist nicht gesetzt. Beispiel:
            export VAULT_TOKEN=<root-or-backup-token>
            ansible-playbook playbooks/backup-openbao-k8s.yml

    - name: Lock in a single timestamp for this run
      ansible.builtin.set_fact:
        _openbao_ts: "{{ lookup('pipe', 'date +%Y%m%dT%H%M%S') }}"

    - name: Compute snapshot paths
      ansible.builtin.set_fact:
        _openbao_remote_path: "/tmp/openbao-{{ openbao_k8s_pod }}-{{ _openbao_ts }}.snap"
        _openbao_local_path: "{{ openbao_backup_local_dir }}/openbao-{{ openbao_k8s_pod }}-{{ _openbao_ts }}.snap"

    - name: Ensure local backup directory exists on the control node
      ansible.builtin.file:
        path: "{{ openbao_backup_local_dir }}"
        state: directory
        mode: "0700"

  tasks: []
```

- [ ] **Step 2: Syntax-check the playbook**

Run: `ansible-playbook --syntax-check playbooks/backup-openbao-k8s.yml`
Expected: `playbook: playbooks/backup-openbao-k8s.yml` and no errors.

- [ ] **Step 3: Run with empty `VAULT_TOKEN` and confirm assert fails with the German message**

Run: `env -u VAULT_TOKEN ansible-playbook playbooks/backup-openbao-k8s.yml`
Expected: play fails on the "Verify a Vault token is available" task with `fail_msg` containing `VAULT_TOKEN ist nicht gesetzt`. Exit code non-zero.

- [ ] **Step 4: Run with a dummy token and confirm pre_tasks pass**

Run: `VAULT_TOKEN=dummy ansible-playbook playbooks/backup-openbao-k8s.yml`
Expected: all four pre_tasks return `ok` / `changed`, then play ends (no `tasks:`). The directory `./backups/` exists with mode `0700`. Exit code 0.

Verify: `ls -ld backups`
Expected: `drwx------` permissions.

- [ ] **Step 5: Commit**

```bash
git add playbooks/backup-openbao-k8s.yml
git commit -m "feat(ansible): scaffold k8s raft-snapshot backup playbook"
```

---

## Task 3: Snapshot pipeline (save in pod → `kubectl cp` → cleanup)

**Files:**
- Modify: `playbooks/backup-openbao-k8s.yml`

Add the three real tasks plus a final debug. Note on env vars: the OpenBao pod already has `VAULT_ADDR` and `VAULT_CACERT` set via `extraEnvironmentVars` in `helm/openbao/values-hetzner.yaml`, but we set them explicitly in the `env`-prefixed command so the playbook is robust against Helm value changes. `kubernetes.core.k8s_exec` does **not** support an `environment:` parameter, so env injection must happen in the command string. `no_log: true` keeps the token out of stdout/log files.

- [ ] **Step 1: Replace `tasks: []` with the snapshot pipeline**

Replace the line `  tasks: []` in `playbooks/backup-openbao-k8s.yml` with:

```yaml
  tasks:
    - name: Take Raft snapshot inside the target pod
      kubernetes.core.k8s_exec:
        namespace: "{{ openbao_k8s_namespace }}"
        pod: "{{ openbao_k8s_pod }}"
        command: >-
          env
          VAULT_ADDR={{ openbao_k8s_addr }}
          VAULT_CACERT={{ openbao_k8s_cacert }}
          VAULT_TOKEN={{ openbao_token }}
          bao operator raft snapshot save {{ _openbao_remote_path }}
      no_log: true

    - name: Copy snapshot from the pod to the control node
      ansible.builtin.command:
        argv:
          - kubectl
          - -n
          - "{{ openbao_k8s_namespace }}"
          - cp
          - "{{ openbao_k8s_pod }}:{{ _openbao_remote_path }}"
          - "{{ _openbao_local_path }}"
      changed_when: true

    - name: Remove snapshot from the pod
      kubernetes.core.k8s_exec:
        namespace: "{{ openbao_k8s_namespace }}"
        pod: "{{ openbao_k8s_pod }}"
        command: "rm -f {{ _openbao_remote_path }}"

    - name: Show local snapshot path
      ansible.builtin.debug:
        msg: "Snapshot gespeichert unter {{ _openbao_local_path }}"
```

- [ ] **Step 2: Syntax-check**

Run: `ansible-playbook --syntax-check playbooks/backup-openbao-k8s.yml`
Expected: no errors.

- [ ] **Step 3: Lint (informational, non-blocking)**

Run: `ansible-lint playbooks/backup-openbao-k8s.yml || true`
Expected: completes; warnings are acceptable. Real end-to-end verification happens in Task 5.

- [ ] **Step 4: Commit**

```bash
git add playbooks/backup-openbao-k8s.yml
git commit -m "feat(ansible): implement k8s raft-snapshot pipeline (save, cp, cleanup)"
```

---

## Task 4: Add `k8s-backup` Makefile target and help entry

**Files:**
- Modify: `Makefile`

Mirror the existing `k8s-*` targets: depend on `check-kctx` (enforces context `hetzner`) and `check-token` (enforces `VAULT_TOKEN`).

- [ ] **Step 1: Locate the `k8s-status` target — the new target goes right after it**

Run: `grep -n "^k8s-status:" Makefile`
Expected: a line number, e.g. `174:k8s-status:`.

- [ ] **Step 2: Append `k8s-backup` after the `k8s-status` block**

Find this block in `Makefile`:

```make
k8s-status:
	@kubectl -n $(K8S_NAMESPACE) get pods,pvc,svc,ingress
	@echo
	@kubectl -n $(K8S_NAMESPACE) exec $(HELM_RELEASE)-0 -- bao status || true
```

Append immediately after it (one blank line separator):

```make

k8s-backup: check-kctx check-token
	ansible-playbook playbooks/backup-openbao-k8s.yml
```

- [ ] **Step 3: Add the help line for `k8s-backup`**

Find this line in the `help:` target:

```make
	@echo "  k8s-status   - show pods, PVCs, and bao status from openbao-0"
```

Append immediately after it:

```make
	@echo "  k8s-backup   - Pull a Raft snapshot from the helm-deployed cluster to ./backups/ (requires VAULT_TOKEN)"
```

- [ ] **Step 4: Add `k8s-backup` to `.PHONY`**

Run: `grep -n "^\.PHONY" Makefile`
Expected: a line listing phony targets, e.g. `.PHONY: ... k8s-prereqs k8s-install k8s-uninstall k8s-status`.

Edit that line to append ` k8s-backup`. Example resulting line:

```make
.PHONY: ... k8s-prereqs k8s-install k8s-uninstall k8s-status k8s-backup
```

(Preserve everything already on the line — only append the new target name.)

- [ ] **Step 5: Verify the help output and that the target is recognized**

Run: `make help | grep k8s-backup`
Expected: `  k8s-backup   - Pull a Raft snapshot from the helm-deployed cluster to ./backups/ (requires VAULT_TOKEN)`

Run: `make -n k8s-backup VAULT_TOKEN=dummy 2>&1 | tail -5`
Expected: dry-run shows the `ansible-playbook playbooks/backup-openbao-k8s.yml` line (and no "No rule to make target" error). The `check-kctx` step runs and may fail unless your current context is `hetzner` — that's expected behavior, not a Makefile bug.

- [ ] **Step 6: Commit**

```bash
git add Makefile
git commit -m "feat(make): add k8s-backup target wrapping the new k8s backup playbook"
```

---

## Task 5: End-to-end verification against the `hetzner` cluster

**Files:** none (verification only)

Real-cluster smoke test. Validates that the playbook + Makefile target together actually produce a usable Raft snapshot.

**Pre-requisites (hard fails, not bugs):**
- `kubectl current-context` is `hetzner`.
- All three pods (`openbao-0..2`) are `Ready` and unsealed (otherwise the snapshot call returns "Vault is sealed" or the cluster has no leader). If only `openbao-0` is unsealed and the other two are sealed, **switch the target pod to the unsealed one and pass it explicitly** (see Step 2 below).
- `VAULT_TOKEN` is exported and has snapshot capability (root token works).

- [ ] **Step 1: Verify cluster precondition**

Run: `kubectl -n openbao get pods`
Expected: `openbao-0`, `openbao-1`, `openbao-2` all `1/1 Running`.

Run: `kubectl -n openbao exec openbao-0 -- bao status | grep -E "Sealed|HA Mode|Active"`
Expected: `Sealed false`, `HA Mode active` or `standby` with a non-empty `Active Node Address`.

If any pod is `0/1` or sealed, fix that first (`bao operator unseal`) before continuing — this task does not implement seal handling.

- [ ] **Step 2: Run the backup**

Run: `make k8s-backup`
Expected: play runs through pre_tasks + 4 tasks. `PLAY RECAP` shows `ok=8 changed=4` (or similar non-zero) and `failed=0`. Final `debug` task prints `Snapshot gespeichert unter <repo>/backups/openbao-openbao-0-<ts>.snap`.

If `openbao-0` is sealed but `openbao-1` is healthy, instead run:
`ansible-playbook playbooks/backup-openbao-k8s.yml -e openbao_k8s_pod=openbao-1`

- [ ] **Step 3: Verify the local snapshot file**

Run: `ls -lh backups/ | tail -3`
Expected: a new `openbao-openbao-0-<ts>.snap` file, size > 0 bytes (typically tens of KB to several MB).

Run: `file backups/openbao-openbao-0-*.snap | tail -1`
Expected: detected as `gzip compressed data` (Raft snapshots are gzipped tar archives).

- [ ] **Step 4: Validate the snapshot content with `bao` itself**

Copy the snapshot back into the pod and inspect it (the `bao` CLI on the control node may not match the server version):

```bash
SNAP=$(ls -t backups/openbao-openbao-0-*.snap | head -1)
kubectl -n openbao cp "$SNAP" openbao-0:/tmp/verify.snap
kubectl -n openbao exec openbao-0 -- bao operator raft snapshot inspect /tmp/verify.snap
kubectl -n openbao exec openbao-0 -- rm -f /tmp/verify.snap
```

Expected: `bao operator raft snapshot inspect` prints metadata (Version, Term, Index, Size). No "corrupt" / "invalid" errors.

- [ ] **Step 5: Verify pod tempfile cleanup**

Run: `kubectl -n openbao exec openbao-0 -- ls /tmp/ | grep -i openbao || echo "clean"`
Expected: `clean` (or no openbao-* file in `/tmp/` of the pod).

- [ ] **Step 6: No commit**

Verification only. The implementation commits already exist from Tasks 1–4.
