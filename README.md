<p align="center">
  <img src="docs/brand/icon.png" width="128" height="128" alt="CleanAlephaMac98">
</p>

<h1 align="center">CleanAlephaMac98</h1>

<p align="center">
  <strong>Клинер для Mac.</strong><br>
  A Mac cleaner.
</p>

<p align="center">
  <a href="https://github.com/Alepha98/CleanAlephaMac98/releases/latest/download/CleanAlephaMac98.dmg"><img src="https://img.shields.io/badge/Download-DMG-C45C6A?style=for-the-badge&logo=apple&logoColor=white" alt="Download DMG"></a>
  &nbsp;
  <a href="https://github.com/Alepha98/CleanAlephaMac98/releases/latest"><img src="https://img.shields.io/github/v/release/Alepha98/CleanAlephaMac98?style=for-the-badge&color=6B4A55&label=Release" alt="Latest release"></a>
  &nbsp;
  <a href="https://github.com/Alepha98/CleanAlephaMac98/releases"><img src="https://img.shields.io/github/downloads/Alepha98/CleanAlephaMac98/total?style=for-the-badge&color=C45C6A&label=Downloads" alt="Downloads"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-6B4A55?style=flat-square" alt="Universal">
  <img src="https://img.shields.io/github/license/Alepha98/CleanAlephaMac98?style=flat-square&color=C45C6A" alt="MIT">
  <a href="https://github.com/Alepha98/CleanAlephaMac98/releases"><img src="https://img.shields.io/github/downloads/Alepha98/CleanAlephaMac98/total?style=flat-square&color=C45C6A&label=downloads" alt="Total downloads"></a>
</p>

---

## Скачать

<p align="center">
  <a href="https://github.com/Alepha98/CleanAlephaMac98/releases/latest/download/CleanAlephaMac98.dmg">
    <img src="https://img.shields.io/badge/%D0%A1%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C%20%D0%B4%D0%BB%D1%8F%20Mac-CleanAlephaMac98.dmg-C45C6A?style=for-the-badge&logo=apple&logoColor=white" alt="Скачать для Mac">
  </a>
</p>

1. Открой `CleanAlephaMac98.dmg`
2. Перетащи приложение в **Applications**
3. Первый запуск: **правый клик → Открыть**

Для Сообщений и Telegram включи **Полный доступ к диску**. Кэши Chrome и Safari чистятся и без этого.

## Что умеет

- Кэши браузеров, логи, мессенджеры
- Глубокий слой macOS: старые cache/temp текущего пользователя внутри `/private/var/folders`, включая все оставшиеся Darwin hash-корни этого UID, и принадлежащие ему деревья в `/private/tmp`; внутренние symlink допустимы, ссылки наружу блокируют чистку
- Полноразмерные скрытые копии скриншотов и записей из Darwin temp, `group.com.apple.screencapture/ScreenRecordings`, QuickTime Autosave, Claude и Cursor
- Любые `~/Library/Containers/*/Data/tmp/TemporaryItems` и групповые `TemporaryItems` находятся динамически; старые изображения/видео и точные полные дубли показываются отдельной карточкой и входят в «Отметить безопасное», а свежие файлы и хранилище открытого приложения не очищаются
- Отдельно проверяются реальные runtime-корни `T/TemporaryItems`, `T/com.apple.replayd/TemporaryItems`, ScreenCaptureUI, FileProvider/bird и Quick Look; внутри `T/TemporaryItems` распознаются полноразмерные остатки `NSIRD_screencaptureui_*`, а при TCC-запрете Finder-мост показывает их реальный объём только для аудита
- Глобальный форензик-поиск снимков через метаданные macOS и всех проиндексированных скрытых медиа без списка приложений; закрытые `DocumentRevisions`, `TemporaryItems`, ScreenCapture/replayd, QuickTime и Quick Look не считаются пустыми, а требуют Full Disk Access
- Бинарный forensic-проход независимо от Spotlight читает сигнатуры каждого доступного скрытого файла больше 64 KiB, поэтому находит изображения и видео без расширений или с ложными именами и группирует их по реальному owner-пути
- Telegram-медиа без расширения распознаются по содержимому и quarantine-origin; `tdata`, аккаунты и запущенный Telegram остаются защищены
- Скриншоты, отправленные в Telegram, сопоставляются даже после переименования и пережатия: сначала полный SHA-256, затем локальный пиксельный отпечаток; результат только для аудита, базы чатов не читаются
- Скрытое AI-хранилище Cursor: огромная база чатов видна как аудит, а `.trash` и версии расширений, помеченные Cursor как obsolete, очищаются отдельно
- Остатки удалённых AI-чатов отделяются по связности: строки Cursor без `composerHeaders` и кандидаты `agentKv:blob` вычисляются консервативным read-only графом protobuf-ссылок, а перед будущим удалением обязателен native Cursor GC; rollout Codex без живой/архивной задачи, outputs без thread ID и рабочие контейнеры Claude без индексного JSON показываются отдельными audit-карточками
- Сканируются обе корзины macOS: обычная `~/.Trash` и отдельная скрытая `~/Library/Mobile Documents/.Trash` у iCloud Drive; отказ TCC больше не выглядит как «корзина пустая»
- Контентный глубокий индекс: находит неизвестные заранее скрытые хранилища, кэши, старые uploads/outputs и точные медиа-копии по содержимому и фактически занятым блокам
- Дубликаты проходят размер → три сэмпла → полный SHA-256; hard links и APFS-клоны распознаются отдельно и не раздувают обещание очистки, а меняющийся во время хеширования файл отбрасывается
- Переименованные, уменьшенные и пережатые копии скриншотов ищутся отдельно: строгий пиксельный фильтр подтверждается локальным Apple Vision-отпечатком; обычные файлы остаются ручным выбором, скрытые копии — только аудитом
- Дубликаты теперь охватывают Desktop, Documents, Downloads, Pictures и Movies; большие группы обрабатываются от крупнейших к меньшим, а лимит выдачи поднят с 60 до 240 точных копий
- SHA-256 и пиксельные отпечатки кешируются без путей и содержимого; inode, размер, mtime и ctime автоматически сбрасывают запись после любого изменения файла
- Большие файлы показывают физический объём: sparse-файл, облачная заглушка и APFS-клон больше не выдаются за полностью освобождаемый размер
- Системно удерживаемое место вынесено в отдельный read-only баланс: свободно сейчас, резерв macOS, APFS-снимки и версии документов; эта цифра не прибавляется к «можно очистить»
- Аудит системных логов, diagnostics/uuidtext/powerlog, физических swap-файлов, sleepimage и APFS-снимков без опасного автоудаления; все runtime `TemporaryItems` обнаруживаются динамически, даже если сервис заранее неизвестен
- Привилегированный read-only аудит закрытых `.DocumentRevisions-V100`, всех скрытых деревьев Data-тома и `/private/var/root/.Trash`; iCloud/FileProvider placeholders и файлы без локальных блоков никогда не открываются
- Скрытая root-корзина всегда audit-only: она не входит в Safe/Auto и не очищается без отдельного подтверждённого привилегированного действия
- Старые скриншоты, незавершённые загрузки и outputs Claude / ChatGPT / Codex (с подтверждением)
- «Отметить безопасное» добавляет кэши, логи, незавершённые загрузки, проверенные build-кэши и старые контейнерные `TemporaryItems`, не снимая уже сделанный ручной выбор
- У каждой карточки есть простой статус «можно удалить / решите сами / только анализ» и раскрываемые ответы «Что это», «Что изменится», «Где лежит»; технические bundle-ID спрятаны из заголовка, но точный путь всегда доступен
- Защита аккаунтов: сессионные файлы не удаляются, активное приложение сначала нужно закрыть
- Свои исключения – папка или правый клик по карточке
- Быстродействие – память, CPU, вкладки
- Проверка – adware и странные агенты
- Автозагрузка
- Расписание автоочистки кэшей
- Без телеметрии
- Privacy manifest: без tracking и сбора данных; доступ к размеру диска, времени файлов и локальным настройкам заявлен только для функций интерфейса

<p align="center">
  <img src="docs/brand/icon.png" width="220" height="220" alt="CleanAlephaMac98">
</p>

---

## Download

1. Open `CleanAlephaMac98.dmg`
2. Drag the app into **Applications**
3. First launch: **right-click → Open**

Turn on **Full Disk Access** if you want Messages and Telegram in the scan. Browser caches work without it.

## What it does

- Browser caches, logs, messengers
- Deep macOS layer: stale current-user cache/temp inside `/private/var/folders`, including every surviving Darwin hash root owned by this uid, plus current-user trees in `/private/tmp`; contained symlinks are allowed while escaping links and mounted APFS trees block cleanup
- Full-size hidden screenshot/recording copies from Darwin temp, `group.com.apple.screencapture/ScreenRecordings`, QuickTime Autosave, Claude, and Cursor
- Every `~/Library/Containers/*/Data/tmp/TemporaryItems` and group `TemporaryItems` store is discovered dynamically; old images/videos and byte-exact full duplicates get a separate card included by “Select safe items”, while fresh files and stores owned by a running app are not cleaned
- Runtime roots are probed explicitly: `T/TemporaryItems`, `T/com.apple.replayd/TemporaryItems`, ScreenCaptureUI, FileProvider/bird, and Quick Look; full-size `NSIRD_screencaptureui_*` remnants are classified directly, while a read-only Finder bridge reports their real size when TCC denies normal traversal
- A global forensic pass uses macOS metadata and every indexed hidden media file without an app catalogue; denied `DocumentRevisions`, `TemporaryItems`, ScreenCapture/replayd, QuickTime, and Quick Look stores are reported as requiring Full Disk Access instead of empty
- A Spotlight-independent binary pass probes every accessible hidden file above 64 KiB, finds extensionless/misnamed images and videos by magic bytes, and groups them under the actual owner path
- Normal Trash and the separate hidden iCloud Drive `~/Library/Mobile Documents/.Trash` are both scanned; a TCC denial is reported as unknown rather than empty
- Extensionless Telegram media is identified by file contents and quarantine origin; `tdata`, accounts, and a running Telegram stay protected
- Screenshots sent through Telegram are correlated even after renaming or recompression: full SHA-256 first, then an on-device pixel fingerprint; results are audit-only and chat databases are never read
- Hidden Cursor AI storage: the large chat database is surfaced read-only, while `.trash` and Cursor-marked obsolete extension versions are cleaned separately
- Deleted AI history remnants are separated by reachability: Cursor rows without `composerHeaders` plus candidate `agentKv:blob` objects are audited with a conservative read-only protobuf graph and require native Cursor GC before any future deletion; Codex rollouts without a live/archive task, outputs without a thread ID, and Claude work containers without their index JSON become dedicated audit cards
- Blind hidden-tree inventory: every outer `.*` tree in the home/work folders is measured before classification; unknown stores, VMs, databases, environments, and source control stay read-only, while proven project build caches are opt-in
- Old Cursor Agent versions, abandoned Codex runtime staging folders, and OpenCode diagnostic logs are separated from chats and sign-in data
- Content-driven deep index: discovers previously unknown hidden stores, caches, old uploads/outputs, and exact media copies by contents and allocated disk blocks
- Duplicate detection uses size → three samples → full SHA-256; hard links and APFS clones are separated and never inflate the cleanup promise, while a file changing during hashing is rejected
- Renamed, resized, and recompressed screenshot copies use a strict pixel prefilter plus an on-device Apple Vision feature print; normal files remain manual-only and hidden matches stay read-only
- Duplicate coverage now includes Desktop, Documents, Downloads, Pictures, and Movies; largest groups are processed first and up to 240 exact extra copies are shown instead of 60
- Whole duplicate folders are collapsed into one manual-choice card only after every nested path, size, and full-file SHA-256 matches; any change before cleanup cancels deletion
- Folder scans resume from a persisted rotating top-level queue: one huge project cannot starve other roots, unfinished trees never become results, and the next pass starts elsewhere
- Hidden folders are included, but PostgreSQL/MongoDB/MySQL/Redis/Elasticsearch stores are rejected by path and engine markers even when their pages are byte-identical
- SHA-256 and pixel fingerprints are cached without paths or contents; inode, size, mtime, and ctime invalidate a record whenever the file changes
- Large-file results use physical allocation: sparse files, cloud placeholders, and APFS clones are no longer presented as fully reclaimable logical sizes
- macOS-managed storage has a separate read-only ledger for immediately free capacity, the system reclaimable reserve, APFS snapshots, and document versions; it is excluded from “cleanable” totals
- Read-only audit of system logs, diagnostics/uuidtext/powerlog, physical swap files, sleepimage, and APFS snapshots; every runtime `TemporaryItems` store is discovered dynamically even when its owning service is unknown
- Privileged read-only audit for protected `.DocumentRevisions-V100`, every hidden Data-volume tree, and `/private/var/root/.Trash`; iCloud/FileProvider placeholders and files without local blocks are never opened
- Hidden root Trash is always audit-only: it never enters Safe/Auto and cannot be cleaned without a separate confirmed privileged action
- Old screenshots, incomplete downloads, and outputs from Claude / ChatGPT / Gemini / Copilot and other AI tools (opt-in)
- “Select safe items” adds caches, logs, incomplete downloads, proven build caches, and old container `TemporaryItems` without clearing choices the user already made
- Every result has a plain “safe to remove / your choice / read-only” status plus expandable “What this is”, “What changes”, and exact location; opaque bundle IDs are hidden from headings but preserved in the path
- Whole stale iPhone/iPad local backups (opt-in; never individual backup blobs)
- Exact duplicates are always confirmed by a complete-file hash; samples only avoid unnecessary full reads
- Login/session stores such as `HTTPStorages`, cookies, browser profiles, Telegram `tdata`, and iCloud session state are protected
- Account protection: session files stay; quit an active app before cleaning its cache
- Your exclusions – add a folder or right-click a card
- Performance – RAM, CPU, tabs
- Check – adware and odd agents
- Startup items
- Scheduled cache cleanup
- No telemetry
- Bundled privacy manifest declares no tracking or data collection

macOS 14+, Apple Silicon and Intel.

---

## License

[MIT](LICENSE).
