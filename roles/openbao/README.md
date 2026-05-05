# Ansible Role: openbao

Installiert [OpenBao](https://openbao.org/) auf Ubuntu/Debian per offiziellem
`.deb` aus dem GitHub-Release. Es gibt aktuell kein offizielles APT-Repo — die
Rolle lädt das `.deb` direkt von `https://github.com/openbao/openbao/releases/`.

## Anforderungen

- Ubuntu 22.04 / 24.04 oder Debian 12
- Architektur `amd64` oder `arm64`
- `become: true` (Paketinstallation und systemd)
- Internetzugriff vom Zielhost auf `github.com` zum Download des `.deb`

## Variablen

| Variable | Default | Beschreibung |
| --- | --- | --- |
| `openbao_version` | `2.5.3` | Zu installierende Version (entspricht dem Release-Tag ohne `v`) |
| `openbao_service_enabled` | `true` | systemd-Unit beim Boot aktivieren |
| `openbao_service_state` | `started` | gewünschter systemd-Zustand (`started`, `stopped`, …) |
| `openbao_arch_map` | `{x86_64: amd64, aarch64: arm64}` | Mapping von `ansible_architecture` auf die Architektur im Release-Dateinamen |
| `openbao_deb_url` | abgeleitet | Vollständige Download-URL des `.deb`. Selten zu überschreiben |
| `openbao_deb_dest` | `/tmp/openbao_<version>_linux_<arch>.deb` | Lokaler Pfad während des Downloads |
| `openbao_config_path` | `/etc/openbao/openbao.hcl` | Pfad der Hauptkonfig (für blockinfile-Eingriffe) |
| `openbao_audit_enabled` | `true` | File-Audit-Device über `openbao.hcl` aktivieren |
| `openbao_audit_log_path` | `/opt/openbao/audit.log` | Zielpfad des Audit-Logs (Verzeichnis muss vom `openbao`-User schreibbar sein) |
| `openbao_ha_enabled` | `false` | Schaltet den HA-Pfad ein: Raft-Storage, eigene Mini-CA, getemplete `openbao.hcl`. Wenn `false` bleibt das Single-Node-Verhalten unverändert |
| `openbao_ha_group` | `openbao_ha_servers` | Inventory-Gruppe der HA-Peers (Hosts dieser Gruppe werden gegenseitig als `retry_join` und SAN eingetragen) |
| `openbao_data_path` | `/opt/openbao/data` | Datenverzeichnis (für Raft-Storage) |
| `openbao_tls_dir` | `/opt/openbao/tls` | Zielpfad der TLS-Dateien (`ca.crt`, `tls.crt`, `tls.key`) auf dem Host |
| `openbao_api_port` | `8200` | API-/UI-Port |
| `openbao_cluster_port` | `8201` | Raft-Cluster-Port |
| `openbao_ca_local_dir` | `<repo>/.openbao-ca` | Pfad auf der Control-Node, in dem CA-Key + CA-Cert + Per-Host-Keys/Certs liegen — gitignored, persistent über Runs |
| `openbao_ca_cn` | `OpenBao HA CA` | CN der CA |
| `openbao_ca_validity_days` | `3650` | CA-Cert-Laufzeit |
| `openbao_cert_validity_days` | `1095` | Per-Host-Cert-Laufzeit |
| `openbao_extra_san_ips` | abgeleitet | Liste zusätzlicher IP-SANs pro Host (Default: alle Cluster-IPs aus `openbao_ha_group`) |
| `openbao_extra_san_dns` | `[localhost]` | Liste zusätzlicher DNS-SANs pro Host |

## Was die Rolle tut

1. Prüft, ob die Architektur unterstützt ist (`amd64` / `arm64`).
2. Installiert die Pakete `openssl` und `ca-certificates`.
3. Liest die aktuell installierte OpenBao-Version (`dpkg-query`).
4. Lädt das `.deb` nur, wenn die installierte Version von `openbao_version` abweicht.
5. Installiert das `.deb` (idempotent — kein Re-Install bei gleicher Version).
6. Räumt das `.deb` aus `/tmp` weg.
7. Aktiviert und startet `openbao.service`.

Bei einer Versionsänderung wird der Service via Handler neu gestartet.

## Was die Rolle NICHT tut

- Sie ersetzt **nicht** die komplette `openbao.hcl`. Die vom Paket gelieferte
  Default-Config (UI an, HTTPS-Listener auf `0.0.0.0:8200`, file-Storage,
  selbst-signiertes TLS aus dem `postinst`) bleibt erhalten. Die Rolle hängt
  lediglich einen markierten Block für das Audit-Device per `blockinfile` an.
- Sie initialisiert OpenBao **nicht** (`bao operator init`) und entsiegelt es
  nicht (`bao operator unseal`). Beides ist ein bewusst manueller Schritt.
- Sie verwaltet keine Auth-Methoden, Policies, Secrets-Engines o.ä. — diese
  Post-Install-Konfiguration läuft über Terraform (siehe
  [`../../terraform/`](../../terraform/)).

## Audit-Logging

OpenBao 2.x verbietet das Aktivieren von Audit-Devices via API (Härtung gegen
kompromittierte Root-Tokens). Die Rolle hängt daher einen `audit "file"`-Block
direkt in `openbao.hcl` ein. Verifizieren auf der VM:

```bash
sudo tail -f /opt/openbao/audit.log
bao audit list
```

Ein Audit-Device, das nicht schreiben kann, **blockiert sämtliche Requests** —
also Schreibrechte und Plattenplatz im Auge behalten. Logrotation einrichten
(z.B. `logrotate.d/openbao` mit `copytruncate`) — diese Rolle setzt das nicht
auf.

## Was das Paket mitbringt

- systemd-Unit: `openbao.service` (User/Group `openbao`)
- Konfig: `/etc/openbao/openbao.hcl` — UI an, file-Storage unter `/opt/openbao/data`,
  HTTPS-Listener auf `0.0.0.0:8200`
- TLS: selbst-signiert, im `postinst` erzeugt unter
  `/opt/openbao/tls/{tls.crt,tls.key}` (Gültigkeit 3 Jahre)
- Env-File: `/etc/openbao/openbao.env`

## Nach der Installation

OpenBao läuft `sealed` und nicht initialisiert. Einmaliger Init-Schritt auf der VM:

```bash
ssh ubuntu@<host>
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true   # selbst-signiertes Zertifikat
bao operator init
bao operator unseal <key 1>
bao operator unseal <key 2>
bao operator unseal <key 3>
```

Die ausgegebenen Unseal-Keys und den Initial-Root-Token sicher verwahren.

## Beispiel-Playbook

```yaml
- hosts: openbao_servers
  become: true
  roles:
    - role: openbao
      vars:
        openbao_version: "2.5.3"
```

## HA-Modus (3-Node Raft-Cluster)

Wenn `openbao_ha_enabled: true` gesetzt ist, übernimmt die Rolle zusätzlich:

1. Eine **Mini-CA** auf der Control-Node anlegen (`openbao_ca_local_dir`,
   default `<repo>/.openbao-ca/`).
2. Pro Host ein **Server-Cert** mit SANs für die eigene IP, alle Peer-IPs aus
   `openbao_ha_group`, `127.0.0.1` und `localhost` ausstellen und mit der CA
   signieren.
3. `ca.crt`, `tls.crt`, `tls.key` nach `{{ openbao_tls_dir }}` auf dem Host
   ausrollen (Owner `openbao`).
4. Eine vollständige **HA-`openbao.hcl`** rendern mit
   - `storage "raft"` (Daten unter `openbao_data_path`)
   - `node_id = inventory_hostname`
   - `retry_join`-Block für jeden Host der Gruppe
   - `listener "tcp"` mit dem signierten Cert
   - Audit-Block (wenn `openbao_audit_enabled`)

Init und Unseal sind weiterhin manuell — siehe Repo-`README.md`, Abschnitt
„HA-Deployment".

## Lizenz

MIT
