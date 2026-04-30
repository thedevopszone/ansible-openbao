# nginx-demo-eso (OpenBao → Helm via External Secrets Operator)

Selbe Demo-Idee wie [`nginx-demo`](../nginx-demo/), aber statt eines
Init-Containers übernimmt der **External Secrets Operator (ESO)** die
Synchronisation: ein `ExternalSecret`-Custom-Resource zieht das Secret
periodisch aus OpenBao und materialisiert es als reguläres K8s-`Secret`.
nginx mountet dieses Secret als Datei.

Vorteile gegenüber Init-Container-Pattern:

- **Kontinuierliche Synchronisation** — bei Secret-Rotation in OpenBao zieht
  ESO den neuen Wert nach (Default `refreshInterval: 1m`), ohne Pod-Restart.
- **Vendor-neutral** — derselbe Operator funktioniert mit AWS Secrets Manager,
  GCP Secret Manager, Azure Key Vault, GitHub etc.
- **Standard-K8s-Secret als Konsumformat** — Apps müssen nichts über OpenBao
  wissen.

Nachteile: cluster-weiter Operator nötig, eine zusätzliche Komponente, die
selbst Berechtigungen braucht.

## Architektur

```
                  +-------------------------+
                  |  OpenBao 172.16.0.107   |
                  |  auth/kubernetes        |
                  |  policy: nginx-demo     |
                  |  role:   nginx-demo-eso |
                  +-----------+-------------+
                              ^
                              | (1) ESO loggt mit SA-JWT von nginx-demo-eso
                              | (2) liest secret/myapp/db zyklisch
                              v
+---- ESO controller (NS external-secrets) -----+
|  watcht ExternalSecret → schreibt K8s Secret  |
+-----------+-----------------------------------+
            |
            v
+---- Pod (NS nginx-demo-eso) -------------+
|  ExternalSecret ──► K8s Secret           |
|         (template rendert index.html)    |
|                                          |
|  Deployment nginx mountet das Secret     |
|    als /usr/share/nginx/html/index.html  |
+------------------------------------------+
```

## Voraussetzungen

### 1. ESO-Controller installieren (einmalig pro Cluster)

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
kubectl -n external-secrets rollout status deploy
```

### 2. OpenBao K8s-Auth + Policy

Die Policy `nginx-demo` und der `kubernetes` Auth-Mount aus dem
[`nginx-demo`](../nginx-demo/README.md) Demo werden mit verwendet. Falls noch
nicht eingerichtet — siehe dort. Zusätzlich brauchst du **eine neue Role**,
die den SA `nginx-demo-eso`/NS `nginx-demo-eso` an die Policy bindet:

```bash
export VAULT_ADDR=https://172.16.0.107:8200
export VAULT_TOKEN=<root-or-admin-token>
export VAULT_SKIP_VERIFY=true

bao write auth/kubernetes/role/nginx-demo-eso \
    bound_service_account_names=nginx-demo-eso \
    bound_service_account_namespaces=nginx-demo-eso \
    policies=nginx-demo \
    ttl=1h
```

## Chart installieren

ESO hat **kein** `insecureSkipVerify` — das CA-Bundle muss korrekt
mitgegeben werden. Den OpenBao-Server-Cert vom Host holen und beim
`helm install` als `caBundle` setzen:

```bash
ssh ubuntu@172.16.0.107 'sudo cat /opt/openbao/tls/tls.crt' > /tmp/openbao-ca.crt

kubectl create namespace nginx-demo-eso
helm install demo tests/helm/nginx-demo-eso -n nginx-demo-eso \
  --set-string "openbao.caBundle=$(cat /tmp/openbao-ca.crt)"
```

> Voraussetzung: das OpenBao-Cert muss SAN-Einträge für die im
> `openbao.addr` verwendete IP/DNS enthalten — siehe Repo-README,
> Abschnitt **TLS-Zertifikat (SANs)**.

## Verifizieren

```bash
# 1. ExternalSecret muss SecretSynced=True erreichen
kubectl -n nginx-demo-eso get externalsecret -w

# 2. Materialisiertes K8s Secret sollte Key index.html enthalten
kubectl -n nginx-demo-eso get secret nginx-demo -o jsonpath='{.data.index\.html}' \
  | base64 -d

# 3. Über Service abrufen
kubectl -n nginx-demo-eso port-forward svc/nginx-demo-eso 18080:80
curl -s localhost:18080
# Liefert HTML mit "password = s3cr3t"
```

## Rotation testen

Secret in OpenBao ändern und beobachten, wie ESO innerhalb von
`refreshInterval` (1 min Default) das K8s-Secret aktualisiert:

```bash
bao kv put secret/myapp/db password=neuesPasswort
# warten ≤ 60s
kubectl -n nginx-demo-eso get secret nginx-demo -o jsonpath='{.data.index\.html}' \
  | base64 -d
```

Hinweis: nginx serviert die gemountete Datei sofort — das `Secret`-Volume
wird vom kubelet automatisch synchronisiert (eventual consistency, ~1 min).

## Aufräumen

```bash
helm uninstall demo -n nginx-demo-eso
kubectl delete namespace nginx-demo-eso
bao delete auth/kubernetes/role/nginx-demo-eso
# ESO-Controller ggf. cluster-weit drin lassen für andere Apps:
# helm uninstall external-secrets -n external-secrets
```

## Werte (`values.yaml`)

| Schlüssel | Default | Bedeutung |
| --- | --- | --- |
| `openbao.addr` | `https://172.16.0.107:8200` | API-Endpunkt |
| `openbao.caBundle` | `""` | PEM-Zertifikat. **Pflicht** für selbst-signierte Server — ESO hat kein Skip-Verify. Per `--set-string` aus Datei laden. |
| `openbao.authPath` | `kubernetes` | Mount-Pfad der Auth-Methode |
| `openbao.role` | `nginx-demo-eso` | OpenBao-Role |
| `openbao.kvMount` | `secret` | KV-v2-Mount |
| `openbao.kvKey` | `myapp/db` | Pfad innerhalb des Mounts |
| `openbao.secretKey` | `password` | Property innerhalb des KV-v2-Secrets |
| `externalSecret.refreshInterval` | `1m` | Sync-Intervall ESO ↔ OpenBao |
| `externalSecret.targetSecretName` | `nginx-demo` | Name des zu erzeugenden K8s-Secrets |

## Was bewusst weggelassen ist

- **`ClusterSecretStore` statt `SecretStore`:** Für Demos ist
  Namespace-scoped einfacher. Cluster-weit ginge auch und teilt sich die
  OpenBao-Auth über mehrere Namespaces.
- **Resource limits, NetworkPolicies, PodSecurity** — alles produktionsrelevant,
  hier aus didaktischen Gründen ausgelassen.
