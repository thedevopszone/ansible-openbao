resource "vault_password_policy" "managed" {
  for_each = fileset("${path.module}/password-policies", "*.hcl")

  name   = trimsuffix(each.value, ".hcl")
  policy = file("${path.module}/password-policies/${each.value}")
}
