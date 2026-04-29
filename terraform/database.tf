resource "vault_mount" "database" {
  count = length(var.database_connections) > 0 ? 1 : 0

  path        = "database"
  type        = "database"
  description = "Dynamic database credentials"
}

resource "vault_database_secret_backend_connection" "managed" {
  for_each = var.database_connections

  backend       = vault_mount.database[0].path
  name          = each.key
  plugin_name   = each.value.plugin_name
  allowed_roles = each.value.allowed_roles

  dynamic "postgresql" {
    for_each = each.value.plugin_name == "postgresql-database-plugin" ? [1] : []
    content {
      connection_url = each.value.connection_url
      username       = each.value.username
      password       = sensitive(each.value.password)
    }
  }

  dynamic "mysql" {
    for_each = each.value.plugin_name == "mysql-database-plugin" ? [1] : []
    content {
      connection_url = each.value.connection_url
      username       = each.value.username
      password       = sensitive(each.value.password)
    }
  }
}

resource "vault_database_secret_backend_role" "managed" {
  for_each = var.database_roles

  depends_on = [vault_database_secret_backend_connection.managed]

  backend = vault_mount.database[0].path
  name    = each.key
  db_name = each.value.db_connection

  creation_statements   = each.value.creation_statements
  revocation_statements = each.value.revocation_statements

  default_ttl = each.value.default_ttl
  max_ttl     = each.value.max_ttl
}
