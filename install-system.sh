#!/usr/bin/env bash
# Install (or update) the nemo login screen: greetd starts nemo-greet inside niri, from the next
# boot. Run from the repo as yourself; it builds nemo-greet and asks for sudo once.
#   install-system.sh [--no-enable] [--yes]   --no-enable: install, leave the login manager alone; --yes: do not ask
# The installer runs the root half itself (as root):
#   install-system.sh --system USER [--bin FILE] [--cursor DIR] [--no-enable] [--bin-only]
#   install-system.sh --uninit        greetd off, the login manager it replaced on (OpenRC, runit)
# Init systems: systemd (display-manager.service), OpenRC (Alpine, Gentoo), runit (Void). Without
# logind/elogind the greeter user joins seatd's group, so niri gets a seat.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOK=/var/lib/nemo-greet/look STATE=/var/lib/nemo-greet/state LOGD=/var/lib/nemo-greet/log
REPLACED=/var/lib/nemo-greet/replaced
CONF=/etc/greetd/config.toml
DMS=(sddm gdm lightdm lxdm ly emptty cosmic-greeter plasmalogin display-manager xdm slim)

init_kind() {
  if [[ -d /run/systemd/system ]]; then echo systemd
  elif command -v rc-update >/dev/null 2>&1 && [[ -d /etc/runlevels ]]; then echo openrc
  elif [[ -d /etc/sv ]] && runit_dir >/dev/null; then echo runit
  else echo other; fi
}
# where runit's enabled services are linked (Void: /var/service)
runit_dir() {
  local d
  for d in /var/service /etc/runit/runsvdir/default /run/runit/service; do
    [[ -d $d ]] && { echo "$d"; return 0; }
  done
  return 1
}

# the greetd user: the one its own config names, else the one the distro created
greeter_user() {
  local u
  u="$(awk -F'"' '/^[[:space:]]*\[/ { s = $0 } s ~ /default_session/ && /^[[:space:]]*user[[:space:]]*=/ { print $2; exit }' "$CONF" 2>/dev/null)"
  if [[ -n $u ]] && getent passwd "$u" >/dev/null; then echo "$u"; return; fi
  for u in greeter _greetd greetd _greeter; do getent passwd "$u" >/dev/null && { echo "$u"; return; }; done
  return 1
}

# niri needs a seat: logind (systemd) and elogind give one to every session; with seatd alone the
# greeter user has to be in seatd's group (Void: _seatd, Alpine and Gentoo: seat)
seat_setup() {
  local g="$1" grp
  [[ $INIT == systemd || -d /run/systemd/seats ]] && return 0
  for grp in _seatd seat; do
    if getent group "$grp" >/dev/null; then
      id -nG "$g" | tr ' ' '\n' | grep -qx "$grp" || usermod -aG "$grp" "$g"
      case $INIT in
        openrc) rc-update add seatd default >/dev/null 2>&1 || true ;;
        runit) [[ -d /etc/sv/seatd && ! -e $(runit_dir)/seatd ]] && ln -s /etc/sv/seatd "$(runit_dir)/" || true ;;
      esac
      echo "seat: $g joins $grp (seatd)"
      return 0
    fi
  done
  echo "no logind, elogind or seatd: niri of the login screen has no seat (the text login takes over)" >&2
}

# runit (Void): runsvdir starts or stops a service as soon as its link comes or goes, so a login
# manager switched now would end the running session or jump to its own VT. The switch waits for
# the next boot: a stage-1 script (core-services) does it once and removes itself
RUNIT_HOOK=/etc/runit/core-services/90-nemo-greetd.sh
runit_switch() {
  if [[ -d /etc/runit/core-services ]]; then
    { echo "# nemo: switches the login manager at this boot (install-system.sh), then removes itself"
      printf '%s\n' "$@"
      echo "rm -f $RUNIT_HOOK"; } >"$RUNIT_HOOK.new" && mv -f "$RUNIT_HOOK.new" "$RUNIT_HOOK"
    echo "runit: the login manager switches at the next boot (this session is untouched)"
  else
    local c
    for c; do sh -c "$c"; done
    echo "runit: switched now"
  fi
}
runit_svdir() { if [[ -d /etc/runit/runsvdir/default ]]; then echo /etc/runit/runsvdir/default; else runit_dir; fi; }

# greetd becomes the login manager; the ones it replaces are written down for --uninit
enable_greetd() {
  local s d lines=()
  case $INIT in
    systemd)
      systemctl enable -f greetd.service
      echo "greetd: the login manager from the next boot (this session is untouched)" ;;
    openrc)
      [[ -x /etc/init.d/greetd ]] || { echo "no /etc/init.d/greetd: install greetd's OpenRC script (Alpine: greetd-openrc)" >&2; return 1; }
      # rc-update only changes the runlevel: nothing starts or stops now
      for s in "${DMS[@]}"; do
        if [[ -e /etc/runlevels/default/$s ]]; then
          rc-update del "$s" default >/dev/null && note_replaced openrc "$s"
        fi
      done
      rc-update add greetd default >/dev/null
      echo "greetd: in the default runlevel from the next boot (this session is untouched)" ;;
    runit)
      [[ -d /etc/sv/greetd ]] || { echo "no /etc/sv/greetd: install greetd" >&2; return 1; }
      d="$(runit_svdir)"
      for s in "${DMS[@]}"; do
        [[ -L $d/$s ]] && { lines+=("rm -f '$d/$s'"); note_replaced runit "$s"; }
      done
      lines+=("[ -e '$d/greetd' ] || ln -s /etc/sv/greetd '$d/greetd'")
      runit_switch "${lines[@]}" ;;
    *) echo "unknown init system: enable the greetd service yourself" >&2 ;;
  esac
}
note_replaced() { grep -qsx "$1 $2" "$REPLACED" || echo "$1 $2" >>"$REPLACED"; }

# --uninit: greetd off, the managers enable_greetd turned off back on (systemd: install.sh does it)
uninit() {
  local kind s d lines=()
  INIT="$(init_kind)"
  case $INIT in
    openrc)
      rc-update del greetd default >/dev/null 2>&1 || true
      if [[ -r $REPLACED ]]; then
        while read -r kind s; do
          [[ $kind == openrc && $s =~ ^[A-Za-z0-9_.@-]+$ ]] && rc-update add "$s" default >/dev/null 2>&1 && echo "openrc: $s back in the default runlevel"
        done <"$REPLACED"
      fi ;;
    runit)
      d="$(runit_svdir)"
      lines=("rm -f '$d/greetd'")
      if [[ -r $REPLACED ]]; then
        while read -r kind s; do
          [[ $kind == runit && $s =~ ^[A-Za-z0-9_.@-]+$ && -d /etc/sv/$s ]] && lines+=("[ -e '$d/$s' ] || ln -s '/etc/sv/$s' '$d/$s'")
        done <"$REPLACED"
      fi
      runit_switch "${lines[@]}" ;;
  esac
  return 0
}

# SELinux (Fedora): files copied by root keep the label of where they came from, greetd could not run them
relabel() { command -v restorecon >/dev/null 2>&1 && restorecon -R "$@" 2>/dev/null || true; }

# the root half: the binary, folders, greet-session, fonts, cursor, greetd's config, the init system
system() {
  local user="" bin="" cursor="" enable=1 only=0
  while (($#)); do
    case "$1" in
      --system) user="$2"; shift ;;
      --bin) bin="$2"; shift ;;
      --cursor) cursor="$2"; shift ;;
      --no-enable) enable=0 ;;
      --bin-only) only=1 ;;
      *) echo "unknown: $1" >&2; exit 2 ;;
    esac
    shift
  done
  ((EUID == 0)) || { echo "install-system.sh --system runs as root" >&2; exit 1; }
  [[ $user =~ ^[a-z_][a-z0-9_.-]*\$?$ ]] && getent passwd "$user" >/dev/null || { echo "no such user: $user" >&2; exit 1; }
  if [[ -n $bin ]]; then
    install -Dm755 "$bin" /usr/local/bin/.nemo-greet.new && mv -f /usr/local/bin/.nemo-greet.new /usr/local/bin/nemo-greet
    relabel /usr/local/bin/nemo-greet
  fi
  ((only)) && return 0
  command -v greetd >/dev/null || { echo "greetd is not installed" >&2; exit 1; }
  INIT="$(init_kind)"
  local g gg
  g="$(greeter_user)" || { echo "greetd has no greeter user" >&2; exit 1; }
  gg="$(id -gn "$g")"
  # what nemo-greet reads: the look (yours, the shell writes it), its memory and log (the greeter's own)
  install -d -m755 /var/lib/nemo-greet
  install -d -m755 -o "$user" -g "$(id -gn "$user")" "$LOOK"
  install -d -m700 -o "$g" -g "$gg" "$STATE"
  install -d -m755 -o "$g" -g "$gg" "$LOGD"
  # the first boot: this user and the niri session already picked. The folder is the greeter's: the
  # file is made in root's folder and renamed in, so root never writes through a link put there
  if [[ ! -e $STATE/last && ! -L $STATE/last ]]; then
    local tmp
    tmp="$(mktemp /var/lib/nemo-greet/.last.XXXXXX)"
    printf '%s\nniri\n' "$user" >"$tmp" && chown "$g:$gg" "$tmp" && chmod 600 "$tmp" && mv -fT "$tmp" "$STATE/last" || rm -f -- "$tmp"
  fi
  install -Dm755 "$ROOT/greet-session" /usr/local/lib/nemo/greet-session
  install -Dm644 -t /usr/local/share/nemo-greet/fonts "$ROOT/fonts/Tiny5.ttf" "$ROOT/fonts/DotGothic16-Regular.ttf" "$ROOT/fonts/OFL-tiny5.txt" "$ROOT/fonts/OFL-dotgothic16.txt"
  # the pixel cursor: niri of the login screen reads /usr/share/icons only
  if [[ -n $cursor && -d $cursor ]]; then
    rm -rf -- /usr/share/icons/nemo-cursor
    cp -r "$cursor" /usr/share/icons/nemo-cursor
    chmod -R a+rX /usr/share/icons/nemo-cursor
  fi
  seat_setup "$g"
  # greetd's own config is kept once (./install.sh --uninstall puts it back); its terminal stays
  mkdir -p /etc/greetd
  if [[ -f $CONF ]] && ! head -n1 "$CONF" | grep -q '^# nemo:' && [[ ! -e $CONF.nemo-orig ]]; then
    cp -p "$CONF" "$CONF.nemo-orig"
  fi
  local vt
  vt="$(awk '/^[[:space:]]*\[/ { s = $0 } s ~ /terminal/ && /^[[:space:]]*vt[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }' "$CONF.nemo-orig" 2>/dev/null)"
  [[ $vt =~ ^([0-9]+|\"[a-z]+\")$ ]] || vt=1
  # without systemd nothing stops the getty on tty1 for greetd: the login screen takes VT 7
  [[ $INIT != systemd && $vt == 1 ]] && vt=7
  printf '%s\n' "# nemo: the login screen (install-system.sh; ./install.sh --uninstall puts the old file back)" \
    "[terminal]" "vt = $vt" "" "[default_session]" "command = \"/usr/local/lib/nemo/greet-session\"" "user = \"$g\"" >"$CONF.new"
  mv -f "$CONF.new" "$CONF"
  # the SDDM theme nemo had before its own login screen
  rm -rf -- /usr/share/sddm/themes/nemo /etc/sddm.conf.d/zz-nemo.conf /etc/sddm.conf.d/10-nemo.conf
  relabel /var/lib/nemo-greet /usr/local/lib/nemo /usr/local/share/nemo-greet /usr/share/icons/nemo-cursor /etc/greetd
  ((enable)) && enable_greetd
  return 0
}

if [[ ${1:-} == --system ]]; then
  system "$@"
  exit 0
fi
if [[ ${1:-} == --uninit ]]; then
  ((EUID == 0)) || { echo "install-system.sh --uninit runs as root: sudo ./install-system.sh --uninit" >&2; exit 1; }
  uninit
  exit 0
fi

ENABLE=() YES=0
for a; do case "$a" in --no-enable) ENABLE=(--no-enable) ;; -y | --yes) YES=1 ;; *) echo "unknown: $a" >&2; exit 2 ;; esac; done
((EUID != 0)) || { echo "run it as yourself: it asks for the password itself" >&2; exit 1; }
# человек у терминала решает сам; установщик и шелл спросили до запуска и передают --yes
if ((!YES)) && [[ -t 0 && -t 1 ]]; then
  case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
    ru*) q="Поставить экран входа nemo-greet? Он заменит текущий менеджер входа со следующей загрузки, нужен sudo." ;;
    pt*) q="Instalar a tela de login nemo-greet? Ela substitui o gerenciador de login atual a partir da próxima inicialização; precisa de sudo." ;;
    *) q="Install the nemo-greet login screen? It replaces the current login manager from the next boot and needs sudo." ;;
  esac
  read -r -p "$q [y/N] " a || a=n
  [[ $a =~ ^[yYдДsS] ]] || { echo "cancelled"; exit 1; }
fi
SU=sudo
command -v sudo >/dev/null || SU=doas
if ! command -v greetd >/dev/null; then
  if command -v pacman >/dev/null; then $SU pacman -S --needed --noconfirm greetd greetd-agreety
  elif command -v dnf >/dev/null; then $SU dnf install -y greetd
  elif command -v apt-get >/dev/null; then $SU apt-get install -y greetd
  elif command -v zypper >/dev/null; then $SU zypper --non-interactive install greetd
  elif command -v xbps-install >/dev/null; then $SU xbps-install -y greetd
  elif command -v apk >/dev/null; then $SU apk add greetd greetd-agreety
  else echo "install greetd with your package manager first (./install.sh --login does it)" >&2; exit 1; fi
fi
# the updater's clone builds into the cache (install.sh did it a moment ago): the same target, so
# nothing is built twice; a checkout of your own builds into its shell/target
TARGET="${CARGO_TARGET_DIR:-}"
[[ -z $TARGET && $ROOT == "${XDG_DATA_HOME:-$HOME/.local/share}/nemo/src" ]] && TARGET="${XDG_CACHE_HOME:-$HOME/.cache}/nemo/target"
TARGET="${TARGET:-$ROOT/target}"
# готовый бинарь лежит рядом (установка из архива выпуска): собирать нечего
GREET="$ROOT/nemo-greet"
if [[ ! -x $GREET ]]; then
  (cd "$ROOT" && cargo build --release --locked --target-dir "$TARGET")
  GREET="$TARGET/release/nemo-greet"
fi
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
# курсор экрана входа: его рисует шелл nemo; без шелла — системный
if command -v nemo-shell >/dev/null; then nemo-shell recolor --cursor-to "$TMP/nemo-cursor" || true; fi
# the login manager greetd replaces (systemd): ./install.sh --uninstall enables it again; on OpenRC
# and runit the root half writes them down itself (/var/lib/nemo-greet/replaced)
STATE_D="${XDG_STATE_HOME:-$HOME/.local/state}/nemo"
prev="$(basename "$(readlink /etc/systemd/system/display-manager.service 2>/dev/null)" .service)"
if [[ -n $prev && $prev != greetd && ! -s $STATE_D/login-dm ]]; then
  mkdir -p "$STATE_D" && printf '%s\n' "$prev" >"$STATE_D/login-dm"
fi
$SU "$ROOT/install-system.sh" --system "$(id -un)" --bin "$GREET" --cursor "$TMP/nemo-cursor" "${ENABLE[@]}"
# the look of the shell, now (it keeps it current itself)
nemo-shell login sync >/dev/null 2>&1 || true
echo "login screen: nemo-greet in greetd ($(/usr/local/bin/nemo-greet --version))"
# SDDM (the login screen before 2.6, often installed by this installer) is off now, not removed: it
# may be KDE's. Once the new login screen has let you in, `nemo doctor` prints the command to remove it
command -v sddm >/dev/null && echo "SDDM is turned off, not removed; after the first login here, nemo doctor tells how to remove it if nothing else uses it"
