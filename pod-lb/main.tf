terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.74.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

variable "project_id" {
  description = "project id"
}

variable "region_east" {
  description = "region for first cluster"
}

variable "region_west" {
  description = "region for second cluster"
}

variable "cf_account_id" {
  description = "cloudflare account id"
}

variable "cf_zone_id" {
  description = "cloudflare zone id"
}

variable "cf_api_key" {
  description = "cloudflare global api key (how to use limited token?)"
}

provider "google" {
  project = var.project_id
}

provider "cloudflare" {
  email   = "alexeldeib@gmail.com"
  api_key = var.cf_api_key
}

# Must be 32 character random string to be used as a secret for creating the
# tunnel's access token
# https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/tunnel#secret
resource "random_password" "tunnel_secret" {
  length  = 32
  special = true
}

# VPC
resource "google_compute_network" "vpc-east" {
  name                    = "${var.project_id}-east"
  auto_create_subnetworks = "false"
}

# Subnet
resource "google_compute_subnetwork" "subnet-east" {
  name          = "${var.project_id}-subnet-east"
  region        = var.region_east
  network       = google_compute_network.vpc-east.name
  ip_cidr_range = "10.0.0.0/16"
}

# VPC
resource "google_compute_network" "vpc-west" {
  name                    = "${var.project_id}-west"
  auto_create_subnetworks = "false"
}

# Subnet
resource "google_compute_subnetwork" "subnet-west" {
  name          = "${var.project_id}-subnet-west"
  region        = var.region_west
  network       = google_compute_network.vpc-west.name
  ip_cidr_range = "10.0.0.0/16"
}

data "google_container_engine_versions" "gke_version" {
  location = var.region_east
  version_prefix = "1.27."
}

resource "google_container_cluster" "east" {
  name     = "${var.project_id}-east"
  location = var.region_east

  initial_node_count       = 1

  network    = google_compute_network.vpc-east.name
  subnetwork = google_compute_subnetwork.subnet-east.name

  node_config {
    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  timeouts {
    create = "30m"
    update = "40m"
  }

}

resource "google_container_cluster" "west" {
  name     = "${var.project_id}-west"
  location = var.region_west

  initial_node_count       = 1

  network    = google_compute_network.vpc-west.name
  subnetwork = google_compute_subnetwork.subnet-west.name

  node_config {
    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  timeouts {
    create = "30m"
    update = "40m"
  }
}

# Create a tunnel for the jump server
resource "cloudflare_tunnel" "envoy_tunnel_9898" {
  account_id = var.cf_account_id
  name       = "envoy_tunnel_9898"
  secret     = base64encode(random_password.tunnel_secret.result)
}

# Proxy from the cloudflared tunnel to the server
resource "cloudflare_tunnel_config" "envoy_tunnel_9898" {
  account_id = var.cf_account_id
  tunnel_id  = cloudflare_tunnel.envoy_tunnel_9898.id

  config {
    ingress_rule {
      service = "http://podinfo.test.svc.cluster.local:9898"
    }
  }
}

resource "cloudflare_record" "envoy_9898" {
  zone_id = var.cf_zone_id
  name    = "envoy_9898"
  value   = cloudflare_tunnel.envoy_tunnel_9898.cname
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

output "tunnel_token_9898" {
  value = cloudflare_tunnel.envoy_tunnel_9898.tunnel_token
  sensitive = true
}

# Create a tunnel for the jump server
resource "cloudflare_tunnel" "envoy_tunnel_9999" {
  account_id = var.cf_account_id
  name       = "envoy_tunnel_9999"
  secret     = base64encode(random_password.tunnel_secret.result)
}

# Proxy from the cloudflared tunnel to the server
resource "cloudflare_tunnel_config" "envoy_tunnel_9999" {
  account_id = var.cf_account_id
  tunnel_id  = cloudflare_tunnel.envoy_tunnel_9999.id

  config {
    ingress_rule {
      service = "http://podinfo.test.svc.cluster.local:9999"
    }
  }
}

resource "cloudflare_record" "envoy_9999" {
  zone_id = var.cf_zone_id
  name    = "envoy_9999"
  value   = cloudflare_tunnel.envoy_tunnel_9999.cname
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

output "tunnel_token_9999" {
  value = cloudflare_tunnel.envoy_tunnel_9999.tunnel_token
  sensitive = true
}
