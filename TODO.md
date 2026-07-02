# TODO

- [x] Проверить, нужны ли провайдеры `null` и `local` — провайдер `null` нужен (используется в `ip-dns.tf` для `null_resource`), провайдер `local` удалён и не используется
- [x] Убрать default значения из helm-values.yaml, которые совпадают с дефолтами контейнера Nora
- [x] Аутентификация ВКЛЮЧЕНА — `NORA_AUTH_ENABLED=true` + htpasswd secret в helm-values.yaml
