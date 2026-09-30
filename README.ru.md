# gatygo

[English](README.md) · **Русский**

VPN-клиент для OpenWrt 25.12. Берёт подписку Xray-JSON, запускает xray с выбранным профилем и
пускает всю LAN через туннель (nftables tproxy).

> [!WARNING]
> Бета-версия: возможны ошибки, поведение и настройки могут меняться между релизами.
> Если xray упадёт, по умолчанию дом остаётся без интернета, пока VPN не поднимется или не будет выключен
> (меняется в Advanced → Settings).
> ПО предоставляется «как есть», без гарантий. Об ошибках — в [Issues](https://github.com/id-filatov/gatygo/issues).

## Возможности

- Обновление подписки по расписанию. Каждый конфиг проверяется `xray run -test`, при ошибке
  остаётся рабочий.
- DNS из LAN идёт через xray, трафик самого роутера не трогается.
- Маршрутизация, балансировщик и geo-файлы только из подписки, своих правил нет.
- Лимит соединений против OOM.

## Требования

- OpenWrt 25.12 (apk, firewall4).
- ~40 МБ на overlay.
- 256 МБ ОЗУ.
- Подписка, отдающая Xray-JSON.
- Если VPN-провайдер фильтрует по User-Agent, задайте его в Advanced → Settings.

## Установка

```sh
wget -qO- https://raw.githubusercontent.com/id-filatov/gatygo/main/install.sh | sh
```

Скрипт проверяет роутер (версию OpenWrt, конфликтующие прокси-пакеты, зависимости в фидах,
место, dnsmasq, сборку xray под архитектуру) и при любой ошибке ничего не ставит. Затем ставит
последний релиз и ядро xray.

Дальше: LuCI → **Services → gatygo**, вставить ссылку, **Connect**.

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
- 10085 API xray, 10808 SOCKS для проверки сервисов — только `127.0.0.1`.

## Разработка

```sh
tests/run.sh                     # юнит-тесты в Docker (busybox ash, jq, закреплённый xray)
tests/run.sh test_core.sh        # один файл
tools/build-apk.sh               # сборка обоих .apk в OpenWrt SDK
tests/vm/run.sh [gatygo.apk]     # e2e на VM с OpenWrt
tools/pin-core.sh v26.9.9        # закрепить другую версию xray
tools/release.sh                 # релиз из main, пакеты собирает CI
```

## Лицензия

[MIT](LICENSE)
