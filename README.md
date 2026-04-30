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
