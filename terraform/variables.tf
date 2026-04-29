variable "vault_addr" {
  description = "Adresse der OpenBao-Instanz."
  type        = string
  default     = "https://172.16.0.107:8200"
}

variable "vault_token" {
  description = "Token für die Provider-Authentifizierung. Leer lassen, um VAULT_TOKEN aus der Umgebung zu nutzen."
  type        = string
  sensitive   = true
  default     = null
}

variable "skip_tls_verify" {
  description = "TLS-Verifikation überspringen (nötig für selbst-signiertes Cert aus dem .deb-Default)."
  type        = bool
  default     = true
}

variable "users" {
  description = "Userpass-Benutzer mit zugewiesenen Policies. Passwörter werden im Resource-Body als sensitive behandelt; Benutzernamen sind nicht-sensitiv (sie tauchen als Resource-Keys im State auf)."
  type = map(object({
    password = string
    policies = list(string)
  }))
}

variable "database_connections" {
  description = "Datenbank-Verbindungen für die database secret engine. plugin_name z.B. 'postgresql-database-plugin' oder 'mysql-database-plugin'. Aktuell unterstützt: postgres, mysql."
  type = map(object({
    plugin_name    = string
    connection_url = string
    username       = string
    password       = string
    allowed_roles  = list(string)
  }))
  default = {}
}

variable "database_roles" {
  description = "Rollen für dynamische DB-Credentials. db_connection muss auf einen Key in database_connections verweisen."
  type = map(object({
    db_connection         = string
    creation_statements   = list(string)
    revocation_statements = optional(list(string), [])
    default_ttl           = optional(number, 3600)
    max_ttl               = optional(number, 86400)
  }))
  default = {}
}

variable "approles" {
  description = "AppRoles für Maschinen-Logins (Apps, CI/CD). TTLs in Sekunden. secret_id_num_uses = 0 ⇒ unbegrenzt."
  type = map(object({
    policies           = list(string)
    token_ttl          = optional(number, 3600)
    token_max_ttl      = optional(number, 14400)
    secret_id_ttl      = optional(number, 86400)
    secret_id_num_uses = optional(number, 0)
    bind_secret_id     = optional(bool, true)
  }))
  default = {}
}
