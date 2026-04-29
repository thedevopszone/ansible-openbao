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

## Lizenz

MIT
