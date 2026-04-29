output "userpass_login_path" {
  description = "Pfad zum Userpass-Login (für CLI: bao login -method=userpass)."
  value       = "auth/${vault_auth_backend.userpass.path}/login"
}

output "managed_users" {
  description = "Per Terraform verwaltete Userpass-Usernames."
  value       = keys(var.users)
}

output "approle_role_ids" {
  description = "Role-IDs aller verwalteten AppRoles. Allein nicht ausreichend zum Login — zusätzlich wird eine Secret-ID benötigt (siehe README)."
  value = {
    for name, role in vault_approle_auth_backend_role.managed : name => role.role_id
  }
}
