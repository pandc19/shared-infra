variable "name" {
  description = "Droplet name. Also used as the prefix of the firewall name (<name>-fw)."
  type        = string
}

variable "ssh_key_name" {
  description = "Name of the digitalocean_ssh_key resource that holds the Coolify public key."
  type        = string
}

variable "region" {
  description = "DigitalOcean region slug for the droplet and the reserved IP (e.g. nyc1)."
  type        = string
}

variable "droplet_size" {
  description = "Droplet size slug."
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "image_slug" {
  description = "Base image slug. Must stay Ubuntu 24.04: cloud-init uses the 'noble' Docker apt suite and Ubuntu's ssh service name."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "coolify_ssh_public_key" {
  description = "PUBLIC key generated in Coolify Cloud (Keys & Tokens). Installed as root's authorized key. Never put a private key here."
  type        = string

  validation {
    condition     = can(regex("^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp[0-9]+) ", trimspace(var.coolify_ssh_public_key)))
    error_message = "coolify_ssh_public_key must be a single-line OpenSSH PUBLIC key (ssh-ed25519 ..., ssh-rsa ..., ecdsa-sha2-...). Never paste a private key."
  }
}

variable "swap_size" {
  description = "Size of the swap file, as accepted by fallocate -l."
  type        = string
  default     = "2G"
}

variable "restrict_http_to_cloudflare" {
  description = "true: ports 80/443 only accept Cloudflare's IPv4 ranges (all DNS records must be proxied). false: 80/443 open to the world (needed for DNS-only records)."
  type        = bool
  default     = true
}

variable "project_name" {
  description = "Name of an EXISTING DigitalOcean Project. It is looked up, never created."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID of the zone that contains base_domain."
  type        = string
}

variable "base_domain" {
  description = "Domain in the Cloudflare zone (e.g. example.com). Apps live under *.<base_domain>."
  type        = string
}
