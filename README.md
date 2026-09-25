# WARP Manager для AmneziaWG

Меню и Telegram-бот для управления Cloudflare WARP поверх **AmneziaWG 2**, установленного через приложение Amnezia (Docker-контейнер `amnezia-awg2`).

```
Клиент → amnezia-awg2 → интерфейс warp → Cloudflare → Интернет
```

Через WARP идут только выбранные клиенты, остальные — напрямую с IP сервера.

---

## Установка

1. Поставь **AmneziaWG (версия 2)** на сервер через приложение Amnezia.
2. На сервере под root:

```
curl -fsSL https://raw.githubusercontent.com/ln71v/WARP/main/warp.sh -o /usr/local/bin/warp && chmod +x /usr/local/bin/warp && warp
```

3. В меню: `1` — установить WARP, `3` — выбрать, кто идёт через WARP.

Дальше меню открывается командой `warp`.

## Меню

| Пункт | Что делает |
|---|---|
| 1 | Установить WARP (wgcf внутрь контейнера) |
| 2 | Статус: связь с Cloudflare, IP сервера и WARP, клиенты |
| 3 | Клиенты WARP: вкл/выкл по одному или всех |
| 4 | Перевыпуск ключа WARP (клиенты остаются как были) |
| 5 | Добавить клиента AmneziaWG — конфиг + QR |
| 6 | Удалить клиента |
| 7 | Переименовать клиента |
| 8 | Telegram-бот: установка, перезапуск, лог, удаление |
| 9 | Удалить WARP (AmneziaWG и клиенты остаются) |

## Telegram-бот

Ставится из меню, пункт 8, за три шага: токен от @BotFather → свой Telegram ID (@userinfobot) → запуск службы `warp-bot`.

Кнопки: статус, клиенты WARP, новый клиент (присылает `.conf` и QR), удалить клиента, перевыпуск ключа. Отвечает только владельцу.

## Где что лежит

| Путь | Что |
|---|---|
| `/usr/local/bin/warp` | сам скрипт |
| `/root/warp-clients/` | конфиги клиентов, созданных скриптом/ботом |
| `/opt/warp-bot/` | бот и его настройки (`bot.env`) |
| в контейнере `/opt/warp/` | профиль WARP |
| в контейнере `/opt/amnezia/start.sh` | блок автозапуска WARP (между метками `WARP-MANAGER`) |

## Для бота / скриптов

```
warp api clients | installed | status | apply IP... | reissue | add ИМЯ | del IP
```

---

Старый скрипт `setup-warp-for-amneziawg.sh` оставлен для истории, новый — `warp.sh`.
