output "userpass_login_path" {
  description = "Pfad zum Userpass-Login (für CLI: bao login -method=userpass)."
  value       = "auth/${vault_auth_backend.userpass.path}/login"
}

output "managed_users" {
  description = "Per Terraform verwaltete Userpass-Usernames."
  value       = keys(var.users)
}
