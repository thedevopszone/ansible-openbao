resource "vault_auth_backend" "approle" {
  type        = "approle"
  description = "AppRole auth for machine/CI/CD logins"
}

resource "vault_approle_auth_backend_role" "managed" {
  for_each = var.approles

  depends_on = [vault_policy.managed]

  backend            = vault_auth_backend.approle.path
  role_name          = each.key
  token_policies     = each.value.policies
  token_ttl          = each.value.token_ttl
  token_max_ttl      = each.value.token_max_ttl
  secret_id_ttl      = each.value.secret_id_ttl
  secret_id_num_uses = each.value.secret_id_num_uses
  bind_secret_id     = each.value.bind_secret_id
}
