import SwiftUI

enum CopyLang: String, Sendable {
    case ru, en
}

enum LanguageChoice: String, CaseIterable, Identifiable {
    case system, ru, en
    var id: String { rawValue }

    func resolved(locale: Locale = .current) -> CopyLang {
        switch self {
        case .ru: .ru
        case .en: .en
        case .system:
            locale.language.languageCode?.identifier == "en" ? .en : .ru
        }
    }

    func title(_ lang: CopyLang) -> String {
        switch self {
        case .system: Line(ru: "Как в системе", en: "System").t(lang)
        case .ru: "Русский"
        case .en: "English"
        }
    }
}

struct Line: Equatable, Sendable {
    var ru: String
    var en: String
    func t(_ lang: CopyLang) -> String { lang == .en ? en : ru }
    static func proper(_ s: String) -> Line { Line(ru: s, en: s) }
}

private struct CopyLangKey: EnvironmentKey {
    static let defaultValue: CopyLang = .ru
}

extension EnvironmentValues {
    var copyLang: CopyLang {
        get { self[CopyLangKey.self] }
        set { self[CopyLangKey.self] = newValue }
    }
}

/// UX writer table: Russian is source, English is written, not machine-translated (TZ-03 §28 / §10).
enum Copy {
    static let personalMac = Line(ru: "личный Mac", en: "this Mac")
    static let scanGroup = Line(ru: "Скан", en: "Scan")
    static let cleanGroup = Line(ru: "Очистка", en: "Clean")
    static let systemGroup = Line(ru: "Система", en: "System")

    static let scan = Line(ru: "Сканировать", en: "Scan")
    static let clean = Line(ru: "Очистить", en: "Clean")
    static let cleanTrash = Line(ru: "Очистить корзину", en: "Empty Trash")
    static let cleaning = Line(ru: "Очистка…", en: "Cleaning…")
    static let scanAgain = Line(ru: "Сканировать снова", en: "Scan again")
    static let stop = Line(ru: "Остановить", en: "Stop")
    static let safe = Line(ru: "Безопасное", en: "Safe")
    static let deselect = Line(ru: "Снять выбор", en: "Clear selection")
    static let later = Line(ru: "Позже", en: "Later")
    static let close = Line(ru: "Закрыть", en: "Close")
    static let retry = Line(ru: "Повторить", en: "Try again")
    static let settings = Line(ru: "Настройки", en: "Settings")
    static let revealFinder = Line(ru: "Показать в Finder", en: "Show in Finder")
    static let openLog = Line(ru: "Открыть лог", en: "Open log")
    static let fullDisk = Line(ru: "Полный доступ к диску", en: "Full Disk Access")
    static let openSettings = Line(ru: "Открыть настройки", en: "Open Settings")

    static let ready = Line(ru: "Готов очистить этот Mac", en: "Ready to clean this Mac")
    static let scanningMac = Line(ru: "Сканирую Mac", en: "Scanning this Mac")
    static let canClean = Line(ru: "Можно очистить", en: "Can clean")
    static let loginsStay = Line(ru: "Входы Safari и Chrome сохраняем", en: "Safari and Chrome logins stay")
    static let loginsBadge = Line(ru: "логины целы", en: "logins intact")
    static let needFDA = Line(ru: "Нужен полный доступ к диску", en: "Full Disk Access is needed")
    static let needFDAQuiet = Line(
        ru: "Нужен полный доступ, если хочешь видеть Telegram и Safari",
        en: "Full Disk Access is needed to see Telegram and Safari"
    )
    static let dontTouch = Line(ru: "Не трогаем", en: "We don't touch")
    static let emptied = Line(ru: "снято", en: "cleared")
    static let offBadge = Line(ru: "выкл", en: "off")
    static let historyBadge = Line(ru: "история", en: "history")
    static let leftoverBadge = Line(ru: "остаток", en: "leftover")
    static let rebuildBadge = Line(ru: "скачается снова", en: "will re-download")
    static let counting = Line(ru: "считаем…", en: "counting…")
    static let foundLabel = Line(ru: "найдено", en: "found")

    static let idleHint = Line(
        ru: "Нажми «Сканировать» — разберём кэши, логи, мессенджеры. Входы Safari/Chrome не трогаем.",
        en: "Press Scan — we'll sort caches, logs, messengers. Safari and Chrome logins stay."
    )
    static let layerUnscanned = Line(ru: "Этот слой ещё не сканировали.", en: "This layer hasn't been scanned yet.")
    static let foldersClean = Line(ru: "В открытых папках чисто.", en: "Open folders are clean.")
    static let foldersCleanFDA = Line(
        ru: "В открытых папках чисто. Для Telegram/Safari нужен полный доступ к диску.",
        en: "Open folders are clean. Telegram and Safari need Full Disk Access."
    )
    static let layerClean = Line(ru: "В этом слое чисто", en: "This layer is clean")
    static let done = Line(ru: "Готово", en: "Done")
    static let emptySmart = Line(ru: "Кэш и мусор в открытых папках не нашлись.", en: "No cache or junk in the folders we can see.")
    static let emptyFDA = Line(
        ru: "Для Telegram и Safari нужен полный доступ к диску.",
        en: "Telegram and Safari need Full Disk Access."
    )

    static let diskTitle = Line(ru: "Обзор диска", en: "Disk")
    static let diskFail = Line(ru: "Не удалось прочитать ёмкость диска.", en: "Couldn't read disk capacity.")
    static let used = Line(ru: "Занято", en: "Used")
    static let free = Line(ru: "Свободно", en: "Free")
    static let total = Line(ru: "Всего", en: "Total")
    static let ringNote = Line(
        ru: "Защищённые папки — отдельный сегмент, не дыра в кольце.",
        en: "Protected folders are a segment, not a hole in the ring."
    )

    static let toolsTitle = Line(ru: "Обслуживание", en: "Maintenance")
    static let toolsLead = Line(
        ru: "Своё расписание и свои исключения. По расписанию снимаем только кэши — медиа и корзину не трогаем.",
        en: "Your schedule and your exclusions. Scheduled runs clear caches only — media and Trash stay."
    )
    static let schedule = Line(ru: "Расписание", en: "Schedule")
    static let autoClean = Line(ru: "Автоочистка", en: "Auto-clean")
    static let addTime = Line(ru: "Добавить время", en: "Add a time")
    static let removeTime = Line(ru: "Убрать", en: "Remove")
    static let exclusions = Line(ru: "Исключения", en: "Exclusions")
    static let exclusionsLead = Line(
        ru: "Эти папки не сканируем и не чистим. Можно добавить свои — без правки приложения.",
        en: "We don't scan or clean these folders. Add your own — no need to edit the app."
    )
    static let addFolder = Line(ru: "Добавить папку", en: "Add a folder")
    static let addFolderHelp = Line(
        ru: "Выбранная папка больше не попадёт в очистку.",
        en: "The chosen folder will stay out of cleanup."
    )
    static let removeExclusion = Line(ru: "Убрать", en: "Remove")
    static let excludeThis = Line(ru: "Не трогать эту папку", en: "Don't touch this folder")
    static let scheduleFail = Line(
        ru: "Не удалось поставить расписание. Проверь, что приложение лежит в папке Applications.",
        en: "Couldn't install the schedule. Make sure the app is in Applications."
    )
    static let actions = Line(ru: "Действия", en: "Actions")
    static let agentWaiting = Line(
        ru: "Расписание стоит. Запуска ещё не было — или лог пуст.",
        en: "Schedule is on. No run yet — or the log is empty."
    )
    static let agentOff = Line(
        ru: "Автоочистка выключена. Включи — и кэши будут сниматься сами в выбранные часы.",
        en: "Auto-clean is off. Turn it on and caches will clear at the hours you pick."
    )
    static let logOpenedFolder = Line(
        ru: "Файла лога ещё нет — открыта папка Logs.",
        en: "No log file yet — opened the Logs folder."
    )
    static let logMissing = Line(ru: "Лог пока не создан.", en: "The log isn't there yet.")
    static let logOpenFail = Line(ru: "Не удалось открыть лог.", en: "Couldn't open the log.")

    static let shortcuts = Line(ru: "Сочетания клавиш", en: "Keyboard shortcuts")
    static let appearanceMenu = Line(ru: "Оформление", en: "Appearance")
    static let languageMenu = Line(ru: "Язык", en: "Language")
    static let cleanMenu = Line(ru: "Очистка", en: "Clean")
    static let aboutApp = Line(ru: "О CleanAlephaMac98", en: "About CleanAlephaMac98")
    static let aboutCredits = Line(
        ru: "Клинер для Mac. Входы Safari и Chrome не трогаем.\nИсключения и расписание — в Обслуживании.",
        en: "A Mac cleaner. Safari and Chrome logins stay.\nExclusions and schedule live in Maintenance."
    )
    static let northernDay = Line(ru: "Северный день", en: "Northern day")
    static let northernNight = Line(ru: "Северная ночь", en: "Northern night")
    static let followSystem = Line(ru: "Как в системе", en: "System")

    static let progress = Line(ru: "Прогресс", en: "Progress")
    static let progressScan = Line(ru: "Прогресс сканирования", en: "Scan progress")
    static let progressClean = Line(ru: "Прогресс очистки", en: "Clean progress")
    static let stopScan = Line(ru: "Остановить сканирование", en: "Stop scanning")
    static let stopClean = Line(ru: "Остановить очистку", en: "Stop cleaning")
    static let orbIdle = Line(ru: "Стеклянная колба", en: "Glass flask")
    static let scanHelp = Line(ru: "⌘R — пройти кэши и мусор", en: "⌘R — walk caches and junk")
    static let cleanHelp = Line(ru: "⌘↩ — удалить выбранное", en: "⌘↩ — remove the selection")
    static let laterHelp = Line(ru: "Пропустить. Карточка в сайдбаре останется.", en: "Skip. The sidebar card stays.")
    static let fdaCardHelp = Line(
        ru: "Открыть настройки полного доступа к диску",
        en: "Open Full Disk Access settings"
    )
    static let noon = Line(ru: "12:00", en: "12:00")
    static let eightPm = Line(ru: "20:00", en: "20:00")
    static let fdaHint = Line(ru: "кэш и логи, не корзина, история и крупные файлы", en: "caches and logs, not Trash, history, or large files")
    static let deselectHint = Line(ru: "снять галки с видимых карточек", en: "clear checks on visible cards")
    static let leftoverGone = Line(ru: "В /Applications не найдено", en: "Not in /Applications")
    static let fdaOpenFail = Line(ru: "Не удалось открыть настройки доступа.", en: "Couldn't open access settings.")
    static let scanBroke = Line(ru: "Сканирование прервалось.", en: "The scan broke off.")
    static let scanStoppedEmpty = Line(ru: "Сканирование остановлено.", en: "Scan stopped.")
    static let scanStoppedPartial = Line(
        ru: "Остановлено. Показано то, что успели найти.",
        en: "Stopped. Showing what we found."
    )
    static let cleaningStatus = Line(ru: "Удаляю выбранное…", en: "Removing the selection…")
    static let cleanStoppedEmpty = Line(ru: "Очистка остановлена.", en: "Cleaning stopped.")
    static let alreadyGone = Line(ru: "Выбранное уже отсутствовало.", en: "The selection was already gone.")
    static let nothingDeleted = Line(
        ru: "Ничего не удалилось. Проверь полный доступ к диску.",
        en: "Nothing was deleted. Check Full Disk Access."
    )
    static let selectedOn = Line(ru: "выбрано", en: "selected")
    static let selectedOff = Line(ru: "не выбрано", en: "not selected")
    static let defaultOff = Line(ru: "по умолчанию выкл", en: "off by default")

    static let moduleSmart = Line(ru: "Умный скан", en: "Smart Scan")
    static let moduleJunk = Line(ru: "Системный мусор", en: "System junk")
    static let moduleMail = Line(ru: "Почта", en: "Mail")
    static let moduleTrash = Line(ru: "Корзины", en: "Trash")
    static let moduleLeftovers = Line(ru: "Остатки приложений", en: "App leftovers")
    static let moduleLarge = Line(ru: "Большие файлы", en: "Large files")
    static let moduleBrowsers = Line(ru: "Браузеры", en: "Browsers")
    static let moduleDev = Line(ru: "Разработка", en: "Developer")
    static let moduleMessengers = Line(ru: "Мессенджеры", en: "Messengers")
    static let moduleSpace = Line(ru: "Обзор диска", en: "Disk")
    static let moduleTools = Line(ru: "Обслуживание", en: "Maintenance")

    static let subSmart = Line(
        ru: "Кэш и мусор. Входы Safari и Chrome не трогаем.",
        en: "Caches and junk. Safari and Chrome logins stay."
    )
    static let subJunk = Line(ru: "Логи и кэши пользователя", en: "User logs and caches")
    static let subMail = Line(ru: "Вложения и кэш Mail", en: "Mail attachments and cache")
    static let subTrash = Line(ru: "Корзина macOS", en: "macOS Trash")
    static let subLeftovers = Line(ru: "Остатки удалённых приложений", en: "Leftovers from deleted apps")
    static let subLarge = Line(ru: "Крупные файлы, по умолчанию выкл", en: "Large files, off by default")
    static let subBrowsers = Line(ru: "Сетевой кэш; входы не трогаем", en: "Network cache; logins stay")
    static let subDev = Line(ru: "npm и кэши редакторов, не Gradle/Simulator", en: "npm and editor caches, not Gradle or Simulator")
    static let subMessengers = Line(ru: "Медиа и история; история выкл", en: "Media and history; history off")

    static func scanning(_ stage: Line) -> Line {
        Line(ru: "Сканирую: \(stage.ru)…", en: "Scanning: \(stage.en)…")
    }

    static func canClear(_ bytes: Int64) -> Line {
        Line(
            ru: "Можно снять \(ByteFormat.string(bytes, .ru)). Логины браузеров сохранены.",
            en: "Can clear \(ByteFormat.string(bytes, .en)). Browser logins stay."
        )
    }

    static func canClear(selected: Int64, found: Int64) -> Line {
        if found <= selected || found <= 0 {
            return canClear(selected)
        }
        return Line(
            ru: "Можно снять \(ByteFormat.string(selected, .ru)) из найденных \(ByteFormat.string(found, .ru)). Логины на месте.",
            en: "Can clear \(ByteFormat.string(selected, .en)) of \(ByteFormat.string(found, .en)) found. Logins stay."
        )
    }

    static func foundLine(_ bytes: Int64) -> Line {
        Line(ru: "найдено \(ByteFormat.string(bytes, .ru))", en: "found \(ByteFormat.string(bytes, .en))")
    }

    static func doneFreed(_ bytes: Int64) -> Line {
        Line(ru: "Готово — снято \(ByteFormat.string(bytes, .ru)).", en: "Done — cleared \(ByteFormat.string(bytes, .en)).")
    }

    static func stoppedFreed(_ bytes: Int64) -> Line {
        Line(ru: "Остановлено. Снято \(ByteFormat.string(bytes, .ru)).", en: "Stopped. Cleared \(ByteFormat.string(bytes, .en)).")
    }

    static func emptyDetailFreed(_ bytes: Int64) -> Line {
        Line(
            ru: "Снято \(ByteFormat.string(bytes, .ru)). Логины браузеров на месте.",
            en: "Cleared \(ByteFormat.string(bytes, .en)). Browser logins are still there."
        )
    }

    static func someFailed(freed: Int64, failed: Int) -> Line {
        Line(
            ru: "Снято \(ByteFormat.string(freed, .ru)). \(failed) шт. не удалились — проверь доступ к диску.",
            en: "Cleared \(ByteFormat.string(freed, .en)). \(failed) didn't delete — check disk access."
        )
    }

    static func partialRead(_ n: Int) -> Line {
        Line(ru: "Часть папок не прочиталась (\(n)).", en: "Some folders couldn't be read (\(n)).")
    }

    static func selected(_ n: Int, of total: Int) -> Line {
        Line(ru: "выбрано \(n) из \(total)", en: "\(n) of \(total) selected")
    }

    static func percent(_ n: Int) -> Line {
        Line(ru: "\(n) процентов", en: "\(n) percent")
    }

    static func orbScan(_ n: Int) -> Line {
        Line(ru: "Сфера, сканирование \(n) процентов", en: "Flask, scanning \(n) percent")
    }

    static func orbCleaning(_ n: Int) -> Line {
        Line(ru: "Сфера, очистка \(n) процентов", en: "Flask, cleaning \(n) percent")
    }

    static func orbFreed(_ bytes: Int64) -> Line {
        Line(ru: "Сфера, снято \(ByteFormat.string(bytes, .ru))", en: "Flask, cleared \(ByteFormat.string(bytes, .en))")
    }

    static func orbCanClean(_ bytes: Int64) -> Line {
        Line(ru: "Сфера, можно очистить \(ByteFormat.string(bytes, .ru))", en: "Flask, can clean \(ByteFormat.string(bytes, .en))")
    }

    static func diskA11y(used: Int64, reserved: Int64, free: Int64) -> Line {
        Line(
            ru: "Диск: занято \(ByteFormat.string(used, .ru)), не трогаем \(ByteFormat.string(reserved, .ru)), свободно \(ByteFormat.string(free, .ru))",
            en: "Disk: used \(ByteFormat.string(used, .en)), we don't touch \(ByteFormat.string(reserved, .en)), free \(ByteFormat.string(free, .en))"
        )
    }

    static func scheduleLast(when: String, freed: String?) -> Line {
        if let freed {
            return Line(ru: "Последний раз \(when). Снято около \(freed).", en: "Last run \(when). Cleared about \(freed).")
        }
        return Line(ru: "Последний раз \(when).", en: "Last run \(when).")
    }

    static func scheduleA11y(now: String, marks: String) -> Line {
        Line(
            ru: "Сутки. Отметки \(marks). Сейчас \(now).",
            en: "A day. Marks at \(marks). Now \(now)."
        )
    }

    static func offersFDA(_ line: Line) -> Bool {
        line.ru.localizedCaseInsensitiveContains("доступ")
            || line.en.localizedCaseInsensitiveContains("disk access")
            || line.en.localizedCaseInsensitiveContains("access settings")
    }

    static func relative(_ date: Date, lang: CopyLang) -> String {
        let cal = Calendar.current
        let clock = DateFormatter()
        clock.locale = Locale(identifier: lang == .en ? "en_US_POSIX" : "ru_RU")
        clock.dateFormat = "HH:mm"
        let hm = clock.string(from: date)
        if cal.isDateInToday(date) {
            return lang == .en ? "today at \(hm)" : "сегодня в \(hm)"
        }
        if cal.isDateInYesterday(date) {
            return lang == .en ? "yesterday at \(hm)" : "вчера в \(hm)"
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: lang == .en ? "en_GB" : "ru_RU")
        day.dateFormat = lang == .en ? "d MMM, HH:mm" : "d MMM, HH:mm"
        return day.string(from: date)
    }
}

extension AppearanceChoice {
    func title(_ lang: CopyLang) -> String {
        switch self {
        case .system: Copy.followSystem.t(lang)
        case .light: Copy.northernDay.t(lang)
        case .dark: Copy.northernNight.t(lang)
        }
    }
}
