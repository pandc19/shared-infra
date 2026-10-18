output "reserved_ip" {
  description = "Reserved IP of the droplet; use this as the server IP in Coolify."
  value       = module.shared.reserved_ip
}

output "droplet_id" {
  description = "ID of the droplet."
  value       = module.shared.droplet_id
}

output "coolify_server_settings" {
  description = "Copy-paste values for Servers -> Add in Coolify Cloud."
  value       = <<-EOT

    Name:             ${module.shared.droplet_name}
    IP Address/Domain: ${module.shared.reserved_ip}
    Port:             22
    User:             root
    Private Key:      (select the key you generated in Coolify -> Keys & Tokens)
    Wildcard Domain:  https://${var.base_domain}
    Use as build server: off

    Check before adding:  ssh root@${module.shared.reserved_ip} 'docker --version && swapon --show'
  EOT
}
