resource "vault_audit" "file" {
  type        = "file"
  description = "File-based audit log for forensics and compliance"

  options = {
    file_path = var.audit_log_path
    log_raw   = "false"
    hmac_accessor = "true"
  }
}
