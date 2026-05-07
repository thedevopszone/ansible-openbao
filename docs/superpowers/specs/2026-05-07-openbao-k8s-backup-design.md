# OpenBao K8s Raft-Snapshot Backup — Design

**Datum:** 2026-05-07
**Status:** Approved, ready for implementation plan
**Ziel-Cluster:** `hetzner` (Helm-deployed OpenBao im Namespace `openbao`)

## Zusammenfassung

Zweites Backup-Playbook neben dem bestehenden `playbooks/backup-openbao.yml` (SSH-Pfad
für die VM-HA-Installation). Das neue Playbook zieht einen Raft-Snapshot aus dem
Helm-deployed OpenBao-Cluster auf Hetzner K8s und legt ihn lokal auf dem Control-Node
ab. Es läuft via `kubectl`-Context (kein SSH, kein Inventory-Eintrag für die Pods).

Das bestehende SSH-Playbook und das `make backup`-Target bleiben unverändert.

## Design-Entscheidungen

### Eigenes Playbook statt Modus-Switch

Neue Datei `playbooks/backup-openbao-k8s.yml`. Das Connection-Modell unterscheidet
sich fundamental vom SSH-Pfad (`hosts: localhost`, kein `become`, kein Inventory,
`kubernetes.core`-Module statt `command`+`fetch`). Ein einzelnes Playbook mit
Verzweigung über alle Tasks würde unleserlich. Beide Pfade bleiben kurz und
gespiegelt: snapshot → transfer → cleanup.

### Pod-Auswahl: fester Default, override per Variable

Default `openbao-0`, override per `openbao_k8s_pod`. Keine Auto-Leader-Discovery
— `bao operator raft snapshot save` routet intern zum Leader, sofern der
angesprochene Pod unsealed und ready ist. Wenn `openbao-0` sealed ist, gibt der
User per CLI einen anderen Pod an.

### Snapshot-Transport: Tempfile + `kubectl cp` (binary-safe)

Drei-Task-Pipeline:

1. `kubernetes.core.k8s_exec` → `bao operator raft snapshot save /tmp/<file>` im Pod
2. `command: kubectl -n <ns> cp <pod>:/tmp/<file> <local_path>` — binary-safe via tar
3. `kubernetes.core.k8s_exec` → `rm /tmp/<file>` (Cleanup)

**Verworfen: Stdout-Capture (`bao ... save -`).** `kubernetes.core.k8s_exec` gibt
`stdout` als String zurück, geht von UTF-8 aus. Ein Raft-Snapshot ist eine binäre
gzip-komprimierte Tar-Datei — Nicht-UTF-8-Bytes können beim Round-Trip durch
Ansibles String-Handling korrumpiert werden. Tempfile + `kubectl cp` umgeht das
komplett (kubectl streamt via tar).

### Token-Quelle: `VAULT_TOKEN` env, identisch zum SSH-Pfad

Konsistent mit dem ganzen Repo (Terraform, Makefile, SSH-Playbook). Keine
Sonderlogik, kein Lookup aus K8s-Secrets.

### Variablen und Defaults

| Variable | Default | Zweck |
| --- | --- | --- |
| `openbao_token` | `lookup('env','VAULT_TOKEN')` | Token mit `sudo`/Snapshot-Capability |
| `openbao_k8s_namespace` | `openbao` | K8s-Namespace |
| `openbao_k8s_pod` | `openbao-0` | Pod, gegen den `bao` läuft |
| `openbao_k8s_addr` | `https://127.0.0.1:8200` | `VAULT_ADDR` im Pod |
| `openbao_k8s_cacert` | `/openbao/userconfig/openbao-server-tls/ca.crt` | `VAULT_CACERT` im Pod (Mount aus `values-hetzner.yaml`) |
| `openbao_backup_local_dir` | `{{ playbook_dir }}/../backups` | Lokales Zielverzeichnis (mode `0700`) |

### Lokale Datei-Konvention

`./backups/openbao-<pod>-<YYYYMMDDTHHMMSS>.snap` — analog zum SSH-Playbook
(dort `openbao-<inventory_hostname>-<ts>.snap`). Keine Rotation; off-site Copy
bleibt dem User überlassen (gleicher Stand wie SSH-Pfad).

### Makefile-Integration

Neues Target `k8s-backup`, gespiegelt zu den anderen `k8s-*`-Targets:

```make
k8s-backup: check-kctx check-token
	ansible-playbook playbooks/backup-openbao-k8s.yml
```

`check-kctx` erzwingt `kubectl current-context == hetzner`. `check-token`
erzwingt gesetztes `VAULT_TOKEN`. Help-Zeile in `Makefile` analog zu
`k8s-status`/`k8s-install` ergänzen.

### Collection-Dependency

`requirements.yml` um `kubernetes.core` ergänzen. Im Repo bisher nicht
verwendet, ist aber das Standard-Modul für `k8s_exec` und im Helm-Pfad ohnehin
sinnvoll für künftige Erweiterungen.

## Vorbedingungen zur Laufzeit

- `kubectl current-context` zeigt auf `hetzner` (über `make k8s-backup` durch
  `check-kctx` erzwungen).
- Ziel-Pod ist `Ready` und unsealed (sonst schlägt `bao operator raft snapshot
  save` fehl mit klarer Fehlermeldung — kein eigener Pre-Check nötig).
- Cluster hat Raft-Quorum (Snapshot benötigt aktiven Leader).
- `VAULT_TOKEN` exportiert.

## Out-of-Scope

- Rotation, off-site Copy, Verschlüsselung des Snapshots — wie beim SSH-Pfad.
- Restore-Pfad (`bao operator raft snapshot restore`) — separates Playbook,
  separater Spec.
- Auto-Discovery des Leaders.
- Pre-Check auf Seal-Status / Cluster-Health.
- Änderungen am bestehenden SSH-Playbook oder `make backup`-Target.

## Dateien (geplant)

- **Neu:** `playbooks/backup-openbao-k8s.yml`
- **Geändert:** `requirements.yml` (`kubernetes.core` ergänzen)
- **Geändert:** `Makefile` (Target `k8s-backup` + Help-Zeile)
