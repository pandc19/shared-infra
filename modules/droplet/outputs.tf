output "reserved_ip" {
  description = "Reserved IP of the droplet. Stable across droplet replacement."
  value       = digitalocean_reserved_ip.this.ip_address
}

output "droplet_id" {
  description = "ID of the droplet."
  value       = digitalocean_droplet.this.id
}

output "droplet_name" {
  description = "Name of the droplet."
  value       = digitalocean_droplet.this.name
}

output "wildcard_record" {
  description = "Hostname of the wildcard DNS record."
  value       = cloudflare_record.wildcard.name
}
