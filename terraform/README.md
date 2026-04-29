# Terraform: OpenBao-Konfiguration

Verwaltet Auth-Methoden, Policies und User *innerhalb* einer bereits laufenden
OpenBao-Instanz. Voraussetzung: OpenBao ist via Ansible installiert,
initialisiert (`bao operator init`) und entsiegelt.

## Was wird angelegt

- **Auth-Backend** `userpass` — Login per Username/Passwort statt Root-Token.
- **Policy** `admin` — volle Rechte (Ersatz für den Root-Token im Alltag).
- **User** gemäß `var.users` (in `terraform.tfvars`).

## Voraussetzungen

- Terraform ≥ 1.5
- Erreichbarkeit zur OpenBao-Instanz (`https://<host>:8200`)
- Initial-Root-Token aus `bao operator init`

## Erstmalige Anwendung

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Passwort und ggf. weitere User in terraform.tfvars eintragen

export VAULT_ADDR=https://172.16.0.107:8200
export VAULT_TOKEN=<initial-root-token>

terraform init
terraform plan
terraform apply
```

Danach in der GUI (`https://172.16.0.107:8200/ui`) die Auth-Methode
**Username** wählen und mit dem in `terraform.tfvars` definierten User einloggen.

Wenn der Login funktioniert, kann der Root-Token sicher weggesperrt werden
(z.B. in einem Passwort-Manager oder Offline-Tresor) und ist nur noch für
Recovery-Fälle nötig.

## Variablen

| Variable | Default | Beschreibung |
| --- | --- | --- |
| `vault_addr` | `https://172.16.0.107:8200` | Adresse der OpenBao-Instanz |
| `vault_token` | `null` | Provider-Token. `null` ⇒ `VAULT_TOKEN` aus Env wird genutzt |
| `skip_tls_verify` | `true` | TLS-Verifikation aus (selbst-signiertes Cert) |
| `users` | — | Map `username → { password, policies }` |

## Hinweise

- **`terraform.tfvars` enthält Klartext-Passwörter** und ist `.gitignore`d.
- **`terraform.tfstate` enthält Secrets** (Provider-Token, gerendete User-Bodies)
  und ist `.gitignore`d. Die Datei niemals einchecken.
- Die Lock-Datei `.terraform.lock.hcl` **wird committed** — sorgt für
  reproduzierbare Provider-Versionen.
- Passwortrotation: Wert in `terraform.tfvars` ändern, `terraform apply`.
- User entfernen: aus `var.users` löschen, `terraform apply`.

## Out of Scope

- Auto-Unseal (KMS/Transit) — Unseal bleibt manuell auf der VM
- Secret-Engines (KV v2 etc.) — werden hier später ergänzt, wenn Apps Secrets brauchen
- Remote-State-Backend — derzeit lokaler State
