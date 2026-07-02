# NORA: Разворачиваем свой artifact registry в Kubernetes на Yandex Cloud за 15 минут

## Введение

Каждый разработчик сталкивался с проблемой хранения артефактов: Docker-образы, npm-пакеты, Maven-артефакты, Python-колёсики. Вариантов обычно два — использовать публичные реестры (Docker Hub, npmjs.org, PyPI) или поднимать Nexus / Artifactory / Harbor. Публичные реестры ненадёжны из-за rate limit и даунтаймов, Nexus и Artifactory тяжёлые: Java, PostgreSQL, гигабайты RAM, десятки минут на старт.

[NORA](https://github.com/getnora-io/nora) — open-source реестр артефактов на Rust. Один бинарник < 27 МБ, < 50 МБ RAM в простое, старт за 3 секунды. Поддерживает 13 форматов: Docker, Maven, npm, PyPI, Cargo, Go, Raw, RubyGems, Terraform, Ansible Galaxy, NuGet, Pub (Dart/Flutter), Conan (C/C++). Плюс Helm-чарты через OCI.

В этой статье мы развернём NORA в Kubernetes на Yandex Managed Kubernetes с помощью Terraform и Helm, настроим ingress-nginx, выпустим TLS-сертификат через cert-manager, а затем попробуем все основные сценарии использования.

## NORA vs Nexus vs Artifactory vs Harbor

| Метрика | NORA | Nexus | JFrog Artifactory | Harbor |
|---------|------|-------|-------------------|--------|
| Размер бинарника | < 27 МБ | 600+ МБ | 1+ ГБ | 1+ ГБ (все компоненты) |
| RAM (простой) | < 50 МБ | 2–4 ГБ | 2–4 ГБ | 2–4 ГБ |
| Время старта | < 3 сек | 30–60 сек | 30–60 сек | 30–60 сек |
| Зависимости | Нет | Java 11+ | Java 11+ | Go, PostgreSQL, Redis |
| База данных | Файловая система | OrientDB/PostgreSQL | OrientDB/PostgreSQL | PostgreSQL |
| Количество форматов | 13 | 30+ | 30+ | Docker, OCI, Helm, CNAB |
| S3-хранилище | Да | Платная версия | Платная версия | Да |
| Цена | MIT, бесплатно | Community бесплатно | Community бесплатно | Apache 2.0, бесплатно |

NORA уступает Nexus/Artifactory/Harbor по количеству поддерживаемых форматов и enterprise-фичам (LDAP, репликация, встроенное сканирование CVE). Но для команд, которым нужен быстрый, лёгкий и бесплатный registry с основными форматами — это отличный выбор.

## Архитектура решения

```
┌─────────────────────────────────────────────────┐
│                 Yandex Cloud                     │
│                                                  │
│  ┌───────────────────────────────────────────┐  │
│  │        Managed Kubernetes (v1.33)         │  │
│  │                                           │  │
│  │   ┌──────────────┐    ┌──────────────┐   │  │
│  │   │ ingress-nginx│    │    NORA       │   │  │
│  │   │  (Controller)│───▶│  (Registry)   │   │  │
│  │   └──────┬───────┘    └──────┬────────┘   │  │
│  │          │                    │             │  │
│  │          │              ┌─────▼──────┐     │  │
│  │          │              │  PVC 10Gi  │     │  │
│  │          │              │  (/data)   │     │  │
│  │          │              └────────────┘     │  │
│  │          │                                │  │
│  │   ┌──────┴───────┐                        │  │
│  │   │ cert-manager │                        │  │
│  │   │ (Let's       │                        │  │
│  │   │  Encrypt)    │                        │  │
│  │   └──────────────┘                        │  │
│  └──────────┼─────────────────────────────────┘  │
│             │                                    │
│    ┌────────▼────────┐                           │
│    │  LoadBalancer    │                           │
│    │  (Public IP)     │                           │
│    └────────┬─────────┘                           │
│             │                                    │
│    ┌────────▼─────────┐                          │
│    │  DNS: nora.      │                          │
│    │  nora-apatsev.   │                          │
│    │  duckdns.org     │                          │
│    └──────────────────┘                          │
└─────────────────────────────────────────────────┘
```

**Компоненты:**
- **VPC + Subnet** — сетевая изоляция в зоне `ru-central1-a`
- **Managed Kubernetes** — кластер K8s v1.33 с auto-scaling нод (1–3)
- **ingress-nginx** — Ingress-контроллер с LoadBalancer и публичным IP
- **cert-manager** — автоматический выпуск и обновление TLS-сертификатов Let's Encrypt
- **NORA** — artifact registry, деплоится через Helm, хранит данные на PVC
- **DNS** — A-запись `nora-apatsev.duckdns.org` (DuckDNS), указывающая на публичный IP

## Инфраструктура: Terraform

Разберём конфиги.

### versions.tf — провайдеры

```hcl
terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = ">= 0.72.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
  }
  required_version = ">= 1.5"
}
```

Используем провайдеры: `yandex-cloud/yandex` для управления ресурсами облака, `hashicorp/helm` для деплоя Helm-чартов, `hashicorp/time` для задержек при создании сервисных аккаунтов, `hashicorp/null` для вызова DuckDNS API.

### net.tf — сеть

```hcl
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
```

Создаём VPC и одну подсеть в зоне `ru-central1-a` с блоком `10.0.1.0/24`.

### ip-dns.tf — публичный IP и DNS

```hcl
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
```

Закрепляем статический публичный IP и обновляем A-запись на DuckDNS. После `terraform apply` домен `nora-apatsev.duckdns.org` будет резолвиться на IP ingress-контроллера.

### k8s.tf — Kubernetes-кластер и ingress-nginx

```hcl
resource "yandex_kubernetes_cluster" "nora" {
  name       = "nora"
  folder_id  = local.folder_id
  network_id = local.network_id

  master {
    version = "1.33"
    zonal {
      zone      = local.subnet_a_zone
      subnet_id = local.subnet_a_id
    }
    public_ip = true
  }

  service_account_id      = yandex_iam_service_account.sa_k8s_editor.id
  node_service_account_id = yandex_iam_service_account.sa_k8s_editor.id
  release_channel         = "STABLE"
}

resource "yandex_kubernetes_node_group" "k8s_node_group_a" {
  name       = "k8s-node-group-a"
  cluster_id = yandex_kubernetes_cluster.nora.id
  version    = "1.33"

  scale_policy {
    auto_scale {
      min     = 1
      max     = 3
      initial = 1
    }
  }

  instance_template {
    platform_id = "standard-v2"

    resources {
      memory = 16
      cores  = 4
    }

    boot_disk {
      type = "network-hdd"
      size = 65
    }

    scheduling_policy {
      preemptible = true
    }
  }
}
```

Managed Kubernetes-кластер v1.33 с одной нод-группой. Auto-scaling от 1 до 3 нод, 4 ядра, 16 ГБ RAM на ноду. Preemptible-инстансы для экономии — для dev/stage это нормально, для production стоит убрать `preemptible = true`.

```hcl
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  chart            = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true

  values = [
    yamlencode({
      controller = {
        service = {
          type           = "LoadBalancer"
          loadBalancerIP = local.ingress_ip
        }
      }
    })
  ]
}
```

Устанавливаем ingress-nginx через Terraform Helm-провайдер. Контроллер получает зарезервированный публичный IP через `loadBalancerIP`.

### Запуск

```bash
# Авторизация в Yandex Cloud
yc init

# Создаём terraform.tfvars на основе примера
cp terraform.tfvars.example terraform.tfvars
# Редактируем: вставляем свой поддомен и токен с duckdns.org
# duckdns_domain = "nora-apatsev"
# duckdns_token  = "ваш-токен-с-duckdns"

# Инициализация Terraform
terraform init

# Просмотр плана
terraform plan

# Применение
terraform apply

# Получение kubeconfig
yc managed-kubernetes cluster get-credentials \
  --id $(terraform output -raw k8s_cluster_id) \
  --external --force
```

Переменные `duckdns_domain` и `duckdns_token` задаются в файле `terraform.tfvars` (добавлен в `.gitignore`, не попадёт в репозиторий). Токен можно получить в личном кабинете на [duckdns.org](https://duckdns.org) после регистрации.

## cert-manager: автоматические TLS-сертификаты

Для работы HTTPS с валидным TLS-сертификатом от Let's Encrypt нужен [cert-manager](https://cert-manager.io/). Он автоматически выпускает и обновляет сертификаты для Ingress-ресурсов.

### Установка cert-manager

```bash
# Добавляем Helm-репозиторий
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Устанавливаем cert-manager с CRDs
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

Проверяем, что поды cert-manager запустились:

```bash
kubectl get pods -n cert-manager
# cert-manager-xxx            1/1     Running
# cert-manager-cainjector-xxx 1/1     Running
# cert-manager-webhook-xxx    1/1     Running
```

### Создаём ClusterIssuer

```bash
cat <<EOF > cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: noreply@duckdns.org
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF

kubectl apply -f cluster-issuer.yaml
```

Проверяем:

```bash
kubectl get clusterissuer letsencrypt-prod
# NAME               READY   AGE
# letsencrypt-prod   True    10s
```

## Аутентификация

По умолчанию NORA работает без аутентификации (анонимный доступ на чтение). Для включения авторизации выполните следующие шаги:

### Шаг 1. Создаём htpasswd-файл

```bash
htpasswd -Bbc users.htpasswd admin your-password
# -B = bcrypt (обязательно для NORA), -b = пароль из аргумента, -c = создать файл
```

### Шаг 2. Создаём Kubernetes Secret

```bash
kubectl create secret generic nora-htpasswd \
  --from-file=users.htpasswd=./users.htpasswd
```

NORA поддерживает три роли: `read` (чтение), `write` (чтение + запись), `admin` (всё + управление токенами). Роли назначаются через токены (см. ниже).

## Деплой NORA через Helm

Инфраструктура готова — кластер работает, ingress-nginx слушает на публичном IP, cert-manager выпустит TLS-сертификат автоматически. Теперь ставим NORA.

### Добавляем Helm-репозиторий

```bash
helm repo add nora https://getnora-io.github.io/helm-charts
helm repo update
```

### Создаём values-файл

```bash
cat <<EOF > helm-values.yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: nora-apatsev.duckdns.org
      paths:
        - path: /
          pathType: Prefix
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls:
    - secretName: nora-tls
      hosts:
        - nora-apatsev.duckdns.org

persistence:
  enabled: true
  size: 10Gi

config:
  server:
    public_url: "https://nora-apatsev.duckdns.org"
  registries:
    enable: "all"
  auth:
    enabled: true
    htpasswd:
      existingSecret: nora-htpasswd
      secretKey: users.htpasswd

resources:
  limits:
    memory: 512Mi
    cpu: "1"
  requests:
    memory: 128Mi
    cpu: "0.25"
EOF
```

Указываем только то, что отличается от дефолтов Nora:
- `config.server.public_url` — внешний URL, который NORA будет вставлять в download-ссылки (обязательно за reverse proxy)
- `config.auth.enabled` — включает аутентификацию по htpasswd
- `config.auth.htpasswd.existingSecret` — ссылка на Kubernetes Secret с htpasswd-файлом (chart сам монтирует его в контейнер)
- `proxy-body-size: "0"` — снимает ограничение на размер тела запроса (нужно для больших Docker-образов)
- `proxy-read-timeout: "600"` — увеличенный таймаут для больших загрузок
- `cert-manager.io/cluster-issuer` — аннотация для автоматического выпуска TLS-сертификата через cert-manager
- `tls` — конфигурация TLS с указанием Secret для сертификата

### Устанавливаем

```bash
helm upgrade --install nora nora/nora --version 0.3.16 -f helm-values.yaml
```

### Проверяем

```bash
# Ждём готовности пода
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=nora --timeout=120s

# Проверяем health
curl https://nora-apatsev.duckdns.org/health

# Открываем Web UI
open https://nora-apatsev.duckdns.org/ui/
```

После этого NORA доступна по адресу `https://nora-apatsev.duckdns.org`. Web UI покажет dashboard с 13 реестрами.

### Создание и использование токенов

NORA использует API-токены с префиксом `nra_` вместо эндпоинта `/auth/token` (который есть в Docker Hub / GHCR, но отсутствует в NORA).

NORA поддерживает три роли: `read` (чтение), `write` (чтение + запись), `admin` (всё + управление токенами).

### Создание и использование токенов

```bash
# Создать токен
curl -X POST https://nora-apatsev.duckdns.org/api/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "username": "admin",
    "password": "your-password",
    "role": "write",
    "ttl_days": 90,
    "description": "CI/CD pipeline token"
  }'
# {"token": "nra_cc40a977a2b147cfa4bde58c2b193b3a...", "expires_in_days": 90}

# проверка токена
curl -H "Authorization: Bearer nra_cc40a977a2b147cfa4bde58c2b193b3a" \
  https://nora-apatsev.duckdns.org/v2/_catalog

# Использовать токен для npm
npm config set //nora-apatsev.duckdns.org:_authToken nra_cc40a977a2b147cfa4bde58c2b193b3a

# Docker login с токеном (токен в качестве пароля, любое имя пользователя)
docker login nora-apatsev.duckdns.org -u token -p nra_cc40a977a2b147cfa4bde58c2b193b3a
```

## Использование: примеры для каждого формата

### Docker

```bash
# Берём готовый публичный образ (или собираем свой из Dockerfile)
docker pull nginx:alpine

# Пушим образ
docker tag nginx:alpine nora-apatsev.duckdns.org/myapp:1.0
docker push nora-apatsev.duckdns.org/myapp:1.0

# Пуллим образ из NORA
docker pull nora-apatsev.duckdns.org/myapp:1.0
```

NORA полностью совместима с Docker Registry v2 API, поэтому все стандартные команды `docker` работают без изменений.

### npm

```bash
# Настройка реестра для проекта
npm config set registry https://nora-apatsev.duckdns.org/npm/

# Установка пакета (NORA проксирует запрос в npmjs.org и кэширует)
npm install lodash

```

#### Тестирование npm publish

Чтобы проверить публикацию, можно создать минимальный тестовый пакет (директория `test-npm-pkg` уже есть в репозитории):

```bash
cd test-npm-pkg

npm config set //nora-apatsev.duckdns.org/npm/:_authToken nra_cc40a977a2b147cfa4bde58c2b193b3a

# Публикуем (запускается из директории test-npm-pkg)
npm publish --registry https://nora-apatsev.duckdns.org/npm/

# Проверяем установку
cd .. && mkdir test-install && cd test-install
npm init -y
npm install @test/hello-world --registry https://nora-apatsev.duckdns.org/npm/
node -e "const hello = require('@test/hello-world'); console.log(hello());"
```

Содержимое тестового пакета:

```
test-npm-pkg/
├── package.json   # имя: @test/hello-world, версия: 1.0.0
└── index.js       # module.exports = function hello() { return "Hello from Nora registry!"; }
```

Или через `.npmrc` в проекте:

```
registry=https://nora-apatsev.duckdns.org/npm/
```

Scoped-пакеты тоже работают:

```bash
npm install @babel/core --registry https://nora-apatsev.duckdns.org/npm/
```

### PyPI

```bash
# Создаём и активируем виртуальное окружение
python3 -m venv .venv
source .venv/bin/activate

# Установка пакета через NORA (с токеном)
pip install --index-url https://token:nra_cc40a977a2b147cfa4bde58c2b193b3a@nora-apatsev.duckdns.org/simple/ flask
```

Пример минимального Python-пакета для публикации (директория `python-pkg-example` уже есть в репозитории):

```
python-pkg-example/
├── pyproject.toml
├── src/
│   └── python_pkg_example/
│       └── __init__.py
└── dist/                # создаётся автоматически при python -m build
```

```bash
cd python-pkg-example
python3 -m venv .venv
source .venv/bin/activate
pip install build twine
python -m build
twine upload --repository-url https://token:nra_cc40a977a2b147cfa4bde58c2b193b3a@nora-apatsev.duckdns.org/simple/ dist/*
```

Для постоянной настройки создайте `~/.pip/pip.conf`:

```ini
[global]
index-url = https://nora-apatsev.duckdns.org/simple/
```

NORA поддерживает PEP 503 (HTML) и PEP 691 (JSON) — современные клиенты pip автоматически выбирают JSON API.

### Maven

Пример минимального Maven-пакета для публикации (директория `test-maven-pkg` уже есть в репозитории):

```
test-maven-pkg/
├── pom.xml
├── settings.xml
└── src/main/java/com/example/HelloNora.java
```

Создайте `pom.xml` с описанием артефакта и адресом репозитория:

```bash
cat <<'EOF' > test-maven-pkg/pom.xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <groupId>com.example</groupId>
    <artifactId>hello-nora</artifactId>
    <version>1.0.0</version>
    <packaging>jar</packaging>

    <name>hello-nora</name>
    <description>Minimal Maven package for NORA registry test</description>

    <properties>
        <maven.compiler.source>11</maven.compiler.source>
        <maven.compiler.target>11</maven.compiler.target>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    </properties>

    <distributionManagement>
        <repository>
            <id>nora</id>
            <name>NORA Maven Repository</name>
            <url>https://nora-apatsev.duckdns.org/maven2</url>
        </repository>
    </distributionManagement>
</project>
EOF
```

Создайте `settings.xml` с учётными данными для аутентификации:

```bash
cat <<EOF > test-maven-pkg/settings.xml
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
    <servers>
        <server>
            <id>nora</id>
            <username>admin</username>
            <password>your-password</password>
        </server>
    </servers>
</settings>
EOF
```

Создайте исходный файл:

```bash
mkdir -p test-maven-pkg/src/main/java/com/example
cat <<'EOF' > test-maven-pkg/src/main/java/com/example/HelloNora.java
package com.example;

public class HelloNora {
    public static String greet() {
        return "Hello from NORA!";
    }

    public static void main(String[] args) {
        System.out.println(greet());
    }
}
EOF
```

Публикация артефакта:

```bash
cd test-maven-pkg
mvn deploy -s settings.xml
```

### Helm OCI

Helm-чарты хранятся через Docker/OCI endpoint. Для тестирования создайте и запакуйте чарт (директория `test-helm-pkg` уже есть в репозитории):

```bash
# Создаём чарт (если ещё нет)
cd test-helm-pkg
helm create mychart

# Запаковываем в .tgz
helm package mychart

# Публикация чарта
helm push mychart-0.1.0.tgz oci://nora-apatsev.duckdns.org/helm

# Скачивание чарта
helm pull oci://nora-apatsev.duckdns.org/helm/mychart --version 0.1.0

# Установка чарта из NORA
helm install myrelease oci://nora-apatsev.duckdns.org/helm/mychart --version 0.1.0
```

### Go modules

Настройте Go proxy:

```bash
export GOPROXY=https://nora-apatsev.duckdns.org/go,direct

go get golang.org/x/text@latest
```

Или в `go env`:

```bash
go env -w GOPROXY=https://nora-apatsev.duckdns.org/go,direct
```

Go-модули иммутабельны после первой загрузки — NORA кэширует `.info`, `.mod`, `.zip` навсегда.

### Cargo (Rust)

В `~/.cargo/config.toml`:

```toml
[registries.nora]
index = "sparse+https://nora-apatsev.duckdns.org/cargo/"

[source.crates-io]
replace-with = "nora"
```

```bash
cargo build  # зависимости теперь тянутся через NORA
cargo publish --registry nora
```

NORA реализует Cargo sparse index (RFC 2789) — не нужно хранить git-репозиторий индекса.

### Terraform

В файле `~/.terraformrc`:

```hcl
provider_installation {
  network_mirror {
    url = "https://nora-apatsev.duckdns.org/terraform/"
  }
}
```

После этого все `terraform init` будут скачивать провайдеры через NORA:

```bash
terraform init
# Provider hashicorp/aws will be downloaded from nora-apatsev.duckdns.org
```

### RubyGems

```bash
bundle config mirror.https://rubygems.org https://nora-apatsev.duckdns.org/gems/
bundle install
```

### NuGet (.NET)

```bash
dotnet nuget add source https://nora-apatsev.duckdns.org/nuget/v3/index.json -n nora
dotnet restore
```

### Ansible Galaxy

```bash
ansible-galaxy collection install community.general \
  -s https://nora-apatsev.duckdns.org/ansible/
```

### Conan (C/C++)

```bash
conan remote add nora https://nora-apatsev.duckdns.org/conan
conan install zlib/1.3.1@ --remote=nora
```

### Pub (Dart/Flutter)

```bash
export PUB_HOSTED_URL=https://nora-apatsev.duckdns.org/pub
dart pub get
```

## Air-gapped: работа в изолированных средах

NORA имеет встроенную утилиту `nora mirror` для предварительного кэширования зависимостей. Это критично для сред без доступа в интернет.

### Кэширование по lockfile

```bash
# npm — по package-lock.json
nora mirror npm --lockfile package-lock.json \
  --registry https://nora-apatsev.duckdns.org

# pip — по requirements.txt
nora mirror pip --requirement requirements.txt \
  --registry https://nora-apatsev.duckdns.org

# Cargo — по Cargo.lock
nora mirror cargo --lockfile Cargo.lock \
  --registry https://nora-apatsev.duckdns.org

# Maven — по pom.xml
nora mirror maven --pom pom.xml \
  --registry https://nora-apatsev.duckdns.org
```

### Кэширование Docker-образов

```bash
nora mirror docker \
  --images "nginx:latest,redis:7,node:20-alpine,python:3.12" \
  --registry https://nora-apatsev.duckdns.org
```

### Работа в air-gapped среде

После зеркалирования NORA работает полностью автономно — все зависимости отдаются из локального кэша, обращений к внешним реестрам нет.

## Мониторинг

NORA отдаёт метрики в формате Prometheus по эндпоинту `/metrics`.

### Проверка здоровья

```bash
# Общий health check
curl https://nora-apatsev.duckdns.org/health

# Readiness probe
curl https://nora-apatsev.duckdns.org/ready
```

### Prometheus

Добавьте NORA в `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'nora'
    scrape_interval: 15s
    static_configs:
      - targets: ['nora-apatsev.duckdns.org:443']
    scheme: https
    metrics_path: /metrics
```

### Grafana

NORA предоставляет метрики:
- `nora_requests_total` — количество запросов по реестрам
- `nora_request_duration_seconds` — latency
- `nora_storage_bytes` — объём хранилища
- `nora_artifacts_total` — количество артефактов

### Эндпоинты

| URL | Описание |
|-----|----------|
| `/ui/` | Web UI (dashboard, поиск, просмотр) |
| `/health` | Проверка здоровья |
| `/ready` | Readiness probe |
| `/metrics` | Метрики Prometheus |
| `/api-docs` | Swagger/OpenAPI |

## Бэкап и восстановление

NORA хранит все данные на файловой системе (PVC в Kubernetes). Бэкап — это копирование данных.

### Через CLI NORA

```bash
# Бэкап
nora backup --output /data/nora-backup.tar.gz

# Восстановление
nora restore --input /data/nora-backup.tar.gz
```

### Через kubectl (Volume Snapshot)

```bash
# Создание snapshot PVC
kubectl get pvc -n default
# NAME           STATUS   VOLUME   CAPACITY
# nora-data      Bound    pvc-xxx  10Gi

# Через VolumeSnapshotClass
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: nora-snapshot
spec:
  volumeSnapshotClassName: yc-csi-snapclass
  source:
    persistentVolumeClaimName: nora-data
EOF
```

### Через rsync

Самый простой способ для файловой системы:

```bash
kubectl exec deploy/nora -- tar czf - /data | \
  ssh user@backup-server "cat > /backups/nora-$(date +%Y%m%d).tar.gz"
```

## Trouleshooting

### 1. NORA не стартует / под в CrashLoopBackOff

```bash
kubectl logs deploy/nora
kubectl describe pod -l app.kubernetes.io/name=nora
```

Проверьте, что PVC создан и подключён: `kubectl get pvc`.

### 2. TLS-сертификат не выпускается (NET::ERR_CERT_AUTHORITY_INVALID)

**Симптом:** браузер показывает «Ваше подключение не защищено» / `NET::ERR_CERT_AUTHORITY_INVALID`.

**Причина:** cert-manager ещё не выпустил сертификат или Challenge не прошёл.

```bash
kubectl get certificates
kubectl describe certificate nora-tls
kubectl get challenges
kubectl describe challenge
kubectl get orders
kubectl describe order
```

**Решения:**
- Подождать 1–5 минут — Let's Encrypt ACME HTTP-01 challenge требует времени
- Проверить, что ClusterIssuer в статусе Ready: `kubectl get clusterissuer letsencrypt-prod`
- Проверить логи cert-manager: `kubectl logs -n cert-manager deploy/cert-manager`
- Убедиться, что DNS-запись `nora-apatsev.duckdns.org` резолвится на правильный IP ingress-контроллера:
  ```bash
  dig nora-apatsev.duckdns.org +short
  kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
  ```
- Если cert-manager не может достучаться до `/.well-known/acme-challenge/` — проверить, что ingress-nginx работает и нет конфликтов Ingress-правил

### 3. Docker push / pull не работает

```bash
# Проверяем, что NORA отвечает
curl https://nora-apatsev.duckdns.org/v2/

# Проверяем ingress
kubectl get ingress
kubectl describe ingress nora
```

Убедитесь, что `proxy-body-size` не ограничивает размер образа (в values стоит `"0"` — без ограничения).

### 4. cert-manager: как это работает

1. Ingress-nginx создаётся с аннотацией `cert-manager.io/cluster-issuer`
2. cert-manager видит аннотацию и создаёт Certificate-ресурс
3. Certificate → CertificateRequest → Order → Challenge
4. Let's Encrypt проверяет доступ к `/.well-known/acme-challenge/` через ingress-nginx
5. cert-manager получает сертификат и сохраняет его в Secret `nora-tls`
6. ingress-nginx использует этот Secret для TLS-терминации

## Заключение

NORA — это современная альтернатива Nexus, Artifactory и Harbor для команд, которым не нужен enterprise-overhead. Ключевые преимущества:

- **Простота** — один бинарник, один конфиг, одна PVC. `cp -r /data/ backup/` — полный бэкап.
- **Производительность** — < 3 секунды на старт, < 50 МБ RAM. Rust, Tokio, Axum.
- **13 форматов** — Docker, Maven, npm, PyPI, Cargo, Go, Raw, RubyGems, Terraform, Ansible, NuGet, Pub, Conan.
- **Безопасность** — OpenSSF Scorecard, подписанные релизы, SBOM, 1200+ тестов.
- **Air-gapped ready** — встроенное зеркалирование для изолированных сред.

Репозиторий с Terraform-кодом для этой статьи: [github.com/patsevanton/nora-habr](https://github.com/patsevanton/nora-habr)

- GitHub: [github.com/getnora-io/nora](https://github.com/getnora-io/nora)
- Документация: [getnora.dev](https://getnora.dev)
- Telegram: [t.me/getnora](https://t.me/getnora)
- Artifact Hub: [artifacthub.io/packages/helm/nora/nora](https://artifacthub.io/packages/helm/nora/nora)
