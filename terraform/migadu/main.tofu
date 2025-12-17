terraform {
  required_providers {
    migadu = {
      source  = "metio/migadu"
      version = "2025.12.11"
    }
  }
}

variable "domain" {
  type = string
}

variable "app" {
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
  local_part  = var.app
  password    = random_password.password.result
}

output "password" {
  sensitive = true
  value = random_password.password.result
}