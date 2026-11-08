# yami-greet

Экран входа: greeter для greetd внутри niri, нарисованный тем же движком, что и остальной yami. Работает сам по себе с любым сеансом из `wayland-sessions`.

## Установка

```sh
./install-system.sh
```

Собирает от твоего имени, ставит от root (конфиг greetd с копией, `/var/lib/yami-greet`, скрипт сеанса, шрифты). `./install-system.sh --uninit` возвращает вход прежнему менеджеру.

Если что-то заперло вход: Ctrl+Alt+F3, войди, включи прежний менеджер. После двух быстрых сбоев текстовый greeter greetd поднимается сам.

## Вид

`/var/lib/yami-greet/look/look.json` — те же ключи, что в `~/.config/yami/style.json` (`preset`, `accent`, `corners`, `font`…), `wall.png` — обои. Шелл yami заполняет их сам.

## Лицензия

MIT
