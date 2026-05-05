# Terraform: OpenBao-Konfiguration

Verwaltet Auth-Methoden, Policies und User *innerhalb* einer bereits laufenden
OpenBao-Instanz. Voraussetzung: OpenBao ist via Ansible installiert,
initialisiert (`bao operator init`) und entsiegelt.

## Was wird angelegt

- **Auth-Backend** `userpass` — Login per Username/Passwort statt Root-Token.
- **ACL-Policies** — alle `*.hcl`-Dateien aus [`policies/`](policies/) werden
  automatisch als gleichnamige Policies (ohne `.hcl`) angelegt.
- **Password-Policies** — alle `*.hcl`-Dateien aus
  [`password-policies/`](password-policies/) werden als gleichnamige
  Password-Policies angelegt (genutzt von Secret-Engines wie DB/AppRole zur
  automatischen Passwortgenerierung).
- **User** gemäß `var.users` (in `terraform.tfvars`).
- **AppRoles** gemäß `var.approles` — Maschinen-Logins für CI/CD und Apps
  (Role-ID + Secret-ID statt Token).
- **Datenbank-Secret-Engine** gemäß `var.database_connections` und
  `var.database_roles` — dynamische, kurzlebige DB-Credentials.

> **Audit-Logging** wird *nicht* über Terraform verwaltet — OpenBao 2.x
> verbietet das Aktivieren von Audit-Devices via API (Härtung). Stattdessen
> wird das Audit-Device deklarativ in `openbao.hcl` definiert und über die
> Ansible-Rolle ausgerollt. Siehe [`../roles/openbao/`](../roles/openbao/).

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

## Mehrere Cluster verwalten (Workspaces)

Wenn du sowohl den Single-Node (`172.16.0.107`) als auch den HA-Cluster
(`172.16.0.143`) gleichzeitig mit Terraform pflegen willst, nutzen wir
**Terraform-Workspaces** — eine Codebase, getrennter State pro Cluster.

| Workspace | Ziel | Var-File | TLS-Verifikation |
| --- | --- | --- | --- |
| `default` | Single-Node `https://172.16.0.107:8200` | `terraform.tfvars` | aus (`skip_tls_verify=true`) |
| `ha` | HA-Cluster `https://172.16.0.143:8200` | `ha.tfvars` | an, gegen `../.openbao-ca/ca.crt` |

Der State liegt für `default` weiter in `terraform.tfstate`, für `ha` in
`terraform.tfstate.d/ha/terraform.tfstate` — Workspace-Mechanik von
Terraform, automatisch.

### Setup HA-Workspace

`make`-Targets werden aus dem **Repo-Root** aufgerufen, nicht aus
`terraform/`.

```bash
# tfvars im terraform/-Verzeichnis anlegen:
cp terraform/ha.tfvars.example terraform/ha.tfvars
# Passwort und ggf. weitere User in terraform/ha.tfvars eintragen

# zurück ins Repo-Root für die Make-Targets:
export VAULT_TOKEN=<root-token-vom-HA-cluster>
make tf-init                       # einmalig (initialisiert Provider)
make tf-plan  CLUSTER=ha           # erzeugt Workspace `ha`, plant gegen HA
make tf-apply CLUSTER=ha
```

`make tf-{plan,apply,destroy} CLUSTER=ha` setzt automatisch:

- `terraform workspace select -or-create ha`
- `-var-file=ha.tfvars`
- `VAULT_CACERT=$REPO_ROOT/.openbao-ca/ca.crt` (damit der `hashicorp/vault`-Provider
  das selbst-signierte Cluster-Cert verifizieren kann)

Ohne `CLUSTER=ha` ist `CLUSTER=single` Default → Workspace `default`,
`terraform.tfvars`, kein `VAULT_CACERT` (Single-Node läuft mit
`skip_tls_verify=true`). Bestehender Workflow bleibt unverändert.

### Workspace-Status prüfen

```bash
(cd terraform && terraform workspace list)   # zeigt aktive Workspaces (* = aktuell)
(cd terraform && terraform workspace show)   # nur den aktuellen Namen
```

### Bewusste Trennung

- `terraform.tfvars` und `ha.tfvars` sind beide gitignored — keine
  Cluster-Konfig im Git.
- Auch die Resource-Namen kollidieren nicht: jede Workspace hat ihren
  eigenen State, also können beide Cluster z.B. denselben User
  `thomas` mit unterschiedlichen Passwörtern haben.
- Output-Namen wie `approle_role_ids` sind workspace-lokal:
  `terraform output` gibt die Werte des aktuell gewählten Workspaces aus.

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
| `approles` | `{}` | Map `role_name → { policies, token_ttl, ... }` für AppRole-Maschinen-Logins |
| `database_connections` | `{}` | DB-Verbindungen (Plugin, URL, Privileged-User) |
| `database_roles` | `{}` | Rollen für dynamische DB-Credentials (Creation-SQL, TTLs) |

## Policies

Eine Policy = eine `.hcl`-Datei in [`policies/`](policies/). Der Dateiname
(ohne `.hcl`) wird zum Policy-Namen. Aktuell mitgeliefert:

| Datei | Name | Zweck |
| --- | --- | --- |
| `policies/admin.hcl` | `admin` | Vollzugriff inkl. `sudo` — Ersatz für den Root-Token im Alltag |
| `policies/read-only.hcl` | `read-only` | `read`/`list` auf allen Pfaden — für Monitoring, Troubleshooting |

**Neue Policy hinzufügen:** `.hcl`-Datei in `policies/` ablegen,
`make tf-apply` — fertig. Kein Eintrag in `policies.tf` nötig.

## Password-Policies

Vorlage für serverseitig generierte Passwörter (z.B. dynamische DB-Credentials,
AppRole-Secret-IDs). Funktioniert nach dem gleichen Prinzip wie ACL-Policies:
eine `.hcl`-Datei pro Policy in [`password-policies/`](password-policies/).

| Datei | Name | Eigenschaften |
| --- | --- | --- |
| `password-policies/strong.hcl` | `strong` | 24 Zeichen, mind. 2 aus jeder Gruppe (lower, upper, digit, special) |

**Test:**
```bash
bao read sys/policies/password/strong/generate
```

**Verwendung in einer DB-Secret-Engine:**
```bash
bao write database/roles/my-app password_policy=strong ...
```

**Policy einem User zuweisen:** in `terraform.tfvars` unter `users.<name>.policies`
auflisten:
```hcl
users = {
  thomas = { password = "...", policies = ["admin"] }
  ops    = { password = "...", policies = ["read-only"] }
}
```

## AppRoles

AppRole ist der Standard-Mechanismus, mit dem sich Maschinen (Apps, CI/CD)
gegenüber OpenBao authentifizieren — anstelle eines fest konfigurierten Tokens.
Login erfordert zwei Werte:

- **Role-ID**: nicht geheim; wird beim `apply` erzeugt und ist als Output verfügbar.
- **Secret-ID**: geheim; wird **nicht** über Terraform erzeugt (würde sonst dauerhaft
  im State liegen). Stattdessen on-demand über die CLI oder API.

### Eine Secret-ID ausstellen

```bash
bao write -force auth/approle/role/<role_name>/secret-id
```

Output enthält `secret_id` und `secret_id_accessor`. Die `secret_id` einmalig
übergeben (z.B. an die CI als Geheimnis), den Accessor zur späteren Revokation
notieren.

### Login mit Role-ID + Secret-ID

```bash
ROLE_ID=$(terraform -chdir=terraform output -raw approle_role_ids | jq -r .ci-runner)
SECRET_ID=...   # aus dem Schritt oben
bao write auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID"
```

### Response-Wrapping (empfohlen für Übergabe an Maschinen)

```bash
bao write -wrap-ttl=10m -force auth/approle/role/<role_name>/secret-id
# liefert einen wrapping_token, mit dem die Maschine die Secret-ID einmalig abholt
```

### Variablen-Beispiel

```hcl
approles = {
  ci-runner = {
    policies      = ["read-only"]
    token_ttl     = 3600       # 1h
    token_max_ttl = 14400      # 4h
    secret_id_ttl = 86400      # Secret-IDs gelten 24h ab Erstellung
  }
}
```

## Datenbank-Secret-Engine

Stellt **dynamische, kurzlebige DB-Credentials** für Apps/CI aus. Statt fixer
Anwendungs-User legt OpenBao bei jedem Login einen frischen User mit TTL an
und löscht ihn am Ende der Lebenszeit.

### Voraussetzungen

- Erreichbare DB (Postgres, MySQL — weitere Plugins können `database.tf` ergänzt werden).
- Auf der DB existiert ein **Privileged-User** (z.B. `vault_admin`), der
  Rollen/User anlegen und löschen darf. **Beispiel Postgres:**
  ```sql
  CREATE ROLE vault_admin WITH LOGIN PASSWORD '...' CREATEROLE;
  GRANT CONNECT ON DATABASE app TO vault_admin;
  ```

### Connection + Role definieren

In `terraform.tfvars`:

```hcl
database_connections = {
  app-postgres = {
    plugin_name    = "postgresql-database-plugin"
    connection_url = "postgresql://{{username}}:{{password}}@db.internal:5432/app?sslmode=disable"
    username       = "vault_admin"
    password       = "..."
    allowed_roles  = ["app-readonly"]
  }
}

database_roles = {
  app-readonly = {
    db_connection = "app-postgres"
    creation_statements = [
      "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
      "GRANT CONNECT ON DATABASE app TO \"{{name}}\";",
      "GRANT USAGE ON SCHEMA public TO \"{{name}}\";",
      "GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
    ]
    default_ttl = 3600
    max_ttl     = 86400
  }
}
```

### Credentials abrufen

```bash
bao read database/creds/app-readonly
# Key                Value
# ---                -----
# lease_id           database/creds/app-readonly/abc...
# username           v-token-app-readonly-xyz123
# password           K9$xV2#p...
```

User existiert auf der DB nur für die Lease-Dauer (`default_ttl`), maximal `max_ttl`.

### Hinweise

- **Keine Anwendungs-Logik im Code, die User-Namen rät** — der Username ist
  zufällig und ändert sich pro Lease.
- **Connection-Passwort liegt im Terraform-State** — State entsprechend behandeln.
- **Privileged-User periodisch rotieren**: `bao write -force database/rotate-root/<connection_name>` —
  danach kennt nur noch OpenBao das Passwort. **Achtung:** danach ist es nicht
  mehr aus dem `terraform.tfvars` rekonstruierbar; bei einem späteren
  `terraform apply` würde Terraform versuchen, das alte Passwort zurückzuschreiben.
  Daher Rotation nur, wenn die Connection-Verwaltung danach **außerhalb** von
  Terraform passiert (oder die Variable in tfvars synchron aktualisiert wird).

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
