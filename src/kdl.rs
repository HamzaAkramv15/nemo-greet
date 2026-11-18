// Конфиг niri для экрана входа (`yami-greet kdl`, его пишет greet-session при каждом старте).
// Свой файл niri вида не читает: из look.json берутся только мониторы (то, что написал шелл в
// ~/.config/yami/niri/outputs.kdl) и раскладки, и каждое значение проверяется по белому списку символов.
// Иначе файл пользователя мог бы дать niri экрана входа spawn или бинд — а он видит пароли всех.
// --plain: без мониторов, раскладок и ключей новых niri (если полный конфиг не прошёл проверку).

use serde_json::Value;

fn ok_chars(s: &str, extra: &str, max: usize) -> bool {
    !s.is_empty() && s.len() <= max && s.chars().all(|c| c.is_ascii_alphanumeric() || extra.contains(c))
}

const TRANSFORMS: [&str; 8] = ["normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270"];

/// блоки output из outputs.kdl шелла: имя, off, mode, scale, transform, position
pub fn outputs(text: &str) -> String {
    let mut out = String::new();
    let mut open = false;
    for l in text.lines().map(str::trim).take(400) {
        if let Some(rest) = l.strip_prefix("output \"") {
            if open {
                out += "}\n";
            }
            open = false;
            let Some(name) = rest.strip_suffix("\" {") else { continue };
            if !ok_chars(name, " -_.", 96) {
                continue;
            }
            out += &format!("output \"{name}\" {{\n");
            open = true;
            continue;
        }
        if !open {
            continue;
        }
        let w: Vec<&str> = l.split_whitespace().collect();
        match w.as_slice() {
            ["}"] => {
                out += "}\n";
                open = false;
            }
            ["off"] => out += "    off\n",
            ["mode", m] => {
                let m = m.trim_matches('"');
                let good = m.split_once('x').and_then(|(a, b)| Some((a, b.split_once('@')?))).is_some_and(|(a, (b, r))| {
                    a.parse::<u32>().is_ok_and(|v| v <= 16384) && b.parse::<u32>().is_ok_and(|v| v <= 16384) && r.parse::<f64>().is_ok_and(|v| (1.0..=1000.0).contains(&v))
                });
                if good {
                    out += &format!("    mode \"{m}\"\n");
                }
            }
            ["scale", s] => {
                if let Some(v) = s.parse::<f64>().ok().filter(|v| (0.25..=8.0).contains(v)) {
                    out += &format!("    scale {v}\n");
                }
            }
            ["transform", t] => {
                let t = t.trim_matches('"');
                if TRANSFORMS.contains(&t) {
                    out += &format!("    transform \"{t}\"\n");
                }
            }
            ["position", x, y] => {
                let n = |s: &str, k: &str| s.strip_prefix(k).and_then(|v| v.parse::<i32>().ok()).filter(|v| v.abs() <= 65536);
                if let (Some(x), Some(y)) = (n(x, "x="), n(y, "y=")) {
                    out += &format!("    position x={x} y={y}\n");
                }
            }
            _ => {}
        }
    }
    if open {
        out += "}\n";
    }
    out
}

/// ночной свет и на экране входа: если шелл его включил (nightOn), niri экрана входа запускает
/// wlsunset с теми же аргументами, что у шелла (yami_px::night::args). Значения — чужие: числа
/// зажаты в пределы там же, а в команду попадают только цифры, точки и минусы
pub fn night(look: &Value) -> String {
    let on = look.get("nightOn").and_then(|v| v.as_bool()).unwrap_or(false);
    let bin = ["/usr/bin/wlsunset", "/usr/local/bin/wlsunset"].into_iter().find(|p| std::path::Path::new(p).is_file());
    let Some(bin) = bin.filter(|_| on) else { return String::new() };
    let int = |k: &str, d: i64| look.get(k).and_then(|v| v.as_i64()).unwrap_or(d).clamp(-1000, 100_000) as i32;
    let num = |k: &str| look.get(k).and_then(|v| v.as_f64()).filter(|x| x.is_finite());
    let place = num("nightLat").zip(num("nightLon"));
    let always = look.get("nightAlways").and_then(|v| v.as_bool()).unwrap_or(false);
    let args = yami_px::night::args(int("nightTemp", 4000), always, place, int("nightOnH", 20), int("nightOffH", 7));
    let list: Vec<String> = std::iter::once(bin.to_string()).chain(args).map(|a| q(&a)).collect();
    format!("\nspawn-at-startup {}\n", list.join(" "))
}

fn q(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

/// весь конфиг; me — путь к yami-greet
pub fn config(look: &Value, plain: bool, me: &str) -> String {
    let s = |k: &str| look.get(k).and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
    let mut c = String::from("// yami-greet: niri of the login screen (written by `yami-greet kdl` at every start)\n\n");
    c += "hotkey-overlay {\n    skip-at-startup\n}\nprefer-no-csd\nscreenshot-path null\nanimations {\n    off\n}\n";
    if !plain {
        // ключи niri 25.x: без них старый niri конфиг не примет, тогда идёт --plain
        c += "config-notification {\n    disable-failed\n}\nxwayland-satellite {\n    off\n}\n";
        // чёрный: из него экран входа проявляется и в него уходит (между ним и сеансом — тоже чёрный)
        c += "layout {\n    background-color \"#000000\"\n}\n";
    }
    if std::path::Path::new("/usr/share/icons/yami-cursor/cursors").is_dir() {
        c += "cursor {\n    xcursor-theme \"yami-cursor\"\n    xcursor-size 24\n    hide-when-typing\n}\n";
    }
    c += "input {\n    keyboard {\n";
    let (lay, opt) = (s("kbLayout"), s("kbSwitch"));
    if !plain && ok_chars(&lay, ",_-()", 120) {
        c += &format!("        xkb {{\n            layout {}\n", q(&lay));
        if ok_chars(&opt, ",_-():", 200) {
            c += &format!("            options {}\n", q(&opt));
        }
        c += "        }\n";
    }
    if !plain && look.get("greetNumlock").and_then(|v| v.as_bool()).unwrap_or(true) {
        c += "        numlock\n";
    }
    c += "    }\n    touchpad {\n        tap\n    }\n}\n";
    if !plain {
        c += &outputs(&s("outputs"));
        c += &night(look);
    }
    // экран входа вышел (вошли, упал, выключают) — niri следом; код выхода — greet-session (в свою
    // папку XDG_RUNTIME_DIR, её создаёт greet-session; без неё — никуда, не в общий /tmp). niri
    // отдаёт запущенным /dev/null: сообщения экрана входа — в журнал greet-session (YAMI_GREET_LOG)
    c += &format!(
        "\nspawn-at-startup \"sh\" \"-c\" {} {}\n",
        q("\"$0\" 2>>\"${YAMI_GREET_LOG:-/dev/null}\"; rc=$?; [ -d \"$XDG_RUNTIME_DIR\" ] && echo $rc >\"$XDG_RUNTIME_DIR/yami-greet.rc\"; \"${YAMI_GREET_NIRI:-niri}\" msg action quit --skip-confirmation"),
        q(me)
    );
    c
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    /// ночной свет: выключен — ничего; включён — wlsunset с зажатыми значениями; мусор в команду не попадает
    #[test]
    fn night_light_is_started_only_when_asked_and_clamped() {
        if !std::path::Path::new("/usr/bin/wlsunset").is_file() && !std::path::Path::new("/usr/local/bin/wlsunset").is_file() {
            return;
        }
        assert_eq!(super::night(&json!({})), "");
        assert_eq!(super::night(&json!({ "nightOn": false, "nightTemp": 4000 })), "");
        let on = super::night(&json!({ "nightOn": true, "nightTemp": 4750, "nightOnH": 20, "nightOffH": 23 }));
        assert!(on.contains("spawn-at-startup") && on.contains("\"-t\" \"4750\"") && on.contains("\"-S\" \"23:00\"") && on.contains("\"-s\" \"20:00\""), "{on}");
        let sun = super::night(&json!({ "nightOn": true, "nightTemp": 4000, "nightLat": 30.06, "nightLon": 31.25 }));
        assert!(sun.contains("\"-l\" \"30.06\"") && sun.contains("\"-L\" \"31.25\""), "{sun}");
        let all = super::night(&json!({ "nightOn": true, "nightTemp": 3500, "nightAlways": true }));
        assert!(all.contains("\"-t\" \"3500\" \"-T\" \"3501\""), "{all}");
        // чужие значения: за пределы не выходят, строки вместо чисел — по умолчанию
        let evil = super::night(&json!({ "nightOn": true, "nightTemp": 999999, "nightLat": "1; rm -rf /", "nightOnH": "x" }));
        assert!(evil.contains("\"-t\" \"6000\"") && !evil.contains("rm") && !evil.contains("-l"), "{evil}");
    }

    #[test]
    fn outputs_whitelist() {
        let t = "// yami\n\noutput \"DP-2\" {\n    mode \"1920x1080@180.000\"\n    scale 1\n    transform \"normal\"\n    position x=0 y=0\n    variable-refresh-rate on-demand=true\n}\n\noutput \"HDMI-A-1\" {\n    off\n}\nspawn-at-startup \"evil\"\noutput \"x\\\" { spawn\" {\n    mode \"1x1@60;rm\"\n}\n";
        let o = super::outputs(t);
        assert!(o.contains("output \"DP-2\" {\n    mode \"1920x1080@180.000\"\n    scale 1\n    transform \"normal\"\n    position x=0 y=0\n}\n"));
        assert!(o.contains("output \"HDMI-A-1\" {\n    off\n}"));
        assert!(!o.contains("evil") && !o.contains("spawn") && !o.contains("1x1"));
    }
}
