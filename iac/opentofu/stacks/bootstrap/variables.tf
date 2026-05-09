variable "project" {
  description = "GCP project ID"
  type        = string
  default     = "research-lab"
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "asia-east1"
}

variable "state_bucket_name" {
  description = "Name of the GCS bucket for OpenTofu state"
  type        = string
  default     = "research-lab-tofu-state"
}
