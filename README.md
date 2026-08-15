<p align="center">
  <img src="docs/brand/icon.png" width="128" height="128" alt="CleanAlephaMac98">
</p>

<h1 align="center">CleanAlephaMac98</h1>

<p align="center">
  <strong>Клинер для Mac. Логины Safari и Chrome не трогаем.</strong><br>
  A Mac cleaner. Safari and Chrome logins stay.
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
  <img src="https://img.shields.io/github/actions/workflow/status/Alepha98/CleanAlephaMac98/build.yml?style=flat-square" alt="Build">
</p>

---

## Скачать

Кнопка выше – это `.dmg`, не архив с исходниками.

<p align="center">
  <a href="https://github.com/Alepha98/CleanAlephaMac98/releases/latest/download/CleanAlephaMac98.dmg">
    <img src="https://img.shields.io/badge/%D0%A1%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C%20%D0%B4%D0%BB%D1%8F%20Mac-CleanAlephaMac98.dmg-C45C6A?style=for-the-badge&logo=apple&logoColor=white" alt="Скачать для Mac">
  </a>
</p>

1. Открой `CleanAlephaMac98.dmg`
2. Перетащи в **Applications**
3. Первый запуск: **правый клик → Открыть**  
   Подпись пока ad-hoc, Gatekeeper один раз спросит.
4. Если всё равно орёт: `xattr -cr /Applications/CleanAlephaMac98.app`

Для Сообщений и Telegram включи **Полный доступ к диску**. Кэши Chrome и Safari чистятся и без этого.

## Что умеет

- Кэши браузеров, логи, мессенджеры. Куки и пароли не трогаем.
- Свои исключения – добавь папку, или с карточки правым кликом: «Не трогать эту папку».
- Память – кто жрёт RAM и какие вкладки открыты. Браузер не закрываем.
- Проверка – известный adware и странные агенты. Не антивирус.
- Автозагрузка – что стартует вместе с тобой.
- Расписание – свои часы. По таймеру снимаются только кэши, не медиа и не корзина.
- Telegram находится сам, на этом Mac.
- Colima, Parallels, Gradle, симулятор, DeviceSupport, Claude VM, Photos – не трогаем, если они есть.
- Телеметрии нет. Всё локально.

<p align="center">
  <img src="docs/brand/flask.png" width="280" alt="Glass flask">
</p>

---

## Download

The button is a `.dmg`. Not a zip of the repo.

1. Open `CleanAlephaMac98.dmg`
2. Drag it into **Applications**
3. First launch: **right-click → Open** (ad-hoc signed, Gatekeeper asks once)
4. If macOS still blocks it: `xattr -cr /Applications/CleanAlephaMac98.app`

Turn on **Full Disk Access** if you want Messages and Telegram in the scan. Browser caches work without it.

## What it does

- Browser caches, logs, messengers. Cookies and passwords stay.
- Your exclusions – add a folder, or right-click a card: “Don't touch this folder”.
- Memory – what's eating RAM, which tabs are open. We don't quit the browser.
- Check – known adware and odd agents. Not an antivirus.
- Startup – what launches when you log in.
- Schedule – your hours. The timer only clears caches, not media, not Trash.
- Telegram is found on this Mac, not hardcoded from someone else's.
- Colima, Parallels, Gradle, Simulator, DeviceSupport, Claude VM, Photos – left alone if they're there.
- No telemetry. It lives on your disk.

macOS 14+, Apple Silicon and Intel.

---

## Build from source

```bash
git clone https://github.com/Alepha98/CleanAlephaMac98.git
cd CleanAlephaMac98
zsh packaging/install.sh
open ~/Applications/CleanAlephaMac98.app
```

DMG:

```bash
zsh packaging/make-dmg.sh
open dist/CleanAlephaMac98.dmg
```

Needs Xcode Command Line Tools.

---

## License

[MIT](LICENSE). Use it, fork it, give it to whoever.
