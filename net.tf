resource "yandex_vpc_network" "nora" {
  name      = "nora-vpc"
  folder_id = local.folder_id
}

resource "yandex_vpc_subnet" "nora-a" {
  folder_id      = local.folder_id
  v4_cidr_blocks = ["10.0.1.0/24"]
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.nora.id
}
