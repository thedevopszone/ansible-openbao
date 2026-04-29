resource "vault_auth_backend" "userpass" {
  type        = "userpass"
  description = "Username/password auth for human operators"
}
