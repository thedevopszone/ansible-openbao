resource "vault_policy" "managed" {
  for_each = fileset("${path.module}/policies", "*.hcl")

  name   = trimsuffix(each.value, ".hcl")
  policy = file("${path.module}/policies/${each.value}")
}

moved {
  from = vault_policy.admin
  to   = vault_policy.managed["admin.hcl"]
}
