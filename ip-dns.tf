resource "yandex_vpc_address" "addr" {
  name      = "nora-pip"
  folder_id = local.folder_id

  external_ipv4_address {
    zone_id = local.subnet_a_zone
  }
}

resource "null_resource" "duckdns_update" {
  triggers = {
    ip     = local.ingress_ip
    domain = var.duckdns_domain
  }

  provisioner "local-exec" {
    command = "curl -s 'https://www.duckdns.org/update?domains=${var.duckdns_domain}&token=${var.duckdns_token}&ip=${local.ingress_ip}'"
  }
}
