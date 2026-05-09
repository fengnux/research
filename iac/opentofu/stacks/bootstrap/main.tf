terraform {
  required_providers {
    google = {
      source  = "registry.opentofu.org/hashicorp/google"
      version = "~> 6.0"
    }
  }
  # Bootstrap 使用 local state（避免雞生蛋問題）
}

provider "google" {
  project = var.project
  region  = var.region
}

resource "google_storage_bucket" "tofu_state" {
  name                        = var.state_bucket_name
  project                     = var.project
  location                    = var.region
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 10
    }
    action {
      type = "Delete"
    }
  }
}
