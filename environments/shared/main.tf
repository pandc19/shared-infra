terraform {
  required_version = ">= 1.7"
  required_providers {
    digitalocean = { source = "digitalocean/digitalocean", version = "~> 2.40" }
    cloudflare   = { source = "cloudflare/cloudflare", version = "~> 4.0" }
    http         = { source = "hashicorp/http", version = "~> 3.4" }
  }
}

provider "digitalocean" {
  token = var.do_token
}

provider "cloudflare" {
  api_token = var.cloudflare_token
}

# A second environment can be added later as environments/<name>/ with its own
# backend key and a different name/ssh_key_name.
module "shared" {
  source = "../../modules/droplet"

  name                        = "shared-apps-1"
  ssh_key_name                = "shared-apps-coolify"
  region                      = var.region
  droplet_size                = var.droplet_size
  coolify_ssh_public_key      = var.coolify_ssh_public_key
  restrict_http_to_cloudflare = var.restrict_http_to_cloudflare
  project_name                = var.project_name
  cloudflare_zone_id          = var.cloudflare_zone_id
  base_domain                 = var.base_domain
}
