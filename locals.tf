data "yandex_client_config" "client" {}

locals {
  folder_id     = var.folder_id != "" ? var.folder_id : data.yandex_client_config.client.folder_id
  network_id    = yandex_vpc_network.nora.id
  subnet_a_id   = yandex_vpc_subnet.nora-a.id
  subnet_a_zone = yandex_vpc_subnet.nora-a.zone
  ingress_ip    = yandex_vpc_address.addr.external_ipv4_address[0].address
  duckdns_fqdn  = "${var.duckdns_domain}.duckdns.org"
}
