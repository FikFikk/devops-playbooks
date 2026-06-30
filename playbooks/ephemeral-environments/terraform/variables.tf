variable "dns_provider" {
  description = "DNS provider (aws, gcp, cloudflare, etc)"
  type        = string
  default     = "cloudflare"
}

variable "preview_domain" {
  description = "Base domain untuk preview environments"
  type        = string
  default     = "preview.yourapp.com"
}

variable "acme_email" {
  description = "Email untuk Let's Encrypt certificates"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository (format: owner/repo)"
  type        = string
}
