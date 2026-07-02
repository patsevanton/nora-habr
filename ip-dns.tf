resource "yandex_vpc_address" "addr" {
  name      = "nora-pip"
  folder_id = local.folder_id

  external_ipv4_address {
    zone_id = local.subnet_a_zone
  }
}

resource "yandex_dns_zone" "zone" {
  name      = "nora-dns-zone"
  folder_id = local.folder_id
  zone      = "apatsev.org.ru."
  public    = true
}

resource "yandex_dns_recordset" "nora" {
  zone_id = yandex_dns_zone.zone.id
  name    = "nora.apatsev.org.ru."
  type    = "A"
  ttl     = 200
  data    = [local.ingress_ip]
}
