terraform {
  required_providers {
    migadu = {
      source  = "metio/migadu"
      version = "2026.9.3"
    }
  }
}

variable "domain" {
  type = string
}

variable "identity" {
  type = string
}

variable "name" {
  type = string
}

resource "random_password" "password" {
  length = 64
}

resource "migadu_mailbox" "mailbox" {
  name        = var.name
  domain_name = var.domain
  local_part  = var.identity
  password    = random_password.password.result
  may_send    = true
}

locals {
	address = "${var.identity}@${var.domain}"
}

output "host" {
  value = "smtp.migadu.com"
}

output "address" {
  value = local.address
}

output "from" {
  sensitive = true
  value = "${var.name} <${local.address}>"
}

output "password" {
  sensitive = true
  value = random_password.password.result
}
