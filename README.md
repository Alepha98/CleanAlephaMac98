<p align="center">
  <img src="docs/brand/icon.png" width="128" height="128" alt="CleanAlephaMac98">
</p>

<h1 align="center">CleanAlephaMac98</h1>

<p align="center">
  <strong>Клинер для macOS, который не ломает входы.</strong><br>
  A Mac cleaner that leaves Safari and Chrome logins alone.
</p>

<p align="center">
  <a href="https://github.com/Alepha98/CleanAlephaMac98/releases/latest/download/CleanAlephaMac98.dmg"><img src="https://img.shields.io/badge/Download-DMG-C45C6A?style=for-the-badge&logo=apple&logoColor=white" alt="Download DMG"></a>
  &nbsp;
  <a href="https://github.com/Alepha98/CleanAlephaMac98/releases/latest"><img src="https://img.shields.io/github/v/release/Alepha98/CleanAlephaMac98?style=for-the-badge&color=6B4A55&label=Release" alt="Latest release"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-6B4A55?style=flat-square" alt="Universal">
  <img src="https://img.shields.io/github/license/Alepha98/CleanAlephaMac98?style=flat-square&color=C45C6A" alt="MIT">
  <img src="https://img.shields.io/github/downloads/Alepha98/CleanAlephaMac98/total?style=flat-square&color=C45C6A" alt="Downloads">
</p>

<p align="center">
  <img src="docs/brand/og-banner.png" width="920" alt="CleanAlephaMac98 — northern light, dusty rose">
</p>

---

## Скачать

Нажми кнопку — качается **установщик `.dmg`**, не исходники.

<p align="center">
  <a href="https://github.com/Alepha98/CleanAlephaMac98/releases/latest/download/CleanAlephaMac98.dmg">
    <img src="https://img.shields.io/badge/%D0%A1%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C%20%D0%B4%D0%BB%D1%8F%20Mac-CleanAlephaMac98.dmg-C45C6A?style=for-the-badge&logo=apple&logoColor=white" alt="Скачать для Mac">
  </a>
</p>

1. Открой `CleanAlephaMac98.dmg`
2. Перетащи приложение в **Applications**
3. Первый запуск: **правый клик → Открыть**  
   (подпись Apple Developer пока ad-hoc — Gatekeeper один раз спросит)
4. Если macOS всё равно ругается: `xattr -cr /Applications/CleanAlephaMac98.app`

Для Сообщений и Telegram включи **Полный доступ к диску** в Системных настройках. Кэши Chrome/Safari чистятся и без этого.

---

## Download

Click the button. You get a **`.dmg` installer**, not a zip of source.

1. Open `CleanAlephaMac98.dmg`
2. Drag the app into **Applications**
3. First launch: **right-click → Open** (ad-hoc signed; Gatekeeper asks once)
4. If macOS still blocks it: `xattr -cr /Applications/CleanAlephaMac98.app`

Turn on **Full Disk Access** if you want Messages / Telegram in the scan. Browser caches work without it.

---

## Что умеет

- **Кэши как у больших клинеров** — `~/Library/Caches`, профили Chrome / Safari / Edge / Brave / Firefox / Яндекс. Куки и пароли не трогаем.
- **Свои исключения** — добавь папку. Или с карточки: правый клик → «Не трогать эту папку». Без правки кода.
- **Своё расписание** — свои часы, тумблер «Автоочистка». По расписанию снимаются только кэши, не медиа и не корзина.
- **Telegram сам находится** — любые аккаунты на этом Mac, не хардкод чужого компьютера.
- **Защита из коробки** — Colima, Parallels, Gradle, iOS Simulator, DeviceSupport, Claude VM, Photos. Только если эти папки реально есть.
- **Никакой телеметрии.** Всё локально, на твоём диске.

<p align="center">
  <img src="docs/brand/flask.png" width="280" alt="Glass flask">
</p>

---

## Requirements

| | |
| --- | --- |
| macOS | 14 Sonoma or newer |
| Chip | Apple Silicon and Intel (universal) |
| Disk | Full Disk Access is optional, recommended for Messages / Telegram |

---

## Privacy

No accounts. No cloud. No analytics. The auto-clean LaunchAgent lives in your user domain and writes `~/Library/Logs/CleanAlephaMac98.log`. Browser login databases are on a denylist.

---

## Build from source

```bash
git clone https://github.com/Alepha98/CleanAlephaMac98.git
cd CleanAlephaMac98
zsh packaging/install.sh
open ~/Applications/CleanAlephaMac98.app
```

Make a DMG:

```bash
zsh packaging/make-dmg.sh
open dist/CleanAlephaMac98.dmg
```

Needs Xcode Command Line Tools and macOS 14+.

---

## License

[MIT](LICENSE). Free to use, fork, and give to people who will not rebuild the app.
