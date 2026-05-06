# OpenBao Helm Hetzner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second OpenBao installation path that deploys a 3-replica Raft HA cluster onto the `hetzner` Kubernetes cluster via the official OpenBao Helm chart, with cert-manager-issued internal TLS, ingress-nginx + Let's Encrypt for external access, and manual Shamir unseal.

**Architecture:** Helm-based install of `openbao/openbao` chart in HA Raft mode. Internal TLS provided by a self-signed CA bootstrapped via cert-manager (selfsigned ClusterIssuer → CA Certificate → CA ClusterIssuer → server Certificate). External access via ingress-nginx with `letsencrypt-production` ClusterIssuer. All cluster-side YAML lives under `helm/openbao/`, automation in Makefile (`k8s-*` targets), zero changes to existing Ansible/VM/Terraform paths.

**Tech Stack:** Kubernetes (RKE2 v1.29), Helm 3, OpenBao Helm chart (`openbao/openbao`), cert-manager, ingress-nginx, Longhorn StorageClass.

**Reference spec:** [`docs/superpowers/specs/2026-05-06-openbao-helm-hetzner-design.md`](../specs/2026-05-06-openbao-helm-hetzner-design.md)

**Note on TDD:** This is infrastructure, not application code. The "test → fail → implement → pass" loop adapts to:
- Manifest validation: `kubectl apply --dry-run=server -f <file>` before real apply
- Helm rendering: `helm template ... | kubectl apply --dry-run=server -f -` before real install
- Cluster state checks: `kubectl wait --for=condition=...` and `bao status` as success gates

Each task ends with verification of expected cluster state, not unit tests.

---

## File Structure

| Path | Status | Responsibility |
| --- | --- | --- |
| `helm/openbao/values-hetzner.yaml` | create | Helm values overlay for the openbao chart (HA, TLS, ingress, resources, audit) |
| `helm/openbao/manifests/namespace.yaml` | create | Namespace `openbao` |
| `helm/openbao/manifests/cert-manager.yaml` | create | selfsigned-bootstrap ClusterIssuer + `openbao-ca` Certificate + `openbao-ca-issuer` ClusterIssuer + `openbao-server-tls` Certificate |
| `helm/openbao/README.md` | create | Install/init/unseal walkthrough |
| `Makefile` | modify | Add `k8s-prereqs`, `k8s-install`, `k8s-uninstall`, `k8s-status` targets and help entries |
| `README.md` (root) | modify | Brief mention of new K8s install path with link to `helm/openbao/README.md` |

No existing files are touched besides `Makefile` and root `README.md`. The Ansible roles, playbooks, Terraform code, and existing demo helm charts under `tests/helm/` stay untouched.

---

## Pre-flight (one-time, not committed)

- [ ] **Step P1: Confirm kubectl context is `hetzner`**

```bash
kubectl config current-context
```

Expected output:
```
hetzner
```

If different: `kubectl config use-context hetzner`.

- [ ] **Step P2: Confirm cluster prereqs are present**

```bash
kubectl get clusterissuer letsencrypt-production
kubectl get ingressclass nginx
kubectl get sc longhorn
```

Expected: all three exist; the `letsencrypt-production` ClusterIssuer's `READY` column shows `True`. If any missing, stop — the spec assumes these.

- [ ] **Step P3: Add the OpenBao helm repo locally**

```bash
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo update openbao
helm search repo openbao/openbao
```

Expected: row showing `openbao/openbao` with a chart version.

- [ ] **Step P4: Inspect chart's default values to confirm key names this plan uses**

This is a sanity gate — chart value paths can drift between forks. We rely on these keys: `server.ha.enabled`, `server.ha.raft.enabled`, `server.ha.raft.config`, `server.dataStorage`, `server.auditStorage`, `server.volumes`, `server.volumeMounts`, `server.extraEnvironmentVars`, `server.resources`, `server.affinity`, `server.ingress`, `injector.enabled`.

```bash
helm show values openbao/openbao | grep -E '^[a-z]|^  (ha|raft|dataStorage|auditStorage|volumes|volumeMounts|extraEnvironmentVars|resources|affinity|ingress|enabled):' | head -80
```

Expected: those keys are present in the chart values. If a key is named differently (e.g., `server.dataStorage` vs `server.persistence`), pause and adjust `values-hetzner.yaml` accordingly in Task 4.

---

## Task 1: Namespace manifest

**Files:**
- Create: `helm/openbao/manifests/namespace.yaml`

- [ ] **Step 1.1: Write the namespace manifest**

`helm/openbao/manifests/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openbao
  labels:
    app.kubernetes.io/name: openbao
    app.kubernetes.io/managed-by: helm
```

- [ ] **Step 1.2: Validate it server-side (dry-run)**

```bash
kubectl apply --dry-run=server -f helm/openbao/manifests/namespace.yaml
```

Expected output (line-shape):
```
namespace/openbao created (server dry run)
```

Failure modes: connection error → wrong context, fix `kubectl config use-context hetzner`.

- [ ] **Step 1.3: Apply for real**

```bash
kubectl apply -f helm/openbao/manifests/namespace.yaml
```

Expected:
```
namespace/openbao created
```

- [ ] **Step 1.4: Confirm it exists**

```bash
kubectl get ns openbao
```

Expected: `Active` status.

---

## Task 2: cert-manager internal CA + server Certificate manifest

**Files:**
- Create: `helm/openbao/manifests/cert-manager.yaml`

This single file holds four resources in dependency order:

1. `selfsigned-bootstrap` ClusterIssuer (no inputs)
2. `openbao-ca` Certificate in `cert-manager` namespace (signed by 1, isCA=true)
3. `openbao-ca-issuer` ClusterIssuer (uses Secret produced by 2)
4. `openbao-server-tls` Certificate in `openbao` namespace (signed by 3)

- [ ] **Step 2.1: Write the manifest**

`helm/openbao/manifests/cert-manager.yaml`:

```yaml
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openbao-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: openbao-ca
  secretName: openbao-ca
  duration: 87600h     # 10 years
  renewBefore: 720h    # 30 days
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: openbao-ca-issuer
spec:
  ca:
    secretName: openbao-ca
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openbao-server-tls
  namespace: openbao
spec:
  secretName: openbao-server-tls
  duration: 2160h      # 90 days
  renewBefore: 720h    # 30 days
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  commonName: openbao
  dnsNames:
    - openbao
    - openbao.openbao
    - openbao.openbao.svc
    - openbao.openbao.svc.cluster.local
    - openbao-internal
    - openbao-internal.openbao
    - openbao-internal.openbao.svc
    - openbao-internal.openbao.svc.cluster.local
    - openbao-0.openbao-internal
    - openbao-1.openbao-internal
    - openbao-2.openbao-internal
    - openbao-0.openbao-internal.openbao.svc.cluster.local
    - openbao-1.openbao-internal.openbao.svc.cluster.local
    - openbao-2.openbao-internal.openbao.svc.cluster.local
    - openbao.securek8s.de
    - localhost
  ipAddresses:
    - 127.0.0.1
  issuerRef:
    name: openbao-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
```

- [ ] **Step 2.2: Validate server-side (requires Task 1 applied + cert-manager CRDs available)**

```bash
kubectl apply --dry-run=server -f helm/openbao/manifests/cert-manager.yaml
```

Expected: 4 lines, each ending in `(server dry run)`. If you see "no matches for kind Certificate" → cert-manager CRDs missing, wrong cluster.

- [ ] **Step 2.3: Apply for real**

```bash
kubectl apply -f helm/openbao/manifests/cert-manager.yaml
```

Expected: 4 resources created.

- [ ] **Step 2.4: Wait for the CA Certificate to become Ready**

```bash
kubectl wait --for=condition=Ready certificate/openbao-ca \
  -n cert-manager --timeout=120s
```

Expected:
```
certificate.cert-manager.io/openbao-ca condition met
```

- [ ] **Step 2.5: Wait for the server Certificate to become Ready**

```bash
kubectl wait --for=condition=Ready certificate/openbao-server-tls \
  -n openbao --timeout=120s
```

Expected:
```
certificate.cert-manager.io/openbao-server-tls condition met
```

- [ ] **Step 2.6: Confirm the resulting Secret has the three expected keys**

```bash
kubectl get secret openbao-server-tls -n openbao \
  -o jsonpath='{.data}' | jq 'keys'
```

Expected:
```json
[
  "ca.crt",
  "tls.crt",
  "tls.key"
]
```

If `jq` not available: substitute `python3 -c "import sys, json; print(sorted(json.load(sys.stdin).keys()))"`.

- [ ] **Step 2.7: Commit Task 1 + Task 2 manifests**

```bash
git add helm/openbao/manifests/namespace.yaml helm/openbao/manifests/cert-manager.yaml
git commit -m "feat(k8s): add openbao namespace and cert-manager internal CA manifests"
```

---

## Task 3: Helm values overlay (`values-hetzner.yaml`)

**Files:**
- Create: `helm/openbao/values-hetzner.yaml`

This is the heart of the deployment. Values are written to match the chart key conventions confirmed in step P4. If any key from P4 differs (e.g., `server.persistence` instead of `server.dataStorage`), adjust this file before Task 4 dry-runs.

- [ ] **Step 3.1: Write the values file**

`helm/openbao/values-hetzner.yaml`:

```yaml
# OpenBao Helm values for the `hetzner` Kubernetes cluster.
# Spec: docs/superpowers/specs/2026-05-06-openbao-helm-hetzner-design.md

global:
  enabled: true
  tlsDisable: false

injector:
  enabled: false

server:
  enabled: true

  # bao CLI inside the pod talks to the local listener via HTTPS — point it at
  # the ca.crt from the mounted Secret so `bao status` / `bao operator init`
  # don't need VAULT_SKIP_VERIFY.
  extraEnvironmentVars:
    VAULT_ADDR: "https://127.0.0.1:8200"
    VAULT_CACERT: "/openbao/userconfig/openbao-server-tls/ca.crt"

  # Mount the cert-manager-issued Secret produced in Task 2.
  volumes:
    - name: openbao-server-tls
      secret:
        secretName: openbao-server-tls
        defaultMode: 0400
  volumeMounts:
    - name: openbao-server-tls
      mountPath: /openbao/userconfig/openbao-server-tls
      readOnly: true

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

  # Soft anti-affinity: pods prefer different worker nodes, but co-locate if
  # they must. The cluster has only 2 workers; required anti-affinity would
  # leave the 3rd replica unschedulable.
  affinity: |
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchLabels:
                app.kubernetes.io/name: {{ template "vault.name" . }}
                app.kubernetes.io/instance: "{{ .Release.Name }}"
                component: server
            topologyKey: kubernetes.io/hostname

  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true
      config: |
        ui = true

        listener "tcp" {
          tls_disable        = 0
          address            = "[::]:8200"
          cluster_address    = "[::]:8201"
          tls_cert_file      = "/openbao/userconfig/openbao-server-tls/tls.crt"
          tls_key_file       = "/openbao/userconfig/openbao-server-tls/tls.key"
          tls_client_ca_file = "/openbao/userconfig/openbao-server-tls/ca.crt"
        }

        storage "raft" {
          path = "/openbao/data"
        }

        service_registration "kubernetes" {}

        audit "file" {
          file_path = "/openbao/audit/audit.log"
        }

  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: longhorn
    accessMode: ReadWriteOnce
    mountPath: /openbao/data

  auditStorage:
    enabled: true
    size: 1Gi
    storageClass: longhorn
    accessMode: ReadWriteOnce
    mountPath: /openbao/audit

  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-production
      nginx.ingress.kubernetes.io/backend-protocol: HTTPS
      nginx.ingress.kubernetes.io/proxy-ssl-verify: "off"
    hosts:
      - host: openbao.securek8s.de
        paths: []
    tls:
      - hosts:
          - openbao.securek8s.de
        secretName: openbao-ingress-tls

  service:
    enabled: true
    # ClusterIP — external traffic enters via the Ingress.
    type: ClusterIP

ui:
  enabled: true
  serviceType: ClusterIP
```

- [ ] **Step 3.2: Render the chart with these values (Helm-side validation)**

```bash
helm template openbao openbao/openbao \
  -n openbao \
  -f helm/openbao/values-hetzner.yaml \
  > /tmp/openbao-rendered.yaml
echo "exit=$?"
wc -l /tmp/openbao-rendered.yaml
```

Expected: `exit=0`, line count well above 100. A non-zero exit means a values key the chart doesn't recognize, or a templating error. Read the error and fix the values file before proceeding.

- [ ] **Step 3.3: Pipe rendered output through server-side validation**

```bash
kubectl apply --dry-run=server -f /tmp/openbao-rendered.yaml
```

Expected: a list of resources (StatefulSet, Service `openbao`, Service `openbao-internal`, Service `openbao-ui`, Ingress, ServiceAccount, ConfigMap, etc.), each ending `(server dry run)`. Errors here mean the rendered manifest is invalid for this cluster — read carefully, common causes:

- Unknown CRD → wrong cluster, no cert-manager / ingress-nginx
- Immutable field conflict → the release was already installed, rerun on fresh cluster or use `helm upgrade`

- [ ] **Step 3.4: Commit the values file**

```bash
git add helm/openbao/values-hetzner.yaml
git commit -m "feat(k8s): add openbao Helm values for hetzner cluster"
```

---

## Task 4: Makefile targets

**Files:**
- Modify: `Makefile`

- [ ] **Step 4.1: Append the help line entries inside the `help:` target**

Locate the line in `Makefile`:

```
	@echo "  deploy       - install + tf-init + tf-apply (single-node)"
```

Insert immediately **after** it:

```
	@echo "  k8s-prereqs  - apply namespace + cert-manager internal CA to current kubectl context"
	@echo "  k8s-install  - helm install/upgrade openbao to current kubectl context (hetzner)"
	@echo "  k8s-uninstall- helm uninstall openbao (PVCs are kept)"
	@echo "  k8s-status   - show pods, PVCs, and bao status from openbao-0"
```

- [ ] **Step 4.2: Add the four targets to the `.PHONY` line**

Find:

```
.PHONY: help deps install install-ha backup ping \
        tf-init tf-fmt tf-validate tf-workspace tf-plan tf-apply tf-destroy \
        deploy check-token
```

Replace with:

```
.PHONY: help deps install install-ha backup ping \
        tf-init tf-fmt tf-validate tf-workspace tf-plan tf-apply tf-destroy \
        deploy check-token \
        k8s-prereqs k8s-install k8s-uninstall k8s-status
```

- [ ] **Step 4.3: Append the target bodies at the end of the file**

Append at the end of `Makefile`:

```make

# ----- Kubernetes (Helm) install path -----------------------------------------
# Targets operate on the current kubectl context. The spec targets the `hetzner`
# cluster; switch context with `kubectl config use-context hetzner` before use.

K8S_NAMESPACE ?= openbao
HELM_RELEASE  ?= openbao

k8s-prereqs:
	kubectl apply -f helm/openbao/manifests/namespace.yaml
	kubectl apply -f helm/openbao/manifests/cert-manager.yaml
	kubectl wait --for=condition=Ready certificate/openbao-ca \
	  -n cert-manager --timeout=120s
	kubectl wait --for=condition=Ready certificate/openbao-server-tls \
	  -n $(K8S_NAMESPACE) --timeout=120s

k8s-install: k8s-prereqs
	helm repo add openbao https://openbao.github.io/openbao-helm 2>/dev/null || true
	helm repo update openbao
	helm upgrade --install $(HELM_RELEASE) openbao/openbao \
	  -n $(K8S_NAMESPACE) \
	  -f helm/openbao/values-hetzner.yaml

k8s-uninstall:
	helm uninstall $(HELM_RELEASE) -n $(K8S_NAMESPACE)
	@echo
	@echo "PVCs are kept by design. To wipe them:"
	@echo "  kubectl -n $(K8S_NAMESPACE) delete pvc -l app.kubernetes.io/name=openbao"

k8s-status:
	@kubectl -n $(K8S_NAMESPACE) get pods,pvc,svc,ingress
	@echo
	@kubectl -n $(K8S_NAMESPACE) exec $(HELM_RELEASE)-0 -- bao status || true
```

- [ ] **Step 4.4: Verify Make can parse the new targets**

```bash
make help | grep -E '^  k8s-'
```

Expected: 4 lines listing the new targets.

- [ ] **Step 4.5: Verify a target prints (without running it for real)**

```bash
make -n k8s-prereqs
```

Expected: prints the three `kubectl apply ...` and `kubectl wait ...` commands without executing them.

- [ ] **Step 4.6: Commit the Makefile change**

```bash
git add Makefile
git commit -m "feat(k8s): add Makefile targets for Helm-based OpenBao install"
```

---

## Task 5: README under `helm/openbao/`

**Files:**
- Create: `helm/openbao/README.md`

- [ ] **Step 5.1: Write the README**

`helm/openbao/README.md`:

````markdown
# OpenBao auf Kubernetes (Helm)

Zweiter Installations-Pfad für OpenBao — als 3-Replica-Raft-Cluster im
Kubernetes-Cluster `hetzner`. Der bestehende Ansible/VM-Pfad
([`playbooks/install-openbao-ha.yml`](../../playbooks/install-openbao-ha.yml))
bleibt unverändert.

Spec: [`docs/superpowers/specs/2026-05-06-openbao-helm-hetzner-design.md`](../../docs/superpowers/specs/2026-05-06-openbao-helm-hetzner-design.md).

## Cluster-Voraussetzungen

| Komponente | Erwartet |
| --- | --- |
| kubectl-Context | `hetzner` |
| Storage | StorageClass `longhorn` (oder als Default markiert) |
| Ingress | IngressClass `nginx` |
| Cert-Manager | installiert; ClusterIssuer `letsencrypt-production` Ready |
| DNS | `openbao.securek8s.de` zeigt auf einen Worker-Node |

## Layout

```
helm/openbao/
├── values-hetzner.yaml         # Chart-Values-Overlay (HA, TLS, Ingress, Resources, Audit)
├── manifests/
│   ├── namespace.yaml          # Namespace `openbao`
│   └── cert-manager.yaml       # selfsigned-bootstrap → openbao-ca → ca-issuer → server-tls
└── README.md
```

## Ablauf — von Null bis ready

```bash
# 1. richtigen Cluster ansprechen
kubectl config use-context hetzner

# 2. Namespace + interne CA + Server-Cert anlegen, dann Helm-Install
make k8s-install

# 3. openbao-0 initialisieren — gibt 5 Unseal-Keys + Initial-Root-Token aus.
#    Die Ausgabe IST das einzige Mal, dass du diese Werte sehen wirst.
#    Sicher und getrennt verwahren.
kubectl -n openbao exec -it openbao-0 -- bao operator init

# 4. openbao-0 entsiegeln (3 von 5 Keys reichen)
kubectl -n openbao exec -it openbao-0 -- bao operator unseal <key 1>
kubectl -n openbao exec -it openbao-0 -- bao operator unseal <key 2>
kubectl -n openbao exec -it openbao-0 -- bao operator unseal <key 3>

# 5. openbao-1 + openbao-2 entsiegeln. Sie joinen automatisch via
#    retry_join (chart-default), brauchen aber selbe Unseal-Keys.
for pod in openbao-1 openbao-2; do
  for k in <key 1> <key 2> <key 3>; do
    kubectl -n openbao exec -it $pod -- bao operator unseal "$k"
  done
done

# 6. Cluster-Status prüfen — erwartet: 3 peers, 1 leader, alle voter
kubectl -n openbao exec openbao-0 -- bao operator raft list-peers

# 7. UI: https://openbao.securek8s.de/ui (Login mit Initial-Root-Token)
```

## Make-Targets

| Target | Was es tut |
| --- | --- |
| `make k8s-prereqs` | Namespace + cert-manager Issuers/Cert anlegen, auf Cert-Ready warten |
| `make k8s-install` | `k8s-prereqs` + `helm upgrade --install` (idempotent) |
| `make k8s-uninstall` | `helm uninstall` — PVCs bleiben absichtlich erhalten |
| `make k8s-status` | Pods/PVCs/Services/Ingress + `bao status` von `openbao-0` |

## TLS-Setup im Detail

Zwei separate Trust-Domains:

- **Cluster-intern (Pod ↔ Pod, listener auf 8200, raft cluster auf 8201):**
  cert-manager mit eigener self-signed CA. `selfsigned-bootstrap` ClusterIssuer
  signiert die `openbao-ca`-Certificate (isCA), die wiederum als ClusterIssuer
  `openbao-ca-issuer` zum Ausstellen des Server-Certs `openbao-server-tls` dient.
  Alle 3 Pods mounten dasselbe Secret und trusten dieselbe CA.

- **Extern (Ingress, public):** Let's Encrypt Production via
  `letsencrypt-production` ClusterIssuer. ingress-nginx terminiert TLS public
  und proxied via HTTPS-zu-HTTPS in den Cluster (Backend-Cert ist self-signed,
  daher `proxy-ssl-verify: off` — der Verkehr ist trotzdem end-to-end
  TLS-verschlüsselt).

## Cluster-interne Clients (z.B. ESO im selben Cluster)

Wenn ein cluster-interner Client OpenBao über den internen Service-DNS
ansprechen will (`https://openbao.openbao.svc:8200`), braucht er die `ca.crt`
aus dem `openbao-server-tls`-Secret oder das CA-Secret `openbao-ca` aus dem
`cert-manager`-Namespace als `caBundle`.

Beispiel — CA-Bundle ins Ziel-Namespace kopieren:

```bash
kubectl get secret openbao-ca -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/openbao-ca.crt
```

## Restart / Reseal

Nach jedem Pod-Restart ist der jeweilige Pod wieder `sealed`. Manuelle
Entsiegelung mit denselben Unseal-Keys:

```bash
kubectl -n openbao exec -it openbao-0 -- bao operator unseal <key>   # 3×
```

## Backup

`bao operator raft snapshot` aus dem Leader-Pod:

```bash
kubectl -n openbao exec openbao-0 -- \
  bao operator raft snapshot save - > snapshot-$(date +%Y%m%dT%H%M%S).snap
```

Snapshot-Files enthalten alle verschlüsselten Secrets — `chmod 0600`,
nicht committen.

## Wann diesen Pfad statt VM-HA?

- **VM-HA** (`make install-ha`) bleibt der primäre, persistente Vault.
- **K8s-Helm** (`make k8s-install`) ist gedacht für: cluster-interne Workloads,
  die ein OpenBao im selben Cluster bevorzugen, Tests, Eval.
- Bei **Quorum-Verlust** im K8s-Cluster (z.B. beide Worker rebooten und ein
  Pod ist sealed): der VM-HA bleibt als unabhängiger Vault unbeeinträchtigt.
````

- [ ] **Step 5.2: Commit the README**

```bash
git add helm/openbao/README.md
git commit -m "docs(k8s): add helm/openbao README with install and unseal walkthrough"
```

---

## Task 6: Reference the new path from the root README

**Files:**
- Modify: `README.md` (root)

- [ ] **Step 6.1: Add a short pointer near the existing "Verwendung" section**

In the root `README.md`, find this exact line (around line 83 — it's the closing fence of the make-targets block, *before* the `Direkter Aufruf ohne Makefile:` paragraph):

```
make deploy        # install + tf-init + tf-apply in einem Rutsch (single-node)
```

The line **after** it is a closing ` ``` `. Insert the new content immediately after that closing fence so it sits between the make-targets block and the `Direkter Aufruf` paragraph.

Use the Edit tool with this exact `old_string` / `new_string`:

`old_string`:

````
make deploy        # install + tf-init + tf-apply in einem Rutsch (single-node)
```

Direkter Aufruf ohne Makefile:
````

`new_string`:

````
make deploy        # install + tf-init + tf-apply in einem Rutsch (single-node)
```

Zusätzlich zum Ansible/VM-Pfad gibt es einen **Helm-Install auf Kubernetes**
für einen 3-Replica-Raft-Cluster (siehe [`helm/openbao/README.md`](helm/openbao/README.md)):

```bash
kubectl config use-context hetzner
make k8s-install      # Namespace + interne CA + Helm-Install
make k8s-status       # Pods/PVCs/Ingress + bao status
```

Init und Unseal sind manuell, wie beim VM-HA.

Direkter Aufruf ohne Makefile:
````

- [ ] **Step 6.2: Verify the file still renders cleanly**

```bash
grep -n "k8s-install" README.md
```

Expected: at least one match in a sensible location (under "Verwendung").

- [ ] **Step 6.3: Commit**

```bash
git add README.md
git commit -m "docs: link helm-based k8s install path from root README"
```

---

## Task 7: Real cluster install (executes against `hetzner`)

This task touches the live `hetzner` cluster. It is part of the plan because
the user's intent is to actually deploy. If executing this plan via subagents,
this task should be reviewed by the user before dispatch.

**No file changes** — only cluster operations.

- [ ] **Step 7.1: Confirm context one more time**

```bash
kubectl config current-context
```

Expected: `hetzner`. If not, stop.

- [ ] **Step 7.2: Run the install**

```bash
make k8s-install
```

Expected: `helm upgrade --install` succeeds, output ends with something like:
```
Release "openbao" has been installed. Happy Helming!
NAME: openbao
NAMESPACE: openbao
STATUS: deployed
```

- [ ] **Step 7.3: Wait for all 3 StatefulSet pods to reach `Running` (sealed)**

```bash
kubectl -n openbao rollout status statefulset/openbao --timeout=180s || true
kubectl -n openbao get pods -l app.kubernetes.io/name=openbao
```

Expected: 3 pods named `openbao-0`, `openbao-1`, `openbao-2`, each with
`READY 0/1` and `STATUS Running`. The `0/1` is correct: pods are sealed and
fail their readiness probe until unsealed. The pods themselves are healthy.

If pods are `Pending`: `kubectl -n openbao describe pod openbao-0` — likely
PVC binding issue or anti-affinity constraint.

- [ ] **Step 7.4: Initialize `openbao-0`**

> **Critical:** the output of this command shows 5 unseal keys and 1 root
> token, **once**. Capture them into a password manager / offline storage
> *before* doing anything else.

```bash
kubectl -n openbao exec -it openbao-0 -- bao operator init
```

Expected output: 5 lines `Unseal Key 1: ...` through `Unseal Key 5: ...`
and one `Initial Root Token: ...`.

- [ ] **Step 7.5: Unseal `openbao-0` (3 different keys)**

```bash
kubectl -n openbao exec -it openbao-0 -- bao operator unseal <key 1>
kubectl -n openbao exec -it openbao-0 -- bao operator unseal <key 2>
kubectl -n openbao exec -it openbao-0 -- bao operator unseal <key 3>
```

After the third call, expected:
```
Sealed          false
HA Enabled      true
HA Mode         active
```

- [ ] **Step 7.6: Unseal `openbao-1` and `openbao-2`**

They auto-join via `retry_join` once the chart's post-install hooks (or just
the StatefulSet bringup) reach them. Same 3 keys:

```bash
for pod in openbao-1 openbao-2; do
  for k in "<key 1>" "<key 2>" "<key 3>"; do
    kubectl -n openbao exec -it "$pod" -- bao operator unseal "$k"
  done
done
```

- [ ] **Step 7.7: Confirm Raft cluster health**

```bash
kubectl -n openbao exec openbao-0 -- bao operator raft list-peers
```

Expected: 3 rows, one Leader, two Followers, all `voter`. Example:
```
Node             Address                        State       Voter
openbao-0        openbao-0.openbao-internal:8201 leader      true
openbao-1        openbao-1.openbao-internal:8201 follower    true
openbao-2        openbao-2.openbao-internal:8201 follower    true
```

If only 1 peer: the others didn't join — check their logs:
`kubectl -n openbao logs openbao-1` (look for `retry_join` errors, often DNS
or TLS verification — verify the server cert SANs cover
`openbao-1.openbao-internal.openbao.svc.cluster.local`).

- [ ] **Step 7.8: Confirm pods are now Ready**

```bash
kubectl -n openbao get pods -l app.kubernetes.io/name=openbao
```

Expected: all 3 pods `READY 1/1`.

- [ ] **Step 7.9: Confirm the Ingress has a public TLS cert**

```bash
kubectl -n openbao get ingress
kubectl -n openbao describe certificate openbao-ingress-tls 2>/dev/null \
  || kubectl -n openbao get certificate
```

Expected: ingress shows the host `openbao.securek8s.de`. The
`openbao-ingress-tls` certificate exists and reaches `Ready=True` within ~60s
(LE issues via HTTP-01 through the ingress).

- [ ] **Step 7.10: External smoke test**

```bash
curl -sS https://openbao.securek8s.de/v1/sys/health | jq
```

Expected JSON with `"sealed": false`, `"initialized": true`, `"standby": false`
(or `true` if you happened to hit a follower).

The UI is reachable at https://openbao.securek8s.de/ui — login with the
Initial Root Token from step 7.4.

---

## Task 8: Final verification

- [ ] **Step 8.1: Confirm the working tree is clean**

```bash
git status
```

Expected: clean. All 6 commits made (Tasks 1–6 produced 5 commits; Task 7
produces no commits since it's runtime-only).

- [ ] **Step 8.2: Confirm the commit log**

```bash
git log --oneline | head -10
```

Expected: top 5 entries are the new commits.

- [ ] **Step 8.3: Confirm `make help` lists the new targets**

```bash
make help | grep -E '^  k8s-'
```

Expected: 4 lines.

- [ ] **Step 8.4: Confirm the cluster is happy**

```bash
make k8s-status
```

Expected: 3 pods `1/1 Running`, 6 PVCs (3 data + 3 audit) `Bound`, 3 services,
1 ingress, and `bao status` showing `Sealed false / HA Mode active`.

---

## Out-of-Scope (deferred — separate plans)

- Auto-unseal (Transit via VM-HA-Vault, or Cloud-KMS)
- Backup CronJob in K8s
- Terraform workspace `k8s` for in-vault config (auth methods, policies)
- ESO-Demo against the K8s-Vault (existing demos can be re-pointed via values)
- `values-homelab.yaml` for the second cluster
