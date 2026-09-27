import Foundation

enum CleanupDisposition: Sendable, Equatable {
    case safe
    case choice
    case readOnly

    var badge: Line {
        switch self {
        case .safe: Line(ru: "можно удалить", en: "safe to remove")
        case .choice: Line(ru: "решите сами", en: "your choice")
        case .readOnly: Line(ru: "только анализ", en: "read-only")
        }
    }
}

struct CleanupGuide: Sendable, Equatable {
    let disposition: CleanupDisposition
    let summary: Line
    let what: Line
    let effect: Line
}

extension JunkItem {
    /// Replaces bundle ids and opaque temp tokens in headings while keeping the exact
    /// filesystem name available in the expanded path.
    var userFacingTitle: Line {
        let raw = url.lastPathComponent
        if id.hasPrefix("artifact-file-") || module == .large || module == .duplicates {
            return title
        }
        if id.hasPrefix("dotcache-") {
            let owner = friendlyCacheOwner(raw)
            return Line(ru: "Локальный кэш · \(owner.ru)", en: "Local cache · \(owner.en)")
        }
        if id.hasPrefix("hidden-tree-") {
            return hiddenTreeTitle(raw)
        }

        var ru = title.ru
        var en = title.en
        let separators = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "·–—()[]{}«»“”\"':/\\")
        )
        let candidates = Set(([raw, ru, en].flatMap {
            $0.components(separatedBy: separators).filter { !$0.isEmpty }
        }))
        for candidate in candidates where isOpaqueStorageName(candidate) {
            let replacement = friendlyStorageName(candidate)
            ru = ru.replacingOccurrences(of: candidate, with: replacement.ru)
            en = en.replacingOccurrences(of: candidate, with: replacement.en)
        }
        return Line(ru: ru, en: en)
    }

    var cleanupGuide: CleanupGuide {
        if kind == .advice {
            return CleanupGuide(
                disposition: .readOnly,
                summary: Line(
                    ru: "Это только информация: приложение ничего здесь не удаляет.",
                    en: "Information only: the app does not remove anything here."
                ),
                what: readOnlyWhat,
                effect: Line(
                    ru: "Ничего не изменится. Карточка показывает, куда ушло место и почему автоматическая очистка здесь небезопасна.",
                    en: "Nothing changes. This card shows where the space went and why automatic cleanup is unsafe here."
                )
            )
        }

        if kind == .deleteCaptureRemnants {
            if HiddenCaptureScanner.isSafePresetCard(self) {
                return CleanupGuide(
                    disposition: .safe,
                    summary: Line(
                        ru: "Старые файлы из системной временной папки — можно удалить.",
                        en: "Old files in a system temporary folder — safe to remove."
                    ),
                    what: Line(
                        ru: "Копии изображений и видео, оставшиеся в TemporaryItems после передачи или обработки. Это не папка с чатами и не данные входа.",
                        en: "Image and video copies left in TemporaryItems after sharing or processing. This is not chat history or sign-in data."
                    ),
                    effect: Line(
                        ru: "Освободится место, аккаунты и обычные файлы не изменятся. Исчезнет только эта скрытая временная копия; если она была последней, восстановить её отсюда уже не получится.",
                        en: "Space is freed; accounts and normal files stay. Only this hidden temporary copy disappears; if it was the last copy, it cannot be recovered from here."
                    )
                )
            }
            return CleanupGuide(
                disposition: .choice,
                summary: Line(
                    ru: "Полноразмерная скрытая копия — удаляйте, только если она точно не нужна.",
                    en: "A full-size hidden copy — remove only if you no longer need it."
                ),
                what: Line(
                    ru: "Скриншот, запись экрана или локальная копия из временной папки приложения. Видимый оригинал уже мог быть удалён.",
                    en: "A screenshot, screen recording, or local app copy. The visible original may already be gone."
                ),
                effect: Line(
                    ru: "Освободится указанное место. Чаты и вход останутся, но сама скрытая копия исчезнет без возможности вернуть её из Корзины.",
                    en: "The shown space is freed. Chats and sign-in stay, but the hidden copy is removed without going to Trash."
                )
            )
        }

        let disposition: CleanupDisposition = isSafePreset ? .safe : .choice
        return CleanupGuide(
            disposition: disposition,
            summary: summary(for: disposition),
            what: plainWhat,
            effect: plainEffect
        )
    }

    private func summary(for disposition: CleanupDisposition) -> Line {
        if disposition == .safe {
            return Line(
                ru: "Можно удалить: личные файлы и данные входа не затрагиваются.",
                en: "Safe to remove: personal files and sign-in data are not touched."
            )
        }
        return Line(
            ru: "Удаляется важное или дорого восстанавливаемое — проверьте перед выбором.",
            en: "This removes important or expensive-to-restore data — review it first."
        )
    }

    private var readOnlyWhat: Line {
        if id == "dup-folder-partial-coverage" {
            return Line(
                ru: "Лимит времени закончился во время обхода больших папок. Только полностью прочитанные деревья могли стать результатом; незавершённые папки не сравнивались и не удаляются.",
                en: "The time budget ended while scanning large folders. Only fully read trees could become results; unfinished folders were not compared and cannot be removed."
            )
        }
        if id.hasPrefix("dup-folder-shared-") {
            return Line(
                ru: "Две папки имеют одинаковую структуру и содержимое, но хотя бы один файл использует общие APFS-блоки или hard link. Видимый размер не равен гарантированно освобождаемому месту.",
                en: "Two folders have identical structure and contents, but at least one file uses shared APFS blocks or a hard link. Visible size is not guaranteed reclaimable space."
            )
        }
        if id.hasPrefix("similar-capture-audit-") {
            return Line(
                ru: "Скрытое изображение выглядит как копия известного скриншота даже после переименования, уменьшения или пережатия. Это совпадение формы кадра, контуров и локального Vision-отпечатка, а не догадка по имени.",
                en: "A hidden image still looks like a known screenshot after renaming, resizing, or recompression. The match uses frame shape, edges, and an on-device Vision fingerprint rather than the filename."
            )
        }
        if id == "similar-capture-partial-coverage" {
            return Line(
                ru: "Глубокое сравнение достигло лимита времени. Показанные совпадения проверены, но часть изображений будет проверена в следующий проход.",
                en: "Deep comparison reached its time limit. Reported matches are verified, but some images will be checked on the next pass."
            )
        }
        if id == "system-audit-storage-ledger" {
            return Line(
                ru: "Это не обычная папка. Сюда входят блоки APFS-снимков, системно удаляемые данные и версии документов: файл уже может исчезнуть из Finder и Корзины, но старые блоки ещё некоторое время остаются на диске.",
                en: "This is not an ordinary folder. It includes APFS snapshot blocks, purgeable data, and document versions: a file may be gone from Finder and Trash while older blocks remain on disk for a while."
            )
        }
        if id.hasPrefix("dup-hardlink-") {
            return Line(
                ru: "Два пути указывают на один и тот же физический файл. Это hard link, а не лишняя вторая копия; место освободится только после удаления последней ссылки.",
                en: "Two paths point to the same physical file. This is a hard link, not an extra stored copy; space is released only after the last link is removed."
            )
        }
        if id.hasPrefix("dup-clone-") || id.hasPrefix("large-shared-") {
            return Line(
                ru: "APFS хранит эту видимую копию на общих блоках с другим файлом. Удаление одного имени может не вернуть место, поэтому приложение не считает этот размер очищаемым.",
                en: "APFS stores this visible copy on blocks shared with another file. Removing one path may reclaim no space, so the app does not count it as cleanable."
            )
        }
        if id.hasPrefix("system-audit-") {
            if id.contains("swap") || id.contains("var-vm") {
                return Line(
                    ru: "Рабочая память, которую macOS временно перенесла на диск. Система сама меняет её размер.",
                    en: "Working memory that macOS temporarily moved to disk. The system manages its size automatically."
                )
            }
            if id.contains("diagnostic") || id.contains("powerlog") || id.contains("uuidtext")
                || id.contains("var-log") || id.contains("library-logs") {
                return Line(
                    ru: "Системные журналы macOS: они помогают разбирать сбои, расход батареи и работу служб.",
                    en: "macOS diagnostic logs used to investigate crashes, power use, and system services."
                )
            }
            if id.contains("darwin-temporary") || id.contains("sharedTemporary") {
                return Line(
                    ru: "Общая временная зона macOS. В ней смешаны старые остатки и файлы, которые прямо сейчас нужны запущенным программам.",
                    en: "A shared macOS temporary area containing both old remnants and files currently used by running apps."
                )
            }
            return Line(
                ru: "Системное хранилище macOS. Его размер показан для понимания, но удалять содержимое целиком нельзя.",
                en: "A macOS system store. Its size is shown for context, but its contents must not be removed wholesale."
            )
        }
        if id == "ai-cursor-state-db" {
            return Line(
                ru: "Главная локальная база Cursor. В ней вместе лежат живые чаты, настройки, индексы и следы удалённых записей.",
                en: "Cursor's main local database, containing active chats, settings, indexes, and traces of deleted records together."
            )
        }
        if id.contains("orphan-chat") || id.contains("orphan-rollout") || id.contains("orphan-output") {
            return Line(
                ru: "Следы удалённых AI-чатов или задач. Они найдены анализом связей, но безопасная граница удаления ещё не доказана.",
                en: "Remnants of deleted AI chats or tasks. Link analysis found them, but a safe deletion boundary is not yet proven."
            )
        }
        if id.contains("cursor") || id.contains("codex") || id.contains("claude") {
            return Line(
                ru: "Локальное хранилище AI-приложения. Внутри могут быть связанные чаты, outputs, индексы и служебные блоки.",
                en: "Local AI-app storage. It may contain linked chats, outputs, indexes, and internal blocks."
            )
        }
        if id.hasPrefix("hidden-tree-") {
            let lower = url.lastPathComponent.lowercased()
            if [".ssh", ".gnupg", ".aws", ".kube"].contains(lower) {
                return Line(
                    ru: "Скрытые ключи и настройки доступа. Они нужны для входа на серверы и в облачные сервисы.",
                    en: "Hidden access keys and configuration used to sign in to servers and cloud services."
                )
            }
            if [".git", ".svn", ".hg"].contains(lower) {
                return Line(
                    ru: "История версий проекта: коммиты, ветки и данные для восстановления изменений.",
                    en: "Project version history: commits, branches, and data used to restore changes."
                )
            }
            return Line(
                ru: "Скрытые данные проекта или программы. Сканер не смог доказать, что их можно создать заново без потерь.",
                en: "Hidden project or app data that the scanner could not prove can be rebuilt without loss."
            )
        }
        if id.hasPrefix("forensic-") || id.hasPrefix("deep-media-") || id.hasPrefix("intel-") {
            return Line(
                ru: "Глубокая карта скрытого хранилища. Она показывает найденные медиа и занятое место, но не удаляет папку целиком.",
                en: "A deep map of hidden storage showing discovered media and used space without deleting the whole folder."
            )
        }
        return Line(
            ru: "Найденное хранилище, для которого нельзя доказать безопасную границу удаления.",
            en: "A discovered store without a provably safe deletion boundary."
        )
    }

    private var plainWhat: Line {
        switch module {
        case .trash:
            return Line(ru: "Файлы, которые уже перемещены в Корзину и пока ещё могут быть восстановлены через Finder.", en: "Files already moved to Trash that Finder can still restore.")
        case .duplicates:
            if id.hasPrefix("dup-folder-") {
                return Line(
                    ru: "Целая дополнительная папка: совпадают все вложенные папки, имена, размеры и полный SHA-256 каждого файла. Сохраняемая папка указана в карточке.",
                    en: "A whole extra folder: every nested folder, filename, size, and full-file SHA-256 matches. The folder being kept is shown on the card."
                )
            }
            if id.hasPrefix("similar-capture-file-") {
                return Line(
                    ru: "Визуально почти такая же копия скриншота. Она могла получить другое имя, размер или JPEG-сжатие, поэтому побайтовое сравнение её не видит.",
                    en: "A visually near-identical screenshot copy. Its name, dimensions, or JPEG compression may differ, so byte-for-byte comparison cannot find it."
                )
            }
            return Line(ru: "Побайтово одинаковая дополнительная копия файла. Путь сохраняемой копии указан в карточке.", en: "A byte-for-byte extra copy. The copy being kept is shown on the card.")
        case .large:
            return Line(ru: "Обычный пользовательский файл большого размера: видео, архив, образ диска или документ.", en: "A normal large user file: video, archive, disk image, or document.")
        case .leftovers:
            return Line(ru: "Настройки, кэш или служебные файлы приложения, которого больше нет в Applications.", en: "Settings, cache, or support files for an app no longer in Applications.")
        case .browsers:
            return Line(ru: "Кэш страниц, изображений и сетевых ответов браузера. Пароли, cookies и профили защищены отдельно.", en: "Cached pages, images, and network responses. Passwords, cookies, and profiles are protected separately.")
        case .dev:
            return Line(ru: "Скачанные пакеты, результаты сборки или инструменты разработки, которые можно создать или скачать заново.", en: "Downloaded packages, build products, or developer tools that can be rebuilt or downloaded again.")
        case .messengers:
            if id.contains("tg-d-") || title.ru.localizedCaseInsensitiveContains("истори") {
                return Line(ru: "Локальная база истории сообщений. Это не обычный кэш.", en: "A local message-history database. This is not a normal cache.")
            }
            return Line(ru: "Локальные копии фото, видео и других вложений мессенджера. Данные входа хранятся отдельно.", en: "Local copies of messenger photos, videos, and attachments. Sign-in data is stored separately.")
        case .privacy:
            return Line(ru: "История посещений или список недавних документов. Пароли и данные входа сюда не входят.", en: "Browsing history or recent-document lists. Passwords and sign-in data are not included.")
        case .protect:
            return Line(ru: "Подозрительное приложение, расширение или фоновый агент, найденный проверкой безопасности.", en: "A suspicious app, extension, or background agent found by the security check.")
        case .startup:
            return Line(ru: "Фоновый агент или приложение, которое запускается при входе в macOS.", en: "A background agent or app that starts when you sign in to macOS.")
        case .pulse:
            return Line(ru: "Текущая нагрузка приложения, процесса или вкладки. Это не дисковый мусор.", en: "Current load from an app, process, or tab. This is not disk junk.")
        case .mail:
            return Line(ru: "Локальные копии почтовых вложений и временные данные Mail.", en: "Local copies of mail attachments and temporary Mail data.")
        case .junk, .smart:
            if id.hasPrefix("artifact-file-") {
                if ArtifactScanner.isSafePresetCard(self) {
                    return Line(
                        ru: "Недокачанный файл, оставшийся после прерванной или неудачной загрузки. Готового файла внутри нет.",
                        en: "An unfinished file left by an interrupted or failed download. It does not contain a completed download."
                    )
                }
                return Line(ru: "Старый файл на Рабочем столе или в Загрузках, найденный по типу и возрасту.", en: "An old Desktop or Downloads file found by type and age.")
            }
            if id.hasPrefix("hidden-tree-cache-") {
                return Line(
                    ru: "Скрытый кэш сборки проекта. Инструмент разработки создаёт эту папку заново из исходников.",
                    en: "A hidden project build cache that development tools recreate from source files."
                )
            }
            if id.hasPrefix("darwin-cache-") {
                return Line(
                    ru: "Кэш приложения в закрытой служебной зоне текущего пользователя macOS. Это не документы и не данные входа.",
                    en: "App cache in the current macOS user's private runtime area. It is not documents or sign-in data."
                )
            }
            if id.hasPrefix("private-tmp-") || id.hasPrefix("darwin-temp-") {
                return Line(
                    ru: "Старая рабочая папка, которую программа создала для временной операции и не убрала после завершения.",
                    en: "An old work folder an app created for a temporary operation and left behind afterward."
                )
            }
            if id.hasPrefix("ai-") {
                return Line(
                    ru: "Старая версия компонента, установочный остаток или лог AI-приложения. Активные чаты и проекты лежат отдельно.",
                    en: "An old component version, install remnant, or AI-app log. Active chats and projects are stored separately."
                )
            }
            return Line(ru: "Кэш, лог или временные служебные файлы приложения или macOS.", en: "Cache, logs, or temporary support files from an app or macOS.")
        case .space, .tools:
            return Line(ru: "Информация о занятом месте на диске.", en: "Information about disk usage.")
        }
    }

    private var plainEffect: Line {
        switch module {
        case .trash:
            return Line(ru: "Файлы удалятся окончательно и больше не восстановятся из Корзины.", en: "The files are permanently removed and can no longer be restored from Trash.")
        case .duplicates:
            if id.hasPrefix("dup-folder-") {
                return Line(
                    ru: "Удалится только выбранная папка-дубликат целиком. Перед удалением приложение заново проверит обе папки; при любом изменении операция будет отменена, а указанная копия останется.",
                    en: "Only the selected duplicate folder is removed. The app rechecks both folders immediately before deletion; any change cancels the operation, and the referenced copy remains."
                )
            }
            if id.hasPrefix("similar-capture-file-") {
                return Line(
                    ru: "Удалится только выбранная похожая картинка; эталон по указанному пути останется. Из-за возможных небольших различий пункт никогда не выбирается автоматически.",
                    en: "Only the selected similar image is removed; the referenced copy stays. Because small differences may matter, this item is never selected automatically."
                )
            }
            return Line(ru: "Эта копия удалится окончательно; одна подтверждённо одинаковая копия останется по указанному пути.", en: "This copy is permanently removed; one verified identical copy remains at the shown path.")
        case .large:
            return Line(ru: "Сам файл удалится окончательно. Приложение не сможет вернуть его автоматически.", en: "The file itself is permanently removed. The app cannot restore it automatically.")
        case .leftovers:
            return Line(ru: "Освободится место. При повторной установке приложения старые настройки или локальные данные уже не вернутся.", en: "Space is freed. Reinstalling the app will not bring these old settings or local data back.")
        case .browsers:
            return Line(ru: "Первое открытие сайтов может быть чуть медленнее: изображения и страницы загрузятся заново. Входы останутся.", en: "Sites may open a little slower once while pages and images download again. Sign-ins stay.")
        case .dev:
            if isRebuildCache {
                return Line(ru: "Проекты и исходники останутся, но следующая сборка или запуск скачает большой объём заново.", en: "Projects and source files stay, but the next build or run may download a large amount again.")
            }
            return Line(ru: "Исходники останутся. Следующая сборка займёт больше времени или повторно скачает зависимости.", en: "Source files stay. The next build may take longer or download dependencies again.")
        case .messengers:
            if id.contains("tg-d-") || title.ru.localizedCaseInsensitiveContains("истори") {
                return Line(ru: "Можно потерять локальную историю и офлайн-данные. Поэтому пункт не входит в безопасный выбор.", en: "Local history and offline data may be lost, so this item is not part of Safe selection.")
            }
            return Line(ru: "Вложения исчезнут с диска и при необходимости загрузятся снова. Аккаунт и ключи входа останутся.", en: "Attachments leave the disk and download again when needed. The account and sign-in keys stay.")
        case .privacy:
            return Line(ru: "Списки истории исчезнут. Пароли останутся, но вернуть удалённую историю приложение не сможет.", en: "History lists disappear. Passwords stay, but the removed history cannot be restored by the app.")
        case .protect:
            return Line(ru: "Выбранный объект перестанет работать или запускаться. Проверяйте незнакомые находки перед удалением.", en: "The selected item stops working or launching. Review unfamiliar findings before removal.")
        case .startup:
            return Line(ru: "Приложение останется установленным, но перестанет автоматически запускаться при входе.", en: "The app stays installed but no longer starts automatically at sign-in.")
        case .pulse:
            return Line(ru: "Для вкладки действие закроет её. Приложения и системные процессы автоматически не удаляются.", en: "For a tab, the action closes it. Apps and system processes are not automatically removed.")
        case .mail:
            return Line(ru: "Вложения могут загрузиться снова из почтового сервера; без интернета они временно будут недоступны.", en: "Attachments may download again from the mail server; they may be unavailable while offline.")
        case .junk, .smart:
            if id.hasPrefix("artifact-file-") {
                if ArtifactScanner.isSafePresetCard(self) {
                    return Line(
                        ru: "Удалится только незавершённая загрузка. Если файл всё ещё нужен, его придётся скачать заново с начала.",
                        en: "Only the unfinished download is removed. If you still need it, you will have to download it again."
                    )
                }
                return Line(ru: "Удалится сам найденный файл. Для обычного скриншота или output это необратимо.", en: "The discovered file itself is removed. For a normal screenshot or output, this is permanent.")
            }
            if id.hasPrefix("hidden-tree-cache-") {
                return Line(
                    ru: "Исходники не изменятся. Первая следующая сборка будет дольше, потому что кэш создастся заново.",
                    en: "Source files stay unchanged. The next build will take longer while the cache is recreated."
                )
            }
            if id.hasPrefix("darwin-cache-") || id.hasPrefix("private-tmp-") || id.hasPrefix("darwin-temp-") {
                return Line(
                    ru: "Освободится место. При необходимости программа создаст новые временные данные; аккаунты и документы останутся.",
                    en: "Space is freed. The app can create fresh temporary data when needed; accounts and documents stay."
                )
            }
            if id.hasPrefix("ai-") {
                return Line(
                    ru: "Текущая версия приложения и чаты останутся. Удалённый компонент при необходимости придётся скачать заново.",
                    en: "The current app version and chats stay. The removed component may need to be downloaded again later."
                )
            }
            return Line(ru: "Освободится место. Кэш создастся снова при необходимости; документы и настройки останутся.", en: "Space is freed. Cache is recreated when needed; documents and settings stay.")
        case .space, .tools:
            return Line(ru: "Ничего не удаляется.", en: "Nothing is removed.")
        }
    }

    private func isOpaqueStorageName(_ value: String) -> Bool {
        let lower = value.lowercased()
        let dotParts = lower.split(separator: ".")
        if dotParts.count >= 3 && !value.contains(" ") { return true }
        let compact = lower.filter(\.isLetter).count + lower.filter(\.isNumber).count
        if value.count >= 24 && compact >= value.count - 4 { return true }
        return false
    }

    private func friendlyStorageName(_ value: String) -> Line {
        if let owner = SessionGuard.ownerName(for: url) { return Line.proper(owner) }
        let lower = value.lowercased()
        let known: [(String, String)] = [
            ("google.chrome", "Google Chrome"), ("microsoft.vscode", "Visual Studio Code"),
            ("figma", "Figma"), ("whatsapp", "WhatsApp"), ("torbrowser", "Tor Browser"),
            ("lemon.lvoverseas", "CapCut"), ("ndemiccreations", "Ndemic Creations"),
            ("adspower", "AdsPower"), ("anty", "Anty")
        ]
        if let match = known.first(where: { lower.contains($0.0) }) {
            return Line.proper(match.1)
        }
        let ignored = Set(["com", "org", "net", "ru", "app", "helper", "plugin", "renderer", "cache"])
        let words = value.split { $0 == "." || $0 == "-" || $0 == "_" }
            .map(String.init)
            .filter { !ignored.contains($0.lowercased()) && $0.count > 1 }
        if !words.isEmpty {
            return Line.proper(words.suffix(2).joined(separator: " "))
        }
        return Line(ru: "служебная папка", en: "support folder")
    }

    private func friendlyCacheOwner(_ value: String) -> Line {
        let lower = value.lowercased()
        let known: [(key: String, ru: String, en: String)] = [
            ("huggingface", "Hugging Face", "Hugging Face"),
            ("codex-runtimes", "компоненты Codex", "Codex components"),
            ("pip", "пакеты Python", "Python packages"),
            ("uv", "пакеты Python uv", "Python uv packages"),
            ("npm", "пакеты npm", "npm packages"),
            ("yarn", "пакеты Yarn", "Yarn packages"),
            ("playwright", "браузеры Playwright", "Playwright browsers")
        ]
        if let match = known.first(where: { lower.contains($0.key) }) {
            return Line(ru: match.ru, en: match.en)
        }
        return friendlyStorageName(value)
    }

    private func hiddenTreeTitle(_ value: String) -> Line {
        switch value.lowercased() {
        case ".git", ".svn", ".hg":
            return Line(ru: "История версий проекта", en: "Project version history")
        case ".ssh", ".gnupg", ".aws", ".kube":
            return Line(ru: "Ключи и настройки доступа", en: "Access keys and configuration")
        case ".cursor": return Line(ru: "Локальные данные Cursor", en: "Cursor local data")
        case ".claude": return Line(ru: "Локальные данные Claude", en: "Claude local data")
        case ".codex": return Line(ru: "Локальные данные Codex", en: "Codex local data")
        default:
            if id.hasPrefix("hidden-tree-cache-") {
                return Line(ru: "Кэш сборки проекта", en: "Project build cache")
            }
            return Line(ru: "Скрытые данные проекта или программы", en: "Hidden project or app data")
        }
    }
}
