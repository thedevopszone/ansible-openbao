# nginx-demo (OpenBao → Helm via Kubernetes Auth)

Self-contained Demo: ein nginx-Deployment, dessen Init-Container per
Kubernetes-Auth-Backend an OpenBao loggt, ein KV-v2-Secret liest und es als
HTML-Seite ausliefert.

Kein Operator nötig — die gesamte Mechanik steckt im Chart.

## Architektur

```
                  +-------------------------+
                  |  OpenBao 172.16.0.107   |
                  |  auth/kubernetes        |
                  |  policy: nginx-demo     |
                  |  role:   nginx-demo     |
                  +-----------+-------------+
                              ^
                              | (1) login mit SA-JWT
                              | (2) kv get secret/myapp/db
                              |
+---- Pod (NS nginx-demo) ----+----------+
| ServiceAccount: nginx-demo  |          |
|   + ClusterRoleBinding      |          |
|     system:auth-delegator   |          |
|                             v          |
| initContainer (openbao/openbao):       |
|   bao write auth/kubernetes/login ...  |
|   bao kv get -field=password secret... |
|   schreibt /shared/index.html          |
|                                        |
| container (nginx:alpine):              |
|   mountet /shared als /usr/share/nginx |
+----------------------------------------+
```

## Voraussetzungen auf OpenBao-Seite (einmalig)

KV-v2-Secret muss vorhanden sein (siehe Repo-README). Zusätzlich Kubernetes-
Auth einrichten:

```bash
export VAULT_ADDR=https://172.16.0.107:8200
export VAULT_TOKEN=<root-or-admin-token>
export VAULT_SKIP_VERIFY=true

# 1. Auth-Methode aktivieren
bao auth enable kubernetes

# 2. Cluster-API + CA hinterlegen
KUBE_HOST=https://172.16.0.252:6443
KUBE_CA_CERT="$(kubectl get cm kube-root-ca.crt -n default -o jsonpath='{.data.ca\.crt}')"

bao write auth/kubernetes/config \
    kubernetes_host="$KUBE_HOST" \
    kubernetes_ca_cert="$KUBE_CA_CERT"

# 3. Policy: read-only auf das gewünschte KV-v2-Secret
cat <<'EOF' | bao policy write nginx-demo -
path "secret/data/myapp/db" {
  capabilities = ["read"]
}
EOF

# 4. Role: bindet den SA nginx-demo aus NS nginx-demo an die Policy
bao write auth/kubernetes/role/nginx-demo \
    bound_service_account_names=nginx-demo \
    bound_service_account_namespaces=nginx-demo \
    policies=nginx-demo \
    ttl=1h
```

## Chart installieren

```bash
kubectl create namespace nginx-demo
helm install demo tests/helm/nginx-demo -n nginx-demo
```

Optional Werte überschreiben:

```bash
helm install demo tests/helm/nginx-demo -n nginx-demo \
  --set openbao.addr=https://172.16.0.107:8200 \
  --set openbao.kvPath=secret/myapp/db \
  --set openbao.secretKey=password
```

## Verifizieren

```bash
kubectl -n nginx-demo logs deploy/nginx-demo -c fetch-secret
# erwartet:
# [init] login to OpenBao at ...
# [init] read secret/myapp/db (key=password)
# [init] wrote /shared/index.html

kubectl -n nginx-demo port-forward svc/nginx-demo 18080:80
curl -s localhost:18080
# Liefert HTML mit "password = s3cr3t"
```

## Aufräumen

```bash
helm uninstall demo -n nginx-demo
kubectl delete namespace nginx-demo
```

OpenBao-seitig (optional):

```bash
bao delete auth/kubernetes/role/nginx-demo
bao policy delete nginx-demo
```

## Werte (`values.yaml`)

| Schlüssel | Default | Bedeutung |
| --- | --- | --- |
| `openbao.addr` | `https://172.16.0.107:8200` | API-Endpunkt |
| `openbao.skipVerify` | `true` | TLS-Cert nicht prüfen (selbst-signiert) |
| `openbao.authPath` | `kubernetes` | Mount-Pfad der Auth-Methode |
| `openbao.role` | `nginx-demo` | OpenBao-Role-Name |
| `openbao.kvPath` | `secret/myapp/db` | KV-v2-Pfad (logisch, ohne `/data/`) |
| `openbao.secretKey` | `password` | Key innerhalb des Secrets |
| `image.repository` / `tag` | `nginx` / `1.27-alpine` | App-Image |
| `initImage.repository` / `tag` | `openbao/openbao` / `latest` | Init-Image (bringt `bao` CLI mit) |
| `service.type` / `port` | `ClusterIP` / `80` | Service |

## Was bewusst weggelassen ist

- **Token-Renewal / Re-fetch:** Init-Container holt das Secret einmalig beim
  Pod-Start. Bei Secret-Rotation muss der Pod neu gestartet werden. Für
  laufende Synchronisation ist Vault Agent oder ESO der richtige Weg.
- **Ingress / Auth-Schutz:** Pure Demo, Service läuft als ClusterIP.
- **Resource-Requests/-Limits:** Default leer (`{}`), muss in produktiven
  Werten gesetzt werden.
