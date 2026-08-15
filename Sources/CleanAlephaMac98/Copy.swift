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
    static let personalMac = Line(ru: "для Mac", en: "for Mac")
    static let scanGroup = Line(ru: "Скан", en: "Scan")
    static let cleanGroup = Line(ru: "Очистка", en: "Clean")
    static let liveGroup = Line(ru: "Сейчас", en: "Now")
    static let guardGroup = Line(ru: "Проверки", en: "Checks")
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

    static let ready = Line(ru: "Можно сканировать", en: "Ready to scan")
    static let scanningMac = Line(ru: "Сканирую Mac", en: "Scanning the Mac")
    static let canClean = Line(ru: "Можно очистить", en: "Can clean")
    static let loginsStay = Line(ru: "Логины Safari и Chrome не трогаем", en: "Safari and Chrome logins stay")
    static let loginsBadge = Line(ru: "логины целы", en: "logins stay")
    static let needFDA = Line(ru: "Нужен полный доступ к диску", en: "Needs Full Disk Access")
    static let needFDAQuiet = Line(
        ru: "Без полного доступа не видно Telegram и Safari",
        en: "Without Full Disk Access, Telegram and Safari stay hidden"
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
        ru: "Нажми «Сканировать». Кэши, логи, мессенджеры. Логины Safari и Chrome не трогаем.",
        en: "Press Scan. Caches, logs, messengers. Safari and Chrome logins stay."
    )
    static let layerUnscanned = Line(ru: "Этот слой ещё не сканировали.", en: "Haven't scanned this yet.")
    static let foldersClean = Line(ru: "В открытых папках чисто.", en: "Those folders are clean.")
    static let foldersCleanFDA = Line(
        ru: "В открытых папках чисто. Telegram и Safari без полного доступа не видны.",
        en: "Those folders are clean. Telegram and Safari need Full Disk Access."
    )
    static let layerClean = Line(ru: "В этом слое чисто", en: "This layer is clean")
    static let done = Line(ru: "Готово", en: "Done")
    static let emptySmart = Line(ru: "Кэша и мусора в открытых папках нет.", en: "No cache or junk in the open folders.")
    static let emptyFDA = Line(
        ru: "Telegram и Safari без полного доступа не видны.",
        en: "Telegram and Safari need Full Disk Access."
    )

    static let diskTitle = Line(ru: "Обзор диска", en: "Disk")
    static let diskFail = Line(ru: "Ёмкость диска не прочиталась.", en: "Couldn't read the disk.")
    static let used = Line(ru: "Занято", en: "Used")
    static let free = Line(ru: "Свободно", en: "Free")
    static let total = Line(ru: "Всего", en: "Total")
    static let ringNote = Line(
        ru: "Защищённые папки – отдельный кусок кольца, не дыра.",
        en: "Protected folders are a slice of the ring, not a hole."
    )

    static let toolsTitle = Line(ru: "Обслуживание", en: "Maintenance")
    static let toolsLead = Line(
        ru: "Свои часы, свои исключения. По таймеру снимаются только кэши – не медиа и не корзина.",
        en: "Your hours, your exclusions. The timer only clears caches – not media, not Trash."
    )
    static let schedule = Line(ru: "Расписание", en: "Schedule")
    static let autoClean = Line(ru: "Автоочистка", en: "Auto-clean")
    static let addTime = Line(ru: "Добавить время", en: "Add a time")
    static let removeTime = Line(ru: "Убрать", en: "Remove")
    static let exclusions = Line(ru: "Исключения", en: "Exclusions")
    static let exclusionsLead = Line(
        ru: "Эти папки не сканируем и не чистим. Свои можно добавить тут.",
        en: "We skip these folders. You can add your own here."
    )
    static let addFolder = Line(ru: "Добавить папку", en: "Add a folder")
    static let addFolderHelp = Line(
        ru: "Эту папку больше не чистим.",
        en: "We won't clean this folder."
    )
    static let removeExclusion = Line(ru: "Убрать", en: "Remove")
    static let excludeThis = Line(ru: "Не трогать эту папку", en: "Don't touch this folder")
    static let scheduleFail = Line(
        ru: "Расписание не встало. Проверь, что приложение в папке Applications.",
        en: "Couldn't set the schedule. Keep the app in Applications."
    )
    static let actions = Line(ru: "Действия", en: "Actions")
    static let agentWaiting = Line(
        ru: "Расписание стоит. Запуска ещё не было, или лог пуст.",
        en: "Schedule is on. No run yet, or the log is empty."
    )
    static let agentOff = Line(
        ru: "Автоочистка выключена. Включи, и кэши будут сниматься в выбранные часы.",
        en: "Auto-clean is off. Turn it on and caches clear at the hours you pick."
    )
    static let logOpenedFolder = Line(
        ru: "Лога ещё нет, открыта папка Logs.",
        en: "No log yet. Opened the Logs folder."
    )
    static let logMissing = Line(ru: "Лога пока нет.", en: "No log yet.")
    static let logOpenFail = Line(ru: "Лог не открылся.", en: "Couldn't open the log.")

    static let shortcuts = Line(ru: "Сочетания клавиш", en: "Keyboard shortcuts")
    static let appearanceMenu = Line(ru: "Оформление", en: "Appearance")
    static let languageMenu = Line(ru: "Язык", en: "Language")
    static let cleanMenu = Line(ru: "Очистка", en: "Clean")
    static let aboutApp = Line(ru: "О CleanAlephaMac98", en: "About CleanAlephaMac98")
    static let aboutCredits = Line(
        ru: "Клинер для Mac. Логины Safari и Chrome не трогаем.\nРасписание и исключения – в Обслуживании.",
        en: "Mac cleaner. Safari and Chrome logins stay.\nSchedule and exclusions live in Maintenance."
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
    static let scanHelp = Line(ru: "⌘R – пройти кэши и мусор", en: "⌘R – scan caches and junk")
    static let cleanHelp = Line(ru: "⌘↩ – удалить выбранное", en: "⌘↩ – delete the selection")
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
    static let fdaOpenFail = Line(ru: "Настройки доступа не открылись.", en: "Couldn't open access settings.")
    static let scanBroke = Line(ru: "Сканирование оборвалось.", en: "The scan broke off.")
    static let scanStoppedEmpty = Line(ru: "Сканирование остановлено.", en: "Scan stopped.")
    static let scanStoppedPartial = Line(
        ru: "Остановлено. Показано то, что успели найти.",
        en: "Stopped. Here's what we found so far."
    )
    static let cleaningStatus = Line(ru: "Удаляю выбранное…", en: "Removing the selection…")
    static let cleanStoppedEmpty = Line(ru: "Очистка остановлена.", en: "Cleaning stopped.")
    static let alreadyGone = Line(ru: "Выбранного уже не было.", en: "That was already gone.")
    static let nothingDeleted = Line(
        ru: "Ничего не удалилось. Проверь полный доступ к диску.",
        en: "Nothing got deleted. Check Full Disk Access."
    )
    static let selectedOn = Line(ru: "выбрано", en: "selected")
    static let selectedOff = Line(ru: "не выбрано", en: "not selected")
    static let defaultOff = Line(ru: "по умолчанию выкл", en: "off by default")

    static let liveRefresh = Line(ru: "Обновить", en: "Refresh")
    static let modulePulse = Line(ru: "Память", en: "Memory")
    static let moduleProtect = Line(ru: "Проверка", en: "Check")
    static let moduleStartup = Line(ru: "Автозагрузка", en: "Startup")
    static let subPulse = Line(
        ru: "Кто жрёт память. Вкладки покажем, браузер не закроем.",
        en: "What's eating RAM. We list the tabs, we don't quit the browser."
    )
    static let subProtect = Line(
        ru: "Известный adware и странные агенты. Не антивирус.",
        en: "Known adware and odd agents. Not an antivirus."
    )
    static let subStartup = Line(
        ru: "Что стартует вместе с тобой.",
        en: "What launches when you log in."
    )
    static let weDontQuitBrowsers = Line(
        ru: "Браузер сам не закроем. Лишнюю вкладку закрой руками.",
        en: "We won't quit the browser. Close the extra tab yourself."
    )
    static let showTab = Line(ru: "Показать вкладку", en: "Show tab")
    static let estimateBadge = Line(ru: "оценка", en: "guess")
    static let recommendBadge = Line(ru: "совет", en: "tip")
    static let needAutomation = Line(
        ru: "macOS не дал прочитать вкладки. В Автоматизации разреши Safari и Chrome. Мы только читаем.",
        en: "macOS blocked the tabs. Allow Automation for Safari and Chrome. We only read them."
    )
    static let tabsTitle = Line(ru: "Вкладки", en: "Tabs")
    static let appsTitle = Line(ru: "Кто держит память", en: "What's holding RAM")
    static let pulseIdle = Line(ru: "Обнови, посмотрим память и вкладки.", en: "Refresh to see memory and tabs.")
    static let ramHonest = Line(
        ru: "Память кнопкой не освободить. Если тупит – закрой тяжёлую вкладку.",
        en: "There's no Free RAM button. If it's slow – close a heavy tab."
    )
    static let appRamHint = Line(
        ru: "Процесс живой. Мы его не убиваем.",
        en: "It's running. We won't kill it."
    )
    static let pressureNormal = Line(ru: "Памяти хватает", en: "Memory's fine")
    static let pressureWarn = Line(ru: "Память поджимает", en: "Memory's tight")
    static let pressureCritical = Line(ru: "Уже своп", en: "Already swapping")
    static let protectClear = Line(ru: "Типичного adware нет", en: "No typical adware")
    static let protectClearSub = Line(
        ru: "Глянули приложения, агенты и hosts. Не полная проверка.",
        en: "Looked at apps, agents, and hosts. Not a full scan."
    )
    static let notAntivirus = Line(
        ru: "Ищем известный adware и кривые агенты. Не антивирус.",
        en: "Known adware and odd agents. Not an antivirus."
    )
    static let knownPUP = Line(ru: "известный мусор", en: "known junk")
    static let knownPUPSupport = Line(ru: "папка известного adware", en: "known adware folder")
    static let adwareAgent = Line(ru: "агент известного adware", en: "known adware agent")
    static let unsignedAgent = Line(
        ru: "LaunchAgent без подписи, не из Applications. Сами не трогаем.",
        en: "Unsigned LaunchAgent, not from Applications. We won't touch it."
    )
    static let hostsTouched = Line(ru: "Файл hosts странный", en: "The hosts file looks off")
    static let hostsTouchedSub = Line(
        ru: "Лишние редиректы. Открой /etc/hosts сам, мы его не правим.",
        en: "Extra redirects. Open /etc/hosts yourself, we don't edit it."
    )
    static let ourAgent = Line(ru: "наш агент", en: "our agent")
    static let appleBadge = Line(ru: "Apple", en: "Apple")
    static let fineBadge = Line(ru: "норм", en: "fine")
    static let runsAtLogin = Line(ru: "стартует при входе", en: "starts at login")
    static let agentLoaded = Line(ru: "LaunchAgent пользователя", en: "User LaunchAgent")
    static let loginItem = Line(ru: "элемент входа", en: "login item")
    static let disableAgent = Line(ru: "Убрать выбранное", en: "Remove selected")

    static func ramLine(used: Int64, total: Int64) -> Line {
        Line(
            ru: "Занято \(ByteFormat.string(used, .ru)) из \(ByteFormat.string(total, .ru))",
            en: "Using \(ByteFormat.string(used, .en)) of \(ByteFormat.string(total, .en))"
        )
    }

    static func swapLine(_ bytes: Int64) -> Line {
        Line(
            ru: "Своп \(ByteFormat.string(bytes, .ru)). Уже пишет на диск.",
            en: "Swap \(ByteFormat.string(bytes, .en)). Already paging to disk."
        )
    }
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
        ru: "Кэш и мусор. Логины Safari и Chrome не трогаем.",
        en: "Caches and junk. Safari and Chrome logins stay."
    )
    static let subJunk = Line(ru: "Логи и кэши пользователя", en: "User logs and caches")
    static let subMail = Line(ru: "Вложения и кэш Mail", en: "Mail attachments and cache")
    static let subTrash = Line(ru: "Корзина macOS", en: "macOS Trash")
    static let subLeftovers = Line(ru: "Остатки удалённых приложений", en: "Leftovers from deleted apps")
    static let subLarge = Line(ru: "Крупные файлы, по умолчанию выкл", en: "Large files, off by default")
    static let subBrowsers = Line(ru: "Сетевой кэш. Логины не трогаем.", en: "Network cache. Logins stay.")
    static let subDev = Line(ru: "npm и кэши редакторов. Gradle и Simulator не трогаем.", en: "npm and editor caches. Not Gradle or Simulator.")
    static let subMessengers = Line(ru: "Медиа и история. История выкл.", en: "Media and history. History stays off.")

    static func scanning(_ stage: Line) -> Line {
        Line(ru: "Сканирую: \(stage.ru)…", en: "Scanning: \(stage.en)…")
    }

    static func canClear(_ bytes: Int64) -> Line {
        Line(
            ru: "Можно снять \(ByteFormat.string(bytes, .ru)). Логины на месте.",
            en: "Can clear \(ByteFormat.string(bytes, .en)). Logins stay."
        )
    }

    static func canClear(selected: Int64, found: Int64) -> Line {
        if found <= selected || found <= 0 {
            return canClear(selected)
        }
        return Line(
            ru: "Можно снять \(ByteFormat.string(selected, .ru)) из \(ByteFormat.string(found, .ru)). Логины на месте.",
            en: "Can clear \(ByteFormat.string(selected, .en)) of \(ByteFormat.string(found, .en)). Logins stay."
        )
    }

    static func foundLine(_ bytes: Int64) -> Line {
        Line(ru: "найдено \(ByteFormat.string(bytes, .ru))", en: "found \(ByteFormat.string(bytes, .en))")
    }

    static func doneFreed(_ bytes: Int64) -> Line {
        Line(ru: "Готово. Снято \(ByteFormat.string(bytes, .ru)).", en: "Done. Cleared \(ByteFormat.string(bytes, .en)).")
    }

    static func stoppedFreed(_ bytes: Int64) -> Line {
        Line(ru: "Остановлено. Снято \(ByteFormat.string(bytes, .ru)).", en: "Stopped. Cleared \(ByteFormat.string(bytes, .en)).")
    }

    static func emptyDetailFreed(_ bytes: Int64) -> Line {
        Line(
            ru: "Снято \(ByteFormat.string(bytes, .ru)). Логины на месте.",
            en: "Cleared \(ByteFormat.string(bytes, .en)). Logins stay."
        )
    }

    static func someFailed(freed: Int64, failed: Int) -> Line {
        Line(
            ru: "Снято \(ByteFormat.string(freed, .ru)). \(failed) шт. не удалились, проверь доступ к диску.",
            en: "Cleared \(ByteFormat.string(freed, .en)). \(failed) didn't delete – check disk access."
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
