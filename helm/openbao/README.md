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
| Helm 3 | `brew install helm@3` — siehe Anmerkung unten |

> **K8s 1.29 Workaround:** Der `openbao/openbao`-Chart fordert
> `kubeVersion >= 1.30`. Der Cluster läuft 1.29.4. `make k8s-install` rendert
> daher mit `helm@3 template --kube-version 1.30.0` und applyt mit `kubectl`,
> statt `helm install` zu nutzen. Konsequenz: keine Helm-Release-History,
> keine `helm rollback`. Sobald der Cluster auf 1.30+ aktualisiert ist, kann
> der Makefile-Target wieder auf `helm upgrade --install` umgestellt werden.

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
| `make k8s-install` | `k8s-prereqs` + `helm template \| kubectl apply` (idempotent) |
| `make k8s-uninstall` | `helm template \| kubectl delete` — PVCs bleiben erhalten |
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
