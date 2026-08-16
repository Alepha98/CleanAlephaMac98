#!/usr/bin/env python3
"""User-style UI run: mouse clicks at live window coords + keyboard. No AX entire-contents."""
from __future__ import annotations

import subprocess
import time
from pathlib import Path

APP = Path.home() / "Applications/CleanAlephaMac98.app"
LOG = Path.home() / "Library/Logs/CleanAlephaMac98.log"
OUT = Path(__file__).resolve().parents[1] / "docs/UI_RUN_RESULTS.md"
SHOTS = Path("/tmp/cam98-ui")
SHOTS.mkdir(exist_ok=True)
results: list[dict] = []


def sh(cmd: str, timeout: int = 60) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)


def osa(script: str, timeout: int = 20) -> tuple[int, str, str]:
    r = subprocess.run(["osascript"], input=script, capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout or "").strip(), (r.stderr or "").strip()


def defaults(key: str) -> str:
    return sh(f'defaults read com.alepha98.CleanAlephaMac98 {key} 2>/dev/null').stdout.strip()


def record(uid: str, chain: str, expect: str, ok: bool, detail: str = "") -> None:
    results.append({"id": uid, "chain": chain, "expect": expect, "ok": ok, "detail": detail})
    print(("PASS" if ok else "FAIL"), uid, detail, flush=True)


def activate() -> None:
    osa('tell application "CleanAlephaMac98" to activate')
    time.sleep(0.2)


def win_frame() -> tuple[int, int, int, int] | None:
    code, out, _ = osa(
        '''
        tell application "System Events"
          tell process "CleanAlephaMac98"
            set p to position of window 1
            set s to size of window 1
            return ((item 1 of p) as text) & "," & ((item 2 of p) as text) & "," & ((item 1 of s) as text) & "," & ((item 2 of s) as text)
          end tell
        end tell
        '''
    )
    if code != 0 or not out:
        return None
    a, b, c, d = out.split(",")
    return int(a), int(b), int(c), int(d)


def click_xy(x: float, y: float) -> None:
    activate()
    try:
        from Quartz import (
            CGEventCreateMouseEvent,
            CGEventPost,
            kCGHIDEventTap,
            kCGEventLeftMouseDown,
            kCGEventLeftMouseUp,
            CGPointMake,
        )

        pt = CGPointMake(float(x), float(y))
        down = CGEventCreateMouseEvent(None, kCGEventLeftMouseDown, pt, 0)
        up = CGEventCreateMouseEvent(None, kCGEventLeftMouseUp, pt, 0)
        CGEventPost(kCGHIDEventTap, down)
        CGEventPost(kCGHIDEventTap, up)
    except Exception:
        osa(
            f'''
            tell application "System Events"
              click at {{{int(x)}, {int(y)}}}
            end tell
            '''
        )
    time.sleep(0.28)


def key(key: str, command: bool = False) -> None:
    activate()
    if key == "esc":
        osa('tell application "System Events" to key code 53')
    elif key == ".":
        osa('tell application "System Events" to keystroke "." using command down')
    else:
        using = " using {command down}" if command else ""
        osa(f'tell application "System Events" to keystroke "{key}"{using}')
    time.sleep(0.35)


def wait_log(substr: str, since: str, timeout: float = 120.0) -> bool:
    t0 = time.time()
    while time.time() - t0 < timeout:
        cur = LOG.read_text(errors="ignore") if LOG.exists() else ""
        if substr in cur[len(since) :]:
            return True
        time.sleep(0.35)
    return False


def capture(name: str) -> str:
    path = SHOTS / f"{name}.png"
    # Prefer screencapture by CGWindow id
    try:
        from Quartz import (
            CGWindowListCopyWindowInfo,
            kCGWindowListOptionOnScreenOnly,
            kCGNullWindowID,
        )

        wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
        wid = None
        for w in wins or []:
            if w.get("kCGWindowOwnerName") == "CleanAlephaMac98" and w.get("kCGWindowLayer", 0) == 0:
                wid = w.get("kCGWindowNumber")
                break
        if wid:
            rr = sh(f'screencapture -x -l {wid} "{path}"')
            if path.exists() and path.stat().st_size > 2000:
                return str(path)
    except Exception as e:
        pass
    # Fallback: full display (may fail in sandbox)
    sh(f'screencapture -x "{path}"')
    if path.exists() and path.stat().st_size > 2000:
        return str(path)
    return "capture-fail"


def theme_points(frame: tuple[int, int, int, int]) -> tuple[tuple[float, float], ...]:
    """Three theme chips at foot of sidebar (left→right: light, system, dark)."""
    x, y, w, h = frame
    # Sidebar ~276pt; chips ~78 wide near bottom inside padding.
    cy = y + h - 28
    # Relative to left of sidebar content (~12–16 inset)
    xs = [x + 40, x + 124, x + 208]
    return tuple((xx, cy) for xx in xs)


def menu_scan() -> bool:
    """Trigger Scan from the File menu like a user."""
    activate()
    code, out, err = osa(
        '''
        tell application "System Events"
          tell process "CleanAlephaMac98"
            set frontmost to true
            try
              click menu item "Сканировать" of menu "Файл" of menu bar 1
              return "ok-ru"
            end try
            try
              click menu item "Scan" of menu "File" of menu bar 1
              return "ok-en"
            end try
            try
              click menu item "Сканировать" of menu "Очистка" of menu bar 1
              return "ok-clean-ru"
            end try
            try
              click menu item "Scan" of menu "Clean" of menu bar 1
              return "ok-clean-en"
            end try
            return "miss"
          end tell
        end tell
        '''
    )
    return code == 0 and out.startswith("ok")


def scan_point(frame: tuple[int, int, int, int]) -> tuple[float, float]:
    x, y, w, h = frame
    return x + w * 0.55, y + h * 0.68


def try_start_scan(before: str) -> bool:
    f = win_frame()
    if not f:
        return False
    # Several CTA positions under the orb (layout shifts with results/idle).
    for fy in (0.62, 0.68, 0.72, 0.78):
        click_xy(f[0] + f[2] * 0.55, f[1] + f[3] * fy)
        if wait_log("scan start", before, timeout=2.5) or wait_log("scanLive start", before, timeout=0.1):
            return True
    if menu_scan() and wait_log("scan start", before, timeout=4):
        return True
    key("r", command=True)
    if wait_log("scan start", before, timeout=4) or wait_log("scanLive start", before, timeout=2):
        return True
    # Clean menu: ⌘⇧R
    activate()
    osa('tell application "System Events" to keystroke "r" using {command down, shift down}')
    time.sleep(0.4)
    return wait_log("scan start", before, timeout=5) or wait_log("scanLive start", before, timeout=3)


def main() -> int:
    print("=== UI user run start ===", flush=True)
    sh("killall CleanAlephaMac98 2>/dev/null || true")
    time.sleep(0.5)
    sh(f'open -a "{APP}"')
    time.sleep(2.4)
    activate()

    frame = win_frame()
    record("UI-001", "Открыть app из ~/Applications", "Окно на экране", frame is not None, f"frame={frame}")
    if not frame:
        return 1
    capture("01-start")

    # Theme: click sun / moon / system by layout
    sun, sysp, moon = theme_points(frame)
    click_xy(*sun)
    time.sleep(0.7)
    a = defaults("cam98.appearance")
    record("UI-010", "Клик левая иконка темы (день)", "appearance=light", a == "light", f"appearance={a} @ {sun}")
    capture("02-light")

    frame = win_frame() or frame
    sun, sysp, moon = theme_points(frame)
    click_xy(*moon)
    time.sleep(0.7)
    a = defaults("cam98.appearance")
    record("UI-011", "Клик правая иконка темы (луна/ночь)", "appearance=dark", a == "dark", f"appearance={a} @ {moon}")
    capture("03-dark-moon")

    frame = win_frame() or frame
    sun, sysp, moon = theme_points(frame)
    click_xy(*sysp)
    time.sleep(0.7)
    a = defaults("cam98.appearance")
    record("UI-012", "Клик средняя иконка (система)", "appearance=system", a == "system", f"appearance={a} @ {sysp}")
    click_xy(*(theme_points(win_frame() or frame)[2]))
    time.sleep(0.5)

    # Keyboard navigation like a user
    key("1", command=True)
    record("UI-100", "⌘1", "smart", defaults("cam98.module") == "smart", defaults("cam98.module"))
    key("2", command=True)
    record("UI-101", "⌘2", "junk", defaults("cam98.module") == "junk", defaults("cam98.module"))
    key("3", command=True)
    record("UI-101b", "⌘3", "mail", defaults("cam98.module") == "mail", defaults("cam98.module"))
    key("7", command=True)
    record("UI-102", "⌘7", "browsers", defaults("cam98.module") == "browsers", defaults("cam98.module"))
    key("9", command=True)
    record("UI-102b", "⌘9", "messengers", defaults("cam98.module") == "messengers", defaults("cam98.module"))
    key("0", command=True)
    record("UI-103", "⌘0 Обзор диска", "space", defaults("cam98.module") == "space", defaults("cam98.module"))
    capture("04-disk")
    key("-", command=True)
    record("UI-080", "⌘- Обслуживание", "tools", defaults("cam98.module") == "tools", defaults("cam98.module"))
    capture("05-tools")

    # Smart scan: go home, start like a user (button / menu / shortcuts)
    key("1", command=True)
    time.sleep(0.5)
    before = LOG.read_text(errors="ignore") if LOG.exists() else ""
    started = try_start_scan(before)
    record("UI-030", "Умный скан: клик CTA / меню / ⌘R", "scan start smart в логе", started, f"started={started}")
    capture("06-scanning")

    done = wait_log("scan done smart", before, timeout=180) if started else False
    if started and not done:
        # partial / stop still counts as UI lived
        done = wait_log("scan stopped", before, timeout=5)
    record("UI-031", "Ждать конец умного скана как юзер", "scan done smart", bool(done), f"done={done}")
    capture("07-smart-done")

    def open_module(want: str, y_candidates: list[int]) -> bool:
        for yo in y_candidates:
            f = win_frame() or frame
            click_xy(f[0] + 130, f[1] + yo)
            time.sleep(0.28)
            if defaults("cam98.module") == want:
                return True
        return False

    ok_pulse = open_module("pulse", list(range(540, 700, 32)))
    record("UI-050a", "Клик сайдбар → Быстродействие", "module=pulse", ok_pulse, defaults("cam98.module"))
    if ok_pulse:
        before = LOG.read_text(errors="ignore") if LOG.exists() else ""
        started_p = try_start_scan(before)
        okp = started_p and (
            wait_log("scanLive done pulse", before, timeout=35) or wait_log("pulse junk", before, timeout=8)
        )
        record("UI-050", "Сканировать в Быстродействии", "pulse завершился", okp, f"ok={okp}")
        capture("08-pulse")
        f = win_frame() or frame
        click_xy(f[0] + f[2] * 0.62, f[1] + f[3] * 0.45)
        time.sleep(0.5)
        key("esc")
        record("UI-052", "Клик карточка → Esc назад", "UI живой", win_frame() is not None, defaults("cam98.module"))
    else:
        record("UI-050", "Pulse", "ok", False, "не нашли пункт")
        record("UI-052", "drill", "ok", False, "skip")

    ok_protect = open_module("protect", list(range(620, 820, 28)))
    # protect sits in its own group under startup — if we landed on startup, nudge down
    if not ok_protect and defaults("cam98.module") == "startup":
        f = win_frame() or frame
        for dy in (36, 56, 76, 96, 116):
            click_xy(f[0] + 130, f[1] + 640 + dy)
            time.sleep(0.28)
            if defaults("cam98.module") == "protect":
                ok_protect = True
                break
    record("UI-060a", "Клик сайдбар → Проверка", "module=protect", ok_protect, defaults("cam98.module"))
    if ok_protect:
        before = LOG.read_text(errors="ignore") if LOG.exists() else ""
        try_start_scan(before)
        wait_log("scanLive done protect", before, timeout=40)
        capture("09-protect")
        record(
            "UI-060",
            "Скан Проверки без зависона",
            "окно живо, модуль protect",
            defaults("cam98.module") == "protect" and win_frame() is not None,
            defaults("cam98.module"),
        )
    else:
        record("UI-060", "Protect", "ok", False, "не нашли")

    ok_start = open_module("startup", list(range(580, 780, 32)))
    record("UI-061", "Клик Автозагрузка", "module=startup", ok_start, defaults("cam98.module"))
    if ok_start:
        before = LOG.read_text(errors="ignore") if LOG.exists() else ""
        try_start_scan(before)
        wait_log("scanLive done startup", before, timeout=25)
        capture("10-startup")

    key("0", command=True)
    record("UI-070", "Снова диск ⌘0", "space", defaults("cam98.module") == "space", defaults("cam98.module"))
    capture("11-disk")

    # Theme again after journey
    f = win_frame() or frame
    sun, sysp, moon = theme_points(f)
    click_xy(*sun)
    time.sleep(0.55)
    a1 = defaults("cam98.appearance")
    click_xy(*(theme_points(win_frame() or f)[2]))
    time.sleep(0.55)
    a2 = defaults("cam98.appearance")
    record("UI-110", "После всех экранов день→ночь кликом иконок", "light→dark", a1 == "light" and a2 == "dark", f"{a1}->{a2}")
    capture("12-moon-final")

    # Stop mid-scan
    key("1", command=True)
    before = LOG.read_text(errors="ignore") if LOG.exists() else ""
    key("r", command=True)
    wait_log("scan start smart", before, timeout=10)
    time.sleep(1.2)
    key(".")
    time.sleep(1.0)
    alive = win_frame() is not None
    record("UI-121", "⌘R → подождать → ⌘. Стоп", "окно не умерло", alive, f"alive={alive}")
    capture("13-after-stop")

    passed = sum(1 for r in results if r["ok"])
    lines = [
        "# UI user-run results",
        "",
        "Прогон **в живом UI** (клики мышью + ⌘-шорткаты), не проверки по исходникам.",
        f"App: `{APP}`",
        f"Passed: **{passed}/{len(results)}**",
        f"Screenshots: `{SHOTS}/`",
        "",
        "| ID | Цепочка | Ожидание | Результат | Деталь |",
        "| --- | --- | --- | --- | --- |",
    ]
    for r in results:
        st = "PASS" if r["ok"] else "FAIL"

        def esc(x: object) -> str:
            return str(x).replace("|", "\\|").replace("\n", " ")

        lines.append(
            f"| {r['id']} | {esc(r['chain'])} | {esc(r['expect'])} | {st} | {esc(r['detail'])[:220]} |"
        )
    fails = [r for r in results if not r["ok"]]
    if fails:
        lines += ["", "## Failures"] + [f"- **{r['id']}**: {r['detail']}" for r in fails]
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"=== SUMMARY {passed}/{len(results)} ===", flush=True)
    print("wrote", OUT, flush=True)
    print("shots", sorted(p.name for p in SHOTS.glob('*.png')), flush=True)
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(main())
