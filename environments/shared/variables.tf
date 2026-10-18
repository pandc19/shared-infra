variable "do_token" {
  description = "DigitalOcean API token (read/write). Set via TF_VAR_do_token; never commit it."
  type        = string
  sensitive   = true
}

variable "cloudflare_token" {
  description = "Cloudflare API token with Zone:DNS:Edit on the zone. Set via TF_VAR_cloudflare_token; never commit it."
  type        = string
  sensitive   = true
}

variable "coolify_ssh_public_key" {
  description = "PUBLIC key generated in Coolify Cloud (Keys & Tokens). Installed as root's authorized key."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID of the zone that contains base_domain."
  type        = string
}

variable "base_domain" {
  description = "Domain in the Cloudflare zone. Apps live under *.<base_domain>."
  type        = string
}

variable "region" {
  description = "DigitalOcean region slug for the droplet and reserved IP."
  type        = string
  default     = "nyc1"
}

variable "droplet_size" {
  description = "Droplet size slug."
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "restrict_http_to_cloudflare" {
  description = "true: 80/443 only from Cloudflare ranges (records must be proxied). false: open 80/443 to all, required for DNS-only records."
  type        = bool
  default     = true
}

variable "project_name" {
  description = "Name of the existing DigitalOcean Project to attach the droplet to (looked up, never created)."
  type        = string
  default     = "Shared Apps"
}
