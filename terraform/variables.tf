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

variable "audit_log_path" {
  description = "Pfad der Audit-Log-Datei auf dem OpenBao-Server. Verzeichnis muss vom openbao-User schreibbar sein."
  type        = string
  default     = "/opt/openbao/audit.log"
}

variable "users" {
  description = "Userpass-Benutzer mit zugewiesenen Policies. Passwörter werden im Resource-Body als sensitive behandelt; Benutzernamen sind nicht-sensitiv (sie tauchen als Resource-Keys im State auf)."
  type = map(object({
    password = string
    policies = list(string)
  }))
}
