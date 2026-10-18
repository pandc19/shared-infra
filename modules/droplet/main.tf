terraform {
  required_providers {
    digitalocean = { source = "digitalocean/digitalocean" }
    cloudflare   = { source = "cloudflare/cloudflare" }
    http         = { source = "hashicorp/http" }
  }
}

# Holds ONLY the public half of the key Coolify Cloud generated. Terraform never
# generates keys: a tls_private_key would write the private key into state.
# DigitalOcean installs this key into root's authorized_keys at first boot, which is
# what Coolify connects with (it SSHes as root).
resource "digitalocean_ssh_key" "coolify" {
  name       = var.ssh_key_name
  public_key = trimspace(var.coolify_ssh_public_key)
}

resource "digitalocean_droplet" "this" {
  name     = var.name
  region   = var.region
  size     = var.droplet_size
  image    = var.image_slug
  ssh_keys = [digitalocean_ssh_key.coolify.id]

  # Explicit false, overriding the provider's default of true: growing the disk can
  # never be undone, so a temporary size bump would permanently ratchet up cost.
  # false keeps resizes to CPU/RAM only, reversible in both directions.
  resize_disk = false

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    swap_size = var.swap_size
  })

  # This box holds Postgres and every app's volumes. user_data and ssh_keys are
  # ForceNew, so without this an innocent cloud-init tweak or key edit in a PR would
  # plan to DESTROY AND RECREATE the droplet (and its data). Ignoring them makes such
  # edits a no-op on the existing box. To deliberately rebuild, see
  # DESTROY_AND_REBUILD.md (terraform apply -replace=...).
  lifecycle {
    ignore_changes = [user_data, ssh_keys]
  }
}

# Free-standing reserved IP + separate assignment (not droplet_id inline), so that
# replacing the droplet only touches the assignment: the IP, and therefore DNS and the
# server entry in Coolify, never changes. Free while assigned to a droplet.
resource "digitalocean_reserved_ip" "this" {
  region = var.region

  # droplet_id is Optional, not Computed, and is populated by the assignment resource
  # below. Ignoring it stops the two resources fighting over the same field.
  lifecycle {
    ignore_changes = [droplet_id]
  }
}

resource "digitalocean_reserved_ip_assignment" "this" {
  ip_address = digitalocean_reserved_ip.this.ip_address
  droplet_id = digitalocean_droplet.this.id
}

# Cloudflare's published IPv4 ranges, fetched live so the firewall can't go stale.
data "http" "cloudflare_ipv4" {
  url = "https://www.cloudflare.com/ips-v4"
}

locals {
  cloudflare_ipv4_ranges = compact(split("\n", data.http.cloudflare_ipv4.response_body))

  # Sources allowed on 80/443. Open to everyone when restrict_http_to_cloudflare = false.
  http_sources = var.restrict_http_to_cloudflare ? local.cloudflare_ipv4_ranges : ["0.0.0.0/0", "::/0"]
}

resource "digitalocean_firewall" "this" {
  name        = "${var.name}-fw"
  droplet_ids = [digitalocean_droplet.this.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = local.http_sources
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = local.http_sources
  }

  # SSH open to the internet, deliberately: Coolify Cloud connects from IPs we don't
  # control. Defense is layered in cloud-init instead: key-only auth, root allowed by
  # key only, AllowUsers root, MaxAuthTries 3, LoginGraceTime 30, and fail2ban.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0"]
  }

  # Both protocols outbound: TCP alone would break DNS (UDP/53), which apt and
  # docker pull depend on.
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# Looked up, never created: the project is a permanent external grouping. The droplet
# API has no project argument, so project_resources is how the droplet gets moved out
# of the account's Default project.
data "digitalocean_project" "this" {
  name = var.project_name
}

resource "digitalocean_project_resources" "this" {
  project = data.digitalocean_project.this.id
  resources = [
    digitalocean_droplet.this.urn,
    digitalocean_reserved_ip.this.urn,
  ]
}

# Wildcard for every app Coolify deploys (<name>.<base_domain>). Explicit records in the
# zone (www, api, MX...) still take precedence over the wildcard. Points at the reserved IP, not the droplet's
# own address, so a droplet replacement never moves it.
# Needs Cloudflare SSL mode "Full (strict)" - see SETUP.md.
resource "cloudflare_record" "wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = "*.${var.base_domain}"
  type    = "A"
  content = digitalocean_reserved_ip.this.ip_address
  proxied = true
  ttl     = 1 # must be 1 ("automatic") when proxied = true
}
