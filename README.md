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
│   └── install-openbao.yml     # Top-Level-Playbook ruft die Rolle auf
└── roles/
    └── openbao/                # Rolle: Download + Install des .deb
        ├── defaults/main.yml
        ├── handlers/main.yml
        ├── meta/main.yml
        ├── tasks/main.yml
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
make install       # OpenBao via Ansible installieren
make ping          # Ansible-Hosts pingen
make tf-init       # terraform init
make tf-plan       # terraform plan (VAULT_TOKEN nötig)
make tf-apply      # terraform apply
make deploy        # install + tf-init + tf-apply in einem Rutsch
```

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

## Konfiguration via Terraform

Was *innerhalb* von OpenBao passiert (Auth-Methoden, Policies, User,
Secret-Engines) wird über Terraform verwaltet. Der Code liegt unter
[`terraform/`](terraform/) und nutzt den `hashicorp/vault`-Provider, der mit
OpenBao API-kompatibel ist.

Erstes Ziel: Userpass-Auth + Admin-Policy + ein Admin-User, damit der
Initial-Root-Token nach dem Bootstrap weggesperrt werden kann.

Details und Bootstrap-Anleitung: [`terraform/README.md`](terraform/README.md).

## Lizenz

MIT
