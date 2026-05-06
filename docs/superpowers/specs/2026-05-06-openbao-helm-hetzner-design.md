# OpenBao via Helm auf Hetzner K8s — Design

**Datum:** 2026-05-06
**Status:** Approved, ready for implementation plan
**Ziel-Cluster:** `hetzner` (kubectl-Context, RKE2 v1.29, 3 Control-Plane + 2 Worker Nodes)

## Zusammenfassung

Zweiter Installations-Pfad für OpenBao neben dem bestehenden Ansible-VM-Setup. OpenBao
läuft als 3-Replica-Raft-Cluster (Integrated Storage) im Kubernetes-Cluster `hetzner`,
ausgerollt über den offiziellen [openbao-helm](https://github.com/openbao/openbao-helm)
Chart. Die VM-Installation bleibt unverändert.

## Cluster-Voraussetzungen (im Cluster `hetzner` vorhanden)

| Komponente | Detail |
| --- | --- |
| K8s-Distro | RKE2 v1.29.4 |
| Storage | Longhorn (default StorageClass), `longhorn-rwx` für RWX, `longhorn-static` |
| Ingress | ingress-nginx (IngressClass `nginx`) |
| Cert-Manager | installiert, ClusterIssuers `letsencrypt-production` + `letsencrypt-staging` vorhanden |
| Nodes | 2 Worker (`worker-1`, `worker-2`), Control-Plane mit `NoSchedule`-Taint |
| DNS | `openbao.securek8s.de` → `91.98.218.42` (worker-1) bereits gesetzt |

## Design-Entscheidungen

### Deployment-Mode: HA Raft (3 Replicas)

`server.ha.enabled=true`, `server.ha.raft.enabled=true`. Analog zum bestehenden
VM-HA-Setup (3-Node-Raft). Soft pod-anti-affinity (`preferredDuringScheduling`),
weil nur 2 Worker-Nodes verfügbar sind und harte Anti-Affinity das Scheduling
blockieren würde. Konsequenz: 2 von 3 Pods sharen einen Worker — bei dessen
Ausfall ist Raft-Quorum verloren. Akzeptabel, weil:
- Echtes 3-Node-HA existiert bereits auf VMs (`openbao_ha_servers`).
- Der K8s-OpenBao ist sekundär (Test- bzw. cluster-interner Workload-Vault).
- Kein dritter Worker provisioniert werden soll.

### TLS — Split (intern self-signed CA, extern Let's Encrypt)

**Internal TLS (Pod ↔ Pod, listener auf 8200, raft cluster auf 8201):**
cert-manager mit eigener self-signed CA. Nicht Let's Encrypt — LE braucht
public-resolvbare Hostnames, Pod-DNS-Namen sind cluster-intern.

Setup-Reihenfolge (idempotent):

```
ClusterIssuer  selfsigned-bootstrap            (selfSigned: {})
   ↓ signiert
Certificate    openbao-ca   in NS cert-manager  (isCA: true, secretName: openbao-ca)
   ↓ wird referenziert von
ClusterIssuer  openbao-ca-issuer               (ca: { secretName: openbao-ca })
   ↓ signiert
Certificate    openbao-server-tls in NS openbao
   - secretName: openbao-server-tls
   - dnsNames:
       openbao
       openbao.openbao
       openbao.openbao.svc
       openbao.openbao.svc.cluster.local
       openbao-0.openbao-internal
       openbao-1.openbao-internal
       openbao-2.openbao-internal
       openbao-0.openbao-internal.openbao.svc.cluster.local
       openbao-1.openbao-internal.openbao.svc.cluster.local
       openbao-2.openbao-internal.openbao.svc.cluster.local
       openbao.securek8s.de
       localhost
   - ipAddresses: [127.0.0.1]
```

Das resultierende Secret `openbao-server-tls` enthält `tls.crt`, `tls.key`,
`ca.crt`. Alle 3 Pods mounten dieses Secret (`server.extraVolumes` /
`server.volumes`), trusten denselben CA und können sich gegenseitig verifizieren.
cert-manager rotiert das Cert automatisch (Default 90 Tage Lifetime, 1/3 Renewal-Threshold).

**External TLS (Ingress):** `letsencrypt-production` ClusterIssuer, ausgestellt
für `openbao.securek8s.de`. ingress-nginx terminiert TLS public und proxied
HTTPS-zu-HTTPS in den Cluster (Backend-Protocol `HTTPS`, weil OpenBao intern
nur HTTPS-Listener hat).

### Unseal: manuell (Shamir)

Kein auto-unseal. Nach Install/Pod-Restart manuelle Entsiegelung mit 3 von 5
Shamir-Keys via `kubectl exec`. Begründung: passt zur Linie des VM-HA-Setups,
keine Cloud-KMS-Dependency, kein zweiter OpenBao als Transit-KMS (Setup-Aufwand
nicht gerechtfertigt für sekundären Cluster).

### Storage

| Volume | Größe | StorageClass | Mount-Pfad |
| --- | --- | --- | --- |
| `data` (raft storage) | 10Gi | longhorn (default) | `/openbao/data` |
| `audit` | 1Gi | longhorn | `/openbao/audit` |

Audit-Log analog zur VM-HA-Variante (`audit "file"` an `audit.log`).

### Resources pro Pod

```yaml
requests: { cpu: 100m, memory: 256Mi }
limits:   { cpu: 500m, memory: 512Mi }
```

KV-only Workload, kein Heavy-Crypto. Bei Audit-Last oder vielen Lease-Renewals
ggf. nachjustieren.

### Externer Zugriff

Ingress (ingress-nginx, IngressClass `nginx`):

- Host: `openbao.securek8s.de`
- TLS via cert-manager (`cert-manager.io/cluster-issuer: letsencrypt-production`)
- Backend-Annotations:
  - `nginx.ingress.kubernetes.io/backend-protocol: HTTPS`
  - `nginx.ingress.kubernetes.io/proxy-ssl-verify: "off"` (Backend-Cert ist
    self-signed, ingress-nginx hat den CA nicht; UI/API-Verkehr ist trotzdem
    end-to-end TLS-verschlüsselt)

UI erreichbar unter https://openbao.securek8s.de/ui

## Repo-Struktur (Additionen)

```
helm/
  openbao/
    values-hetzner.yaml             # Helm-Values-Overlay für openbao/openbao
    manifests/
      namespace.yaml                # Namespace openbao
      cert-manager.yaml             # selfsigned-bootstrap + openbao-ca + ca-issuer + openbao-server-tls
    README.md                       # Install / Init / Unseal / Troubleshooting
Makefile                            # neue Targets, siehe unten
```

Bewusst **nicht** in der Repo-Struktur:
- Kein `terraform/`-Workspace für den K8s-Vault (kommt erst, wenn der erste
  Install läuft und Auth-Methoden konfiguriert werden sollen).
- Kein Backup-CronJob im K8s — bestehender `make backup`-Flow ist VM-fokussiert
  und wird separat adaptiert.

## Makefile-Targets (additiv, brechen nichts Bestehendes)

```make
k8s-prereqs:    ## Namespace + cert-manager Issuers/Cert anlegen
	kubectl apply -f helm/openbao/manifests/namespace.yaml
	kubectl apply -f helm/openbao/manifests/cert-manager.yaml
	kubectl wait --for=condition=Ready certificate/openbao-server-tls \
	  -n openbao --timeout=120s

k8s-install: k8s-prereqs    ## OpenBao via Helm in Cluster hetzner installieren
	helm repo add openbao https://openbao.github.io/openbao-helm 2>/dev/null || true
	helm repo update openbao
	helm upgrade --install openbao openbao/openbao \
	  -n openbao -f helm/openbao/values-hetzner.yaml

k8s-uninstall:    ## Helm release entfernen (PVCs bleiben!)
	helm uninstall openbao -n openbao

k8s-status:    ## Pod / Seal-Status anzeigen
	kubectl -n openbao get pods,pvc
	kubectl -n openbao exec openbao-0 -- bao status || true
```

`helm upgrade --install` macht das Target idempotent (initial install + spätere
Value-Änderungen via demselben Befehl).

## Bootstrap-Flow (User-facing, kommt ins README)

```bash
# kubectl-Context auf hetzner-Cluster
kubectl config use-context hetzner

# 1. Prereqs (Namespace + Internal-CA + Server-Cert)
make k8s-prereqs

# 2. Helm-Install
make k8s-install

# 3. Pod-0 initialisieren (gibt 5 Unseal-Keys + Root-Token aus — sicher wegspeichern!)
kubectl -n openbao exec -it openbao-0 -- bao operator init

# 4. Pod-0 entsiegeln (3× mit unterschiedlichen Keys)
kubectl -n openbao exec -it openbao-0 -- bao operator unseal <key 1>
kubectl -n openbao exec -it openbao-0 -- bao operator unseal <key 2>
kubectl -n openbao exec -it openbao-0 -- bao operator unseal <key 3>

# 5. Pod-1 und Pod-2 entsiegeln (joinen automatisch via retry_join)
for pod in openbao-1 openbao-2; do
  for k in <key 1> <key 2> <key 3>; do
    kubectl -n openbao exec -it $pod -- bao operator unseal "$k"
  done
done

# 6. Cluster-Status prüfen
kubectl -n openbao exec openbao-0 -- bao operator raft list-peers
# Erwartet: 3 peers, 1 leader, alle voter

# 7. UI: https://openbao.securek8s.de/ui — Login mit Initial-Root-Token
```

## Out-of-Scope (bewusst weggelassen, YAGNI)

- **Auto-Unseal:** kein Cloud-KMS, kein Transit-Unseal über VM-Vault. Wenn
  später gewünscht: separater Spec, Transit-Variante naheliegend (existing
  VM-HA-Cluster wird Master-KMS).
- **Backup-Automatisierung im K8s:** Raft-Snapshots können manuell via
  `kubectl exec ... -- bao operator raft snapshot save -` gezogen werden.
  CronJob-Pattern später, wenn Bedarf konkret ist.
- **Terraform-Integration:** sobald Auth-Methoden/Policies/AppRoles im
  K8s-Vault gemanaged werden sollen — eigener Spec, wahrscheinlich neuer
  Terraform-Workspace `k8s` analog zu `default` und `ha`.
- **External Secrets Operator-Integration:** ESO-Demos im Repo zeigen heute
  schon das Pattern gegen den VM-Vault. Gegen den K8s-Vault mit minimaler
  Anpassung der `openbao.addr` analog möglich, kein neuer Code nötig.
- **Multi-Cluster** (`values-homelab.yaml` o.ä.): erst wenn `hetzner` läuft.

## Risiken / Akzeptierte Trade-offs

1. **Quorum-Verlust bei Worker-Failure** — Konsequenz aus 2-Worker-Setup +
   3-Replica-HA. Mitigation: VM-HA bleibt der primäre Vault.
2. **Manuelles Unseal nach jedem Pod-Restart** — Kosten der Shamir-Strategie.
   Acceptable für sekundären Cluster.
3. **Self-signed Internal-CA nicht außerhalb K8s vertrauenswürdig** —
   externe Clients erreichen OpenBao via Ingress + LE-Cert (kein Problem).
   Cluster-interne Clients (z.B. ESO im selben Cluster) müssen den
   `openbao-ca`-Bundle als `caBundle` mounten.
4. **`helm uninstall` löscht keine PVCs** (Default des Charts). Bewusst, damit
   Daten nicht versehentlich weg sind. Cleanup explizit via `kubectl delete pvc`.
