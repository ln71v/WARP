# WARP Manager для AmneziaWG

Скрипт для управления туннелированием трафика клиентов из Docker-контейнеров **AmneziaWG** во внешний туннель **Cloudflare WARP**.

Позволяет направлять трафик как всех клиентов сразу, так и выборочно (*per-client*) через таблицу маршрутизации `table 100` и `iptables MASQUERADE`.

---

## Возможности

* **Установка Cloudflare WARP** (`wgcf`) напрямую внутрь контейнера AmneziaWG.
* **Гибкая маршрутизация**: переключение туннеля для всех клиентов сразу или выборочно по отдельным IP.
* **Чтение нативных имён клиентов** из `/opt/amnezia/awg/clientsTable` по их `PublicKey`.
* **Ручное переименование** клиентов (сохраняется в `/opt/amnezia/client_names.txt`).
* **Перевыпуск ключей/аккаунта WARP** в один клик без сброса настроек маршрутизации клиентов.
* **Автозапуск**: сохранение активных правил в `/opt/amnezia/start.sh` внутри контейнера.
* **Мониторинг**: статус handshake с Cloudflare и проверка состояния Docker-контейнеров.

---

## Требования

* Linux-сервер (Ubuntu / Debian / др.) с установленным **Docker**.
* Запущенный контейнер с AmneziaWG (имя контейнера должно начинаться с `amnezia-awg`).
* Права суперпользователя (`root`).

---

## Быстрый запуск

Выполните команду на хосте от имени `root`:

```bash
curl -sSL [https://raw.githubusercontent.com/ln71v/WARP/main/setup-warp-for-amneziawg.sh](https://raw.githubusercontent.com/ln71v/WARP/main/setup-warp-for-amneziawg.sh) -o warp.sh && chmod +x warp.sh && ./warp.sh
