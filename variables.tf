variable "folder_id" {
  description = "Yandex Cloud folder ID (optional; defaults to client config)"
  type        = string
  default     = ""
}

variable "duckdns_domain" {
  description = "DuckDNS subdomain (e.g. nora-habr)"
  type        = string
}

variable "duckdns_token" {
  description = "DuckDNS account token"
  type        = string
  sensitive   = true
}
