# OpenBao

Ansible-Projekt zur automatisierten Installation und Verwaltung von
[OpenBao](https://openbao.org/) (Open-Source-Fork von HashiCorp Vault) auf
Ubuntu/Debian-Systemen.

Die Installation erfolgt über das offizielle `.deb`-Paket aus den GitHub-Releases,
da OpenBao aktuell kein eigenes APT-Repository anbietet.

## Voraussetzungen

- **Control Node**: Ansible ≥ 2.14, Python 3
- **Managed Nodes**: Ubuntu 22.04 (Jammy) / 24.04 (Noble) oder Debian 12 (Bookworm)
- **Architektur**: `amd64` oder `arm64`
- **Netzwerk**: SSH-Zugang zum Zielhost, Port 8200/TCP für UI/API erreichbar
- **Privilegien**: `sudo`/`become` auf dem Zielhost

## Repository-Struktur

```
.
├── ansible.cfg                 # Ansible-Konfiguration (Inventory-Pfad, Pipelining, …)
├── inventory/
│   └── hosts.yml               # Inventory mit Hosts und Verbindungs-Variablen
├── playbooks/
│   ├── install-openbao.yml     # Single-Node-Playbook ruft die Rolle auf
│   └── install-openbao-ha.yml  # 3-Node HA-Playbook (raft + Mini-CA)
└── roles/
    └── openbao/                # Rolle: Download + Install des .deb, optional HA
        ├── defaults/main.yml
        ├── handlers/main.yml
        ├── meta/main.yml
        ├── tasks/
        │   ├── main.yml        # Install (immer) + branch zu ha.yml
        │   └── ha.yml          # CA, Per-Host-Cert, HA-Config-Render
        ├── templates/
        │   └── openbao-ha.hcl.j2
        └── README.md
```

## Konfiguration

### Inventory

`inventory/hosts.yml` definiert die Zielhosts. Beispiel:

```yaml
all:
  children:
    openbao_servers:
      hosts:
        openbao-01:
          ansible_host: 172.16.0.107
          ansible_user: ubuntu
          ansible_become: true
```

### Ansible-Defaults

`ansible.cfg` setzt unter anderem:

- `inventory = inventory/hosts.yml`
- `host_key_checking = False` — kein interaktives Bestätigen unbekannter Hostkeys
- `pipelining = True` — schnellere SSH-Ausführung

## Verwendung

Über das beigelegte `Makefile`:

```bash
make help          # alle Targets
make deps          # Ansible-Collections + Python-Deps in .venv installieren
make install       # OpenBao Single-Node installieren
make install-ha    # OpenBao 3-Node HA-Cluster installieren (raft, eigene CA)
make backup        # Raft-Snapshot ziehen nach ./backups/ (VAULT_TOKEN nötig)
make ping          # Ansible-Hosts pingen
make tf-init       # terraform init
make tf-plan       # terraform plan (single-node, VAULT_TOKEN nötig)
make tf-apply      # terraform apply (single-node)
make tf-plan  CLUSTER=ha  # gleicher Aufruf gegen HA-Cluster (workspace=ha)
make tf-apply CLUSTER=ha
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

```bash
ansible-playbook playbooks/install-openbao.yml
```

Erreichbarkeit prüfen:

```bash
ansible openbao_servers -m ping
```

Spezifische Version installieren (überschreibt Rollen-Default):

```bash
ansible-playbook playbooks/install-openbao.yml -e openbao_version=2.5.3
```

## Was wird installiert

Das offizielle `.deb`-Paket bringt mit:

| Komponente | Pfad / Wert |
| --- | --- |
| Binary | `/usr/bin/bao` |
| systemd-Unit | `openbao.service` (User/Group `openbao`) |
| Hauptkonfig | `/etc/openbao/openbao.hcl` |
| Env-File | `/etc/openbao/openbao.env` |
| Daten (file-Storage) | `/opt/openbao/data` |
| TLS-Zertifikate | `/opt/openbao/tls/tls.{crt,key}` (selbst-signiert, 3 Jahre) |
| Listener | `https://0.0.0.0:8200` (UI aktiviert) |

Die Rolle template-t `openbao.hcl` **nicht** — die Standard-Config aus dem
Paket bleibt erhalten.

## Erstinitialisierung

Nach der Installation läuft OpenBao `sealed` und ist nicht initialisiert.
Einmalig auf dem Zielhost ausführen:

```bash
ssh ubuntu@<host>
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true   # selbst-signiertes Zertifikat
bao operator init
bao operator unseal <key 1>
bao operator unseal <key 2>
bao operator unseal <key 3>
```

`bao operator init` gibt fünf Unseal-Keys (Shamir-Shares) und einen
Initial-Root-Token aus. Beides **sicher und getrennt verwahren** — ohne diese
Keys ist der Vault-Inhalt nach einem Neustart nicht entsperrbar.

Nach jedem Service-Restart muss der Vault per `bao operator unseal` mit drei
der fünf Keys wieder entsperrt werden.

## Web-UI

Die UI ist unter folgender Adresse erreichbar:

```
https://<host>:8200/ui
```

Da das TLS-Zertifikat selbst-signiert ist, wird der Browser eine Warnung
anzeigen — diese muss akzeptiert werden. Login erfolgt mit dem Initial-Root-Token
(oder einem später angelegten Token).

## TLS-Zertifikat (SANs)

Das aus dem `.deb`-Paket mitgelieferte Cert enthält **keine Subject
Alternative Names** — nur `CN=OpenBao`. Moderne Go-Clients (Vault SDK,
External Secrets Operator, …) ignorieren CN und verlangen explizit SANs.
Tools mit Skip-Verify-Flag (`VAULT_SKIP_VERIFY=true`) kommen damit klar,
strikte Clients wie ESO scheitern an `x509: ... doesn't contain any IP SANs`.

Empfohlen: einmalig nach der Installation einen Cert mit korrekten SANs
erzeugen.

```bash
ssh ubuntu@<host>
TS=$(date +%Y%m%d-%H%M%S)
sudo cp -av /opt/openbao/tls/tls.crt /opt/openbao/tls/tls.crt.bak-$TS
sudo cp -av /opt/openbao/tls/tls.key /opt/openbao/tls/tls.key.bak-$TS

sudo openssl req -x509 -newkey rsa:2048 -nodes -days 1095 \
  -keyout /tmp/tls.key.new -out /tmp/tls.crt.new \
  -subj "/O=OpenBao/CN=<hostname>" \
  -addext "subjectAltName=IP:<ip>,DNS:<hostname>,DNS:localhost,IP:127.0.0.1"

sudo install -o openbao -g openbao -m 600 /tmp/tls.crt.new /opt/openbao/tls/tls.crt
sudo install -o openbao -g openbao -m 600 /tmp/tls.key.new /opt/openbao/tls/tls.key
sudo rm /tmp/tls.crt.new /tmp/tls.key.new

sudo systemctl restart openbao
# OpenBao ist jetzt sealed → 3× bao operator unseal
```

CA-Bundle für strikte Clients:

```bash
ssh ubuntu@<host> 'sudo cat /opt/openbao/tls/tls.crt' > /tmp/openbao-ca.crt
curl --cacert /tmp/openbao-ca.crt https://<host>:8200/v1/sys/health
```

## Variablen

Siehe [`roles/openbao/README.md`](roles/openbao/README.md) für die vollständige
Liste der überschreibbaren Variablen der Rolle.

## Secrets aus OpenBao in Ansible nutzen

OpenBao ist API-kompatibel zu HashiCorp Vault — Secrets werden über die
Collection [`community.hashi_vault`](https://docs.ansible.com/ansible/latest/collections/community/hashi_vault/)
gelesen.

### Abhängigkeiten

`requirements.yml` (Ansible-Collection) und `requirements.txt` (Python `hvac`)
werden gemeinsam installiert via:

```bash
make deps
```

Das Target legt ein lokales `.venv/` an und installiert dort `hvac` sowie die
Collection. Das Test-Playbook setzt `ansible_python_interpreter` explizit auf
`.venv/bin/python`, eine Aktivierung des venv ist daher nicht nötig.

### Secret anlegen

KV-v2-Secret anlegen, das vom Test-Playbook gelesen wird (Pfad `secret/myapp/db`,
Key `password`):

```bash
export VAULT_ADDR=https://172.16.0.107:8200
export VAULT_TOKEN=<root-or-admin-token>
export VAULT_SKIP_VERIFY=true

# KV-v2 Engine einmalig aktivieren (falls nicht vorhanden):
bao secrets enable -path=secret -version=2 kv

# Secret schreiben:
bao kv put secret/myapp/db password=s3cr3t

# Prüfen:
bao kv get secret/myapp/db
```

Alternativ über die Web-UI (`/ui` → Secrets Engines → `secret/` → Create
secret) oder via Terraform-Ressource `vault_kv_secret_v2`. Hinweis: bei
Terraform landet der Wert im State.

### Test-Playbook

`tests/ansible/print_var.yaml` liest das Secret und gibt den Wert aus:

```bash
export VAULT_ADDR=https://172.16.0.107:8200
export VAULT_TOKEN=<token>
ansible-playbook tests/ansible/print_var.yaml
```

Pfad/Mount/Key sind als Variablen überschreibbar:

```bash
ansible-playbook tests/ansible/print_var.yaml \
  -e openbao_secret_path=other/app \
  -e openbao_secret_mount=secret \
  -e openbao_secret_key=api_key
```

### Authentifizierung ohne `VAULT_TOKEN` bei jedem Aufruf

`VAULT_TOKEN` jedes Mal in die Shell zu exportieren ist umständlich. Drei
gängige Wege, das zu vermeiden — je nach Use-Case:

#### Option 1 — `~/.vault-token` (lokales Dev-Setup)

`bao login` schreibt den ausgestellten Client-Token automatisch nach
`~/.vault-token`. Die `community.hashi_vault`-Collection (bzw. `hvac`) liest
diese Datei automatisch, wenn `VAULT_TOKEN` nicht gesetzt ist.

```bash
brew install openbao   # bao CLI lokal, einmalig

export VAULT_ADDR=https://172.16.0.107:8200
export VAULT_SKIP_VERIFY=true
bao login -method=userpass username=tzachmann   # einmalig, fragt Passwort

# Danach kein Token-Export mehr nötig:
ansible-playbook tests/ansible/print_var.yaml
```

Der Token bleibt bis zum Ablauf der Userpass-TTL (Default 768h) gültig — erst
dann erneut einloggen. `~/.vault-token` enthält den Token im Klartext, daher
nur auf Geräten mit Disk-Encryption verwenden.

#### Option 2 — AppRole (Automatisierung / CI)

AppRole ist explizit für „Maschinen ohne menschliches Login" gedacht. Die
`role_id` ist langlebig, die `secret_id` ist rotierbar. Beides kommt z. B. aus
CI-Secrets oder einer lokalen, nicht eingecheckten Env-Datei.

Im Playbook:

```yaml
- community.hashi_vault.vault_kv2_get:
    path: myapp/db
    auth_method: approle
    role_id: "{{ lookup('env', 'OPENBAO_ROLE_ID') }}"
    secret_id: "{{ lookup('env', 'OPENBAO_SECRET_ID') }}"
```

Die AppRole-Infrastruktur ist im Terraform-Code (`terraform/approle.tf`)
bereits vorbereitet — eine konkrete Rolle anlegen und eine `secret_id`
ausstellen, dann als Env-Var in CI hinterlegen. **Niemals den Root-Token im
CI verwenden.**

#### Option 3 — `direnv` (projektlokales Auto-Env)

[`direnv`](https://direnv.net/) lädt eine `.envrc` automatisch beim `cd` ins
Projekt-Verzeichnis und entlädt sie beim Verlassen.

```bash
brew install direnv   # einmalig, plus Hook in ~/.zshrc: eval "$(direnv hook zsh)"
```

Im Repo eine `.envrc` anlegen (**nicht committen** — gehört in `.gitignore`):

```bash
# .envrc
export VAULT_ADDR=https://172.16.0.107:8200
export VAULT_SKIP_VERIFY=true
export VAULT_TOKEN="$(cat ~/.vault-token 2>/dev/null)"
```

Einmalig freigeben:

```bash
direnv allow
```

Danach werden die Variablen automatisch gesetzt, sobald du ins Projekt
wechselst. Kombinierbar mit Option 1: `bao login` schreibt den Token,
`direnv` exportiert ihn.

#### Empfehlung

- **Lokal:** Option 1 (`bao login`), optional plus Option 3 für `VAULT_ADDR`.
- **Automatisierung / CI:** Option 2 (AppRole).
- **Root-Token** wird ausschließlich für Bootstrap und Recovery genutzt und
  bleibt offline weggesperrt.

## Secrets aus OpenBao in Kubernetes nutzen

Zwei lauffähige Helm-Chart-Demos unter [`tests/helm/`](tests/helm/) — beide
ziehen dasselbe KV-v2-Secret `secret/myapp/db.password` und rendern es als
HTML-Seite.

| Pfad | Pattern | Cluster-Voraussetzung | Rotation |
| --- | --- | --- | --- |
| [`tests/helm/nginx-demo`](tests/helm/nginx-demo/) | Init-Container loggt mit SA-JWT, liest Secret per `bao` CLI, schreibt ins Pod-`emptyDir` | keine | nur per Pod-Restart |
| [`tests/helm/nginx-demo-eso`](tests/helm/nginx-demo-eso/) | External Secrets Operator reconciliert OpenBao → K8s-`Secret`, nginx mountet es | ESO Controller einmalig | automatisch (`refreshInterval`) |

### Wie das funktioniert — drei Vertrauensbeziehungen

OpenBao gibt nur dann ein Secret raus, wenn es *sicher* weiß, **wer**
fragt. Bei K8s-Pods gibt es kein Passwort — also wird die Identität so
nachgewiesen:

```
                        +-------------+
                        |  K8s API    |  ← die "Wahrheitsquelle" für Pod-Identität
                        +------+------+
                       (1)|         ^
                vertraut: |         |(3) "ist dieses JWT echt?"
                CA-Cert   v         |    (TokenReview API)
+------------+        +-----------------+
|  K8s API   |<--(2)--|    OpenBao      |
|            |  JWT   |  auth/kubernetes|
+------------+        +-----------------+
       ^                       ^
       | gibt Pod ein JWT      | (4) "ich bin SA xyz, login!"
       | (automatisch im Pod)  |     hier ist mein JWT
+------+----+                  |
|   Pod     +------------------+
|  SA: xyz  |
+-----------+
```

Drei Trust-Edges:

1. **OpenBao → K8s API:** OpenBao kennt die K8s-API-URL + CA-Cert (gesetzt
   per `bao write auth/kubernetes/config`).
2. **K8s → Pod:** Kubelet mountet automatisch ein JWT in jeden Pod unter
   `/var/run/secrets/kubernetes.io/serviceaccount/token`. Das JWT ist
   K8s-signiert und sagt: „Dieser Pod hat ServiceAccount `xyz` in Namespace
   `n`".
3. **K8s validiert das JWT für OpenBao** (TokenReview API): wenn OpenBao
   fragt „ist dieses JWT echt?", muss der anfragende SA das tun dürfen.
   Deshalb hat unser SA das ClusterRoleBinding auf `system:auth-delegator`.

#### Variante A — Init-Container: Der Pod holt selbst

```
┌────────────────────────────────────────────────────────────────────┐
│ Pod startet (Namespace: nginx-demo)                                │
│                                                                    │
│ 1. kubelet mountet JWT in /var/run/secrets/.../token               │
│                                                                    │
│ 2. Init-Container (openbao/openbao Image) läuft:                   │
│    a) bao write auth/kubernetes/login                              │
│         role=nginx-demo                                            │
│         jwt=<inhalt von /var/run/.../token>                        │
│       ↓                                                            │
│       OpenBao ruft K8s TokenReview API auf:                        │
│         "Ist dieses JWT valid?" → "ja, SA=nginx-demo NS=nginx-demo"│
│       ↓                                                            │
│       OpenBao prüft Role nginx-demo:                               │
│         bound_service_account_names=[nginx-demo] ✓                 │
│         bound_service_account_namespaces=[nginx-demo] ✓            │
│       ↓                                                            │
│       OpenBao stellt aus: client_token + Policy nginx-demo         │
│                                                                    │
│    b) bao kv get -field=password secret/myapp/db                   │
│       (mit dem client_token aus a)                                 │
│       ↓                                                            │
│       OpenBao prüft Policy: "darf path secret/data/myapp/db" ✓     │
│       ↓                                                            │
│       OpenBao gibt zurück: "s3cr3t"                                │
│                                                                    │
│    c) schreibt /shared/index.html mit dem Wert                     │
│                                                                    │
│ 3. Init beendet, Hauptcontainer (nginx) startet, mountet /shared   │
│    als HTML-Root und serviert die Seite.                           │
└────────────────────────────────────────────────────────────────────┘
```

Der Pod selbst macht den Login. Kein zentraler Operator nötig — aber das
passiert nur **einmal** beim Pod-Start.

#### Variante B — ESO: Der Operator holt für den Pod

```
┌────────────────── External Secrets Operator (NS external-secrets) ──┐
│ watcht ExternalSecret-Resources cluster-weit                        │
└────────┬─────────────────────────────────────────────────────┬──────┘
         │                                                     │
         │ liest ExternalSecret                                 │ schreibt
         │                                                     │ K8s Secret
         ▼                                                     ▼
┌───────────────────── Namespace nginx-demo-eso ───────────────────────┐
│                                                                      │
│  SecretStore "nginx-demo-eso"                                        │
│    provider.vault: server, path, caBundle                            │
│    auth.kubernetes.serviceAccountRef: nginx-demo-eso  ← welche SA    │
│                                       nutzen, um JWT  zu beziehen    │
│                                                                      │
│  ServiceAccount "nginx-demo-eso"                                     │
│    + ClusterRoleBinding system:auth-delegator                        │
│                                                                      │
│  ExternalSecret "nginx-demo-eso"                                     │
│    secretStoreRef: nginx-demo-eso                                    │
│    refreshInterval: 1m                                               │
│    data: secretKey=password, remoteRef.key=myapp/db                  │
│                                                                      │
│  K8s Secret "nginx-demo" (von ESO erzeugt, refresht alle 1m)         │
│    data.index.html = <gerenderte Seite mit password=s3cr3t>          │
│                                                                      │
│  Deployment nginx-demo-eso                                           │
│    mountet K8s Secret "nginx-demo" als /usr/share/nginx/html/        │
└──────────────────────────────────────────────────────────────────────┘
```

Was ESO alle 60 Sekunden tut:

1. ESO ruft die K8s API: „gib mir ein neues, kurzlebiges JWT für SA
   `nginx-demo-eso` in NS `nginx-demo-eso`" (TokenRequest API).
2. ESO sendet dieses JWT an OpenBao — identische Login-Logik wie bei A —
   bekommt `client_token` mit Policy `nginx-demo`.
3. ESO liest `secret/data/myapp/db` → bekommt `password=s3cr3t`.
4. ESO rendert das Template aus `ExternalSecret.spec.target.template.data`
   mit `{{ .password }}` → fertige HTML-Seite.
5. ESO erstellt/aktualisiert das K8s-`Secret` `nginx-demo` mit dem Inhalt.
6. nginx hat das `Secret` als Volume gemountet → kubelet syncht den
   Inhalt → nginx serviert die neue Seite.

Der App-Pod selbst weiß nichts von OpenBao — für ihn ist es einfach ein
normales K8s-Secret.

#### Was beim Init-Container anders läuft als bei ESO

|  | Init-Container (A) | ESO (B) |
| --- | --- | --- |
| Wer macht den Login? | der Pod selbst | der ESO-Controller |
| Welcher SA loggt sich ein? | der App-SA (`nginx-demo`) | der im SecretStore referenzierte SA (`nginx-demo-eso`) |
| Wann wird gelesen? | einmalig beim Pod-Start | zyklisch (`refreshInterval`) |
| Konsumformat im App-Pod | Datei im `emptyDir` | normales K8s-`Secret` |
| Bei Secret-Rotation | Pod muss neu starten | App-Pod sieht neuen Wert ohne Restart |

#### Verifikation am laufenden Beispiel

Init-Container-Demo, Pod-Log:

```
[init] login to OpenBao at https://172.16.0.107:8200 via auth/kubernetes (role=nginx-demo)
[init] read secret/myapp/db (key=password)
[init] wrote /shared/index.html
```

ESO-Demo, Resource-States:

```
SecretStore     ... STATUS=Valid          ← Edge 1+3 ok, Login klappt
ExternalSecret  ... STATUS=SecretSynced   ← Edge 4 (read) ok, K8s-Secret erstellt
Secret nginx-demo ... DATA=1              ← materialisiertes Secret-Objekt
```

### Gemeinsame Voraussetzung: OpenBao Kubernetes-Auth

Einmal pro Cluster aktivieren und Cluster-API + CA hinterlegen:

```bash
export VAULT_ADDR=https://172.16.0.107:8200
export VAULT_TOKEN=<root-or-admin-token>

KUBE_HOST="https://<api-server>:6443"
KUBE_CA_CERT="$(kubectl get cm kube-root-ca.crt -n default -o jsonpath='{.data.ca\.crt}')"

bao auth enable kubernetes
bao write auth/kubernetes/config \
    kubernetes_host="$KUBE_HOST" \
    kubernetes_ca_cert="$KUBE_CA_CERT"
```

Policy für genau dieses KV-Secret:

```bash
cat <<'EOF' | bao policy write nginx-demo -
path "secret/data/myapp/db" {
  capabilities = ["read"]
}
EOF
```

### Variante A — Init-Container (`nginx-demo`)

Self-contained, kein Operator nötig. Der Pod authentifiziert sich mit seiner
eigenen ServiceAccount-JWT direkt am OpenBao Kubernetes-Auth-Backend, der
Init-Container holt das Secret und schreibt es ins shared `emptyDir`.

```bash
# 1. Role binden
bao write auth/kubernetes/role/nginx-demo \
    bound_service_account_names=nginx-demo \
    bound_service_account_namespaces=nginx-demo \
    policies=nginx-demo \
    ttl=1h

# 2. Chart installieren
kubectl create namespace nginx-demo
helm install demo tests/helm/nginx-demo -n nginx-demo

# 3. Verifizieren
kubectl -n nginx-demo logs deploy/nginx-demo -c fetch-secret
kubectl -n nginx-demo port-forward svc/nginx-demo 18080:80
curl localhost:18080
```

Details und Werte: [`tests/helm/nginx-demo/README.md`](tests/helm/nginx-demo/README.md).

### Variante B — External Secrets Operator (`nginx-demo-eso`)

Cluster-weiter Operator, der OpenBao-Secrets in native K8s-`Secret`-Objekte
synchronisiert — Apps konsumieren das Secret als ganz normalen K8s-Secret,
ohne OpenBao-Wissen. Bei Secret-Rotation in OpenBao zieht ESO den neuen
Wert automatisch nach (Default `refreshInterval: 1m`).

```bash
# 1. ESO einmal pro Cluster installieren
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --wait

# 2. Eigene Role für ESO-Demo binden
bao write auth/kubernetes/role/nginx-demo-eso \
    bound_service_account_names=nginx-demo-eso \
    bound_service_account_namespaces=nginx-demo-eso \
    policies=nginx-demo \
    ttl=1h

# 3. CA-Bundle vom OpenBao-Host holen (ESO hat kein skip-verify!)
ssh ubuntu@172.16.0.107 'sudo cat /opt/openbao/tls/tls.crt' > /tmp/openbao-ca.crt

# 4. Chart installieren
kubectl create namespace nginx-demo-eso
helm install demo tests/helm/nginx-demo-eso -n nginx-demo-eso \
  --set-string "openbao.caBundle=$(cat /tmp/openbao-ca.crt)"

# 5. Verifizieren
kubectl -n nginx-demo-eso get secretstore,externalsecret,secret
kubectl -n nginx-demo-eso port-forward svc/nginx-demo-eso 18080:80
curl localhost:18080
```

Voraussetzung: das OpenBao-Cert muss SAN-Einträge für die `openbao.addr`
enthalten — siehe Abschnitt [TLS-Zertifikat (SANs)](#tls-zertifikat-sans).

Details und Rotations-Test: [`tests/helm/nginx-demo-eso/README.md`](tests/helm/nginx-demo-eso/README.md).

### Wann welche Variante

- **Init-Container (A):** Tests, einfache Apps, Secrets ändern sich selten,
  Pod-Restart bei Rotation akzeptabel. Kein cluster-weiter Operator.
- **ESO (B):** Mehrere Apps konsumieren OpenBao-Secrets, automatische
  Rotation gewünscht, vendor-neutrales Konsumformat (K8s-Secret) bevorzugt.

## HA-Deployment (3 Nodes, Raft)

Für ein hochverfügbares Setup gibt es ein eigenes Playbook
[`playbooks/install-openbao-ha.yml`](playbooks/install-openbao-ha.yml). Es
deployt OpenBao auf mehrere VMs als Raft-Cluster (Integrated Storage), inkl.
einer eigenen Mini-CA auf der Control-Node und Per-Host-Server-Certs mit
korrekten SANs.

### Inventory

Die HA-Hosts liegen in einer eigenen Gruppe `openbao_ha_servers`. Default
(`inventory/hosts.yml`):

```yaml
openbao_ha_servers:
  vars:
    ansible_user: ubuntu
    ansible_become: true
  hosts:
    openbao-ha-01:
      ansible_host: 172.16.0.143
    openbao-ha-02:
      ansible_host: 172.16.0.120
    openbao-ha-03:
      ansible_host: 172.16.0.69
```

Der bestehende `openbao_servers`-Single-Node bleibt unverändert nebenher.

### Was die HA-Variante tut (zusätzlich zum Single-Node-Pfad)

1. **Mini-CA** auf der Control-Node erzeugen (`./.openbao-ca/ca.{key,crt}`,
   gitignored, persistent über Runs).
2. Pro Host ein **Server-Cert** mit IP-SANs für alle 3 Cluster-IPs +
   `127.0.0.1` und DNS-SAN `localhost` ausstellen, mit der CA signieren und
   als `/opt/openbao/tls/{ca.crt,tls.crt,tls.key}` ausrollen.
3. Eine vollständige **HA-`openbao.hcl`** rendern:
   - `storage "raft"` mit `node_id = inventory_hostname`,
   - `retry_join` für jeden Peer (Self-Skip ist erlaubt → symmetrische Config),
   - `listener "tcp"` auf `0.0.0.0:8200` + `cluster_address 0.0.0.0:8201`
     mit dem signierten Cert,
   - `audit "file"` (wenn `openbao_audit_enabled`).

### Deploy

```bash
make install-ha
```

Nach dem Run laufen alle 3 Services `sealed`. **Init und Unseal sind
manuell** — analog zum Single-Node-Workflow:

```bash
export VAULT_CACERT=$(pwd)/.openbao-ca/ca.crt

# 1. Auf Node 1 initialisieren
export VAULT_ADDR=https://172.16.0.143:8200
bao operator init     # gibt 5 Unseal-Keys + Initial-Root-Token aus

# 2. Node 1 entsiegeln (3× mit verschiedenen Keys)
bao operator unseal <key 1>
bao operator unseal <key 2>
bao operator unseal <key 3>

# 3. Node 2 + 3 joinen automatisch via retry_join, sind sealed.
#    Mit denselben Unseal-Keys entsiegeln:
for ip in 172.16.0.120 172.16.0.69; do
  for k in <key 1> <key 2> <key 3>; do
    VAULT_ADDR=https://$ip:8200 bao operator unseal "$k"
  done
done

# 4. Cluster-Status prüfen — erwartet: 3 Peers, ein Leader, alle voter
VAULT_ADDR=https://172.16.0.143:8200 bao operator raft list-peers
```

### Hinweise

- **Frische VMs vorausgesetzt:** Wenn unter `/opt/openbao/data` schon ein
  alter File-Storage liegt (z.B. weil das `.deb` schon einmal Single-Node
  gestartet wurde), muss er vor dem ersten HA-Run weg — Raft kann den nicht
  übernehmen.
- **Cert-Rotation** (z.B. neuer Peer): einfach `make install-ha` erneut
  ausführen — die CA bleibt persistent unter `.openbao-ca/`, neue Per-Host-Certs
  werden idempotent gegen die bestehende CA signiert.
- **CA-Bundle** (`.openbao-ca/ca.crt`) ist der Trust-Anchor für strikte
  Clients (Terraform-Provider, ESO, …). Statt `VAULT_SKIP_VERIFY=true` lieber
  `VAULT_CACERT=…/ca.crt` exportieren.
- **Inter-Host-Konnektivität:** Die VMs müssen sich gegenseitig auf TCP/8200
  und TCP/8201 erreichen können (Raft-Cluster-Verkehr).

## Backup (Raft-Snapshot)

Das Playbook [`playbooks/backup-openbao.yml`](playbooks/backup-openbao.yml)
zieht einen Raft-Snapshot aus dem laufenden Cluster und legt ihn auf der
Control-Node unter `./backups/openbao-<host>-<timestamp>.snap` ab.

### Was ein Snapshot enthält

- alle KV-Secrets, Auth-Methoden, Policies, AppRoles, Mounts — der komplette
  logische Vault-Inhalt.
- die Daten sind verschlüsselt mit dem Master-Key, der wiederum per
  Shamir-Shares (Unseal-Keys) gewrappt ist. **Zum Restore brauchst du
  trotzdem die Original-Unseal-Keys.**
- Snapshots sind Cluster-konsistent — egal von welchem Node gezogen.

### Aufruf

```bash
export VAULT_TOKEN=<root-or-backup-token>
make backup
```

Output:
```
Snapshot gespeichert unter <repo>/backups/openbao-openbao-ha-01-20260504T103045.snap
```

### Variablen / Overrides

| Variable | Default | Bedeutung |
| --- | --- | --- |
| `openbao_backup_target` | `groups.openbao_ha_servers[0]` | Inventory-Hostname, von dem der Snapshot gezogen wird |
| `openbao_backup_local_dir` | `<repo>/backups` | Zielverzeichnis auf der Control-Node |
| `openbao_token` | aus `VAULT_TOKEN` | Token für die Raft-Snapshot-API |
| `openbao_api_port` | `8200` | API-Port auf dem Zielhost |
| `openbao_tls_dir` | `/opt/openbao/tls` | Wo das CA-Cert (`ca.crt`) auf dem Host liegt |

Beispiele:

```bash
# Anderen Quell-Node nutzen
ansible-playbook playbooks/backup-openbao.yml -e openbao_backup_target=openbao-ha-02

# Auf Off-Site-Mount schreiben
ansible-playbook playbooks/backup-openbao.yml -e openbao_backup_local_dir=/mnt/nas/openbao

# Token aus ~/.vault-token statt Env
ansible-playbook playbooks/backup-openbao.yml -e openbao_token=$(cat ~/.vault-token)
```

### Eigener Backup-Token (statt Root-Token)

Root-Token im Cron ist unnötig riskant. Lieber einen langlebigen Token mit
einer minimalen Backup-Policy ausstellen:

```bash
# Policy nur für Snapshots
cat <<'EOF' | bao policy write backup -
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
EOF

# Periodischer Token (renewable, kein TTL-Ablauf wenn regelmäßig genutzt)
bao token create -policy=backup -period=720h -display-name=raft-backup
# → Token kopieren, in den Cron-Slot des Backup-Users hinterlegen
```

Den Backup-Token revoken, sobald er nicht mehr gebraucht wird:
`bao token revoke <accessor>`.

### Cron-Beispiel

Täglich um 03:00 von der Control-Node aus, mit Logging:

```cron
# /etc/cron.d/openbao-backup
0 3 * * *  ubuntu  cd /opt/ansible-openbao && VAULT_TOKEN=$(cat /etc/openbao/backup.token) make backup >> /var/log/openbao-backup.log 2>&1
```

Für **Off-Site-Kopien** den Zielordner danach z.B. via `restic`/`rclone`
auf S3/B2 syncen — der Snapshot allein nützt nichts, wenn er auf derselben
Maschine liegt wie der Vault. Retention/Rotation lokaler Snapshots ist
bewusst nicht im Playbook — das gehört in die Backup-Pipeline drumherum.

### Sicherheit

- **Niemals committen.** `backups/` ist gitignored.
- Snapshot-Files mind. `chmod 0600` halten — sie enthalten alle verschlüsselten
  Secrets. Wer sie + die Unseal-Keys hat, hat den ganzen Vault.
- CA + Backup gehören in **getrennte** Storage-Locations (sonst kann ein
  Angreifer mit Zugriff auf einen Ort nicht beides gleichzeitig).

### Restore-Flow

```bash
export VAULT_ADDR=https://172.16.0.143:8200
export VAULT_CACERT=$(pwd)/.openbao-ca/ca.crt
export VAULT_TOKEN=<root-token>

bao operator raft snapshot restore ./backups/openbao-openbao-ha-01-20260504T103045.snap
```

Nach dem Restore wird der Vault wieder sealed — mit den **Original-Unseal-Keys
zum Zeitpunkt des Snapshots** entsiegeln. Wenn die Keys seitdem rotiert wurden,
brauchst du die alten.

> **Restore-Test mindestens 1× in eine separate Test-VM durchspielen.**
> Ungetestete Backups sind keine Backups.

## Konfiguration via Terraform

Was *innerhalb* von OpenBao passiert (Auth-Methoden, Policies, User,
Secret-Engines) wird über Terraform verwaltet. Der Code liegt unter
[`terraform/`](terraform/) und nutzt den `hashicorp/vault`-Provider, der mit
OpenBao API-kompatibel ist.

Erstes Ziel: Userpass-Auth + Admin-Policy + ein Admin-User, damit der
Initial-Root-Token nach dem Bootstrap weggesperrt werden kann.

Single-Node und HA-Cluster werden parallel über **Terraform-Workspaces**
verwaltet — gleicher Code, getrennter State, getrennte tfvars-Dateien:

```bash
make tf-apply              # Single-Node (default, workspace=default, terraform.tfvars)
make tf-apply CLUSTER=ha   # HA-Cluster (workspace=ha, ha.tfvars, VAULT_CACERT auto-gesetzt)
```

Details und Bootstrap-Anleitung: [`terraform/README.md`](terraform/README.md).

## Lizenz

MIT
