# yami-greet

A login screen: a greetd greeter inside niri, drawn with the same engine as the rest of yami. Works on its own with any session listed in `wayland-sessions`.

## Install

```sh
./install-system.sh
```

It builds as you and installs as root (greetd's config with a backup, `/var/lib/yami-greet`, the session script, fonts). `./install-system.sh --uninit` hands the login back to the previous manager.

If it ever locks you out: Ctrl+Alt+F3, log in, enable your previous manager. After two fast failures greetd's text greeter comes up by itself.

## Look

`/var/lib/yami-greet/look/look.json` holds the same keys as `~/.config/yami/style.json` (`preset`, `accent`, `corners`, `font`…) and `wall.png` the wallpaper. The yami shell fills them in by itself.

## License

MIT
