# gatygo

[English](README.md) · **Русский**

VPN-клиент для OpenWrt 25.12. Берёт подписку Xray-JSON, запускает xray с выбранным профилем и
пускает всю LAN через туннель (nftables tproxy). Управление — одна страница в LuCI.

## Возможности

- Обновление подписки по расписанию. Каждый конфиг проверяется `xray run -test`, при ошибке
  остаётся рабочий.
- Профили кнопками со временем отклика (TCP connect до самого быстрого сервера).
- Проверка, открываются ли популярные сервисы через туннель.
- DNS из LAN идёт через xray, трафик самого роутера не трогается, IPv6 из LAN в интернет
  блокируется. При остановке всё возвращается.
- Маршрутизация, балансировщик и geo-файлы только из подписки, своих правил нет.
- Лимит соединений против OOM: 600 на устройство, 1000 всего (Advanced → Settings).
- Если xray упал: без интернета (по умолчанию) или напрямую.
- Понятные ошибки: подписка истекла, лимит устройств, сервер не узнал клиента.

## Требования

- OpenWrt 25.12 (apk, firewall4).
- ~40 МБ на overlay (ядро xray 35 МБ).
- 256 МБ ОЗУ.
- Подписка, отдающая Xray-JSON. Если панель фильтрует по User-Agent, задайте его в
  Advanced → Settings.

## Установка

```sh
wget -qO- https://raw.githubusercontent.com/id-filatov/gatygo/main/install.sh | sh
```

Скрипт проверяет роутер (версию OpenWrt, конфликтующие прокси-пакеты, зависимости в фидах,
место, dnsmasq, сборку xray под архитектуру) и при любой ошибке ничего не ставит. Затем ставит
последний релиз и ядро xray. Сервис не включает.

- `--version <тег>` — конкретный релиз; `install.sh gatygo-*.apk luci-app-gatygo-*.apk` —
  локальные файлы.
- В самосборном образе обычно нет kmod-фида: добавьте в образ
  `kmod-nft-tproxy kmod-nft-connlimit jq curl ca-bundle unzip ip-full`.
- Вручную: оба `.apk` из [релизов](https://github.com/id-filatov/gatygo/releases/latest), затем
  `apk add --allow-untrusted gatygo-*.apk luci-app-gatygo-*.apk`.

Дальше: LuCI → **Services → gatygo**, вставить ссылку, **Connect**.

- Обновить: запустить скрипт ещё раз, настройки сохраняются.
- Убрать подписку: **Delete** в Advanced → Settings или `gatygo forget`.
- Удалить: `apk del luci-app-gatygo gatygo`; `/etc/gatygo` и `/etc/config/gatygo` остаются.

## Ядро xray

Не `xray-core` из фида. Релиз gatygo закрепляет версию
[Xray-core](https://github.com/XTLS/Xray-core) и SHA256 архивов (`gatygo/files/lib/core.pin`).
Роутер качает архив под свою архитектуру, сверяет хеш и только потом распаковывает и запускает.
Ядро обновляется только вместе с gatygo.

## Командная строка

```
gatygo start|stop|restart        управление сервисом
gatygo connect <url>             сохранить ссылку, включить и запустить
gatygo forget                    удалить подписку и сбросить настройки
gatygo update                    обновить подписку
gatygo select <profile>          переключить профиль
gatygo status                    JSON: состояние, профиль, подписка, последний результат
gatygo check [fresh]             JSON: доступность сервисов через туннель
gatygo ping [kept]               JSON: отклик профилей
gatygo nodes                     JSON: outbound'ы, выбор балансировщика, трафик
gatygo log [N]                   последние N строк лога xray и gatygo
```

Настройки — `/etc/config/gatygo`, состояние — `/etc/gatygo`, логи — `logread -e gatygo`,
`logread -e xray`.

## Порты

- 12345 tproxy, 5353 DNS — трафик LAN.
- 10085 API xray, 10808 SOCKS для проверки сервисов — только `127.0.0.1`, SOCKS под паролем
  (`/etc/gatygo`, 0600).
- Ссылка на подписку, user id и HWID в лог не пишутся.

## Разработка

```sh
tests/run.sh                     # юнит-тесты в Docker (busybox ash, jq, закреплённый xray)
tests/run.sh test_core.sh        # один файл
tools/build-apk.sh               # сборка обоих .apk в OpenWrt SDK
tests/vm/run.sh [gatygo.apk]     # e2e на VM с OpenWrt
tools/pin-core.sh v26.9.9        # закрепить другую версию xray
tools/release.sh                 # релиз из main, пакеты собирает CI
```

POSIX sh под busybox ash. Тестовые фикстуры синтетические.

## Лицензия

MIT
