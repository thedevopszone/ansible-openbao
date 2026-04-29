resource "vault_generic_endpoint" "user" {
  for_each = var.users

  depends_on = [
    vault_auth_backend.userpass,
    vault_policy.managed,
  ]

  path                 = "auth/userpass/users/${each.key}"
  ignore_absent_fields = true

  data_json = jsonencode({
    password = sensitive(each.value.password)
    policies = each.value.policies
  })
}
