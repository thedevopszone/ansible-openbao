# Ansible Role: openbao

Installiert OpenBao auf Ubuntu/Debian per offiziellem `.deb` aus dem GitHub-Release.
Es gibt aktuell kein offizielles APT-Repo — die Rolle lädt das `.deb` direkt von
`https://github.com/openbao/openbao/releases/`.

## Variablen

| Variable | Default | Beschreibung |
| --- | --- | --- |
| `openbao_version` | `2.5.3` | Zu installierende Version (entspricht dem Release-Tag ohne `v`) |
| `openbao_service_enabled` | `true` | systemd-Unit aktivieren |
| `openbao_service_state` | `started` | gewünschter systemd-Zustand |
| `openbao_arch_map` | `{x86_64: amd64, aarch64: arm64}` | Mapping von `ansible_architecture` auf die Architektur im Dateinamen |

## Was das Paket mitbringt

- Systemd-Unit: `openbao.service` (User/Group `openbao`)
- Konfig: `/etc/openbao/openbao.hcl` — UI an, file-Storage unter `/opt/openbao/data`,
  HTTPS-Listener auf `0.0.0.0:8200`
- TLS: selbst-signiert, automatisch im `postinst` erzeugt unter
  `/opt/openbao/tls/{tls.crt,tls.key}` (Gültigkeit 3 Jahre)
- Env-File: `/etc/openbao/openbao.env`

Die Rolle template-t `openbao.hcl` **nicht** — die Default-Config bleibt erhalten.

## Nach der Installation

OpenBao läuft danach `sealed` und nicht initialisiert. Einmaliger Init-Schritt
auf der VM:

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
    - openbao
```
