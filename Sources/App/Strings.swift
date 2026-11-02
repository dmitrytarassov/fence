import Foundation

enum Language: String, CaseIterable {
    case english = "en"
    case russian = "ru"

    static let defaultsKey = "language"

    static var current: Language {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            return Language(rawValue: raw) ?? .english
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var nativeName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        }
    }
}

/// UI strings. `L.text(.key)` returns the string in the current language.
enum L {
    enum Key {
        case iconOpen, iconBlocked, iconChecking, iconNoDaemon, iconBlockError
        case statusOpen, statusBlocked, statusManual, statusChecking, statusNoDaemon
        case installHint, checkedAt, error
        case manualBlock, recheck, openLog, launchAtLogin, language, services, quit
    }

    private static let en: [Key: String] = [
        .iconOpen: "Fence: access is open",
        .iconBlocked: "Fence: block is active",
        .iconChecking: "Fence: checking the country, block is active",
        .iconNoDaemon: "Fence: the daemon does not answer",
        .iconBlockError: "Fence: the block failed, open the menu",
        .statusOpen: "Access open · %@ · %@",
        .statusBlocked: "Blocked: IP from %@ · %@",
        .statusManual: "Manual block · %@ · %@",
        .statusChecking: "Checking the country… block is active",
        .statusNoDaemon: "The daemon does not answer",
        .installHint: "Run in a terminal: sudo ./install.sh",
        .checkedAt: "Checked at %@",
        .error: "Error: %@",
        .manualBlock: "Block manually",
        .recheck: "Check now",
        .openLog: "Open log",
        .launchAtLogin: "Launch at login",
        .language: "Language",
        .services: "Services",
        .quit: "Quit",
    ]

    private static let ru: [Key: String] = [
        .iconOpen: "Fence: доступ открыт",
        .iconBlocked: "Fence: блок активен",
        .iconChecking: "Fence: проверка страны, блок активен",
        .iconNoDaemon: "Fence: демон не отвечает",
        .iconBlockError: "Fence: блок не применился, открой меню",
        .statusOpen: "Доступ открыт · %@ · %@",
        .statusBlocked: "Блок: IP из %@ · %@",
        .statusManual: "Ручной блок · %@ · %@",
        .statusChecking: "Проверка страны… блок активен",
        .statusNoDaemon: "Демон не отвечает",
        .installHint: "Запусти в терминале: sudo ./install.sh",
        .checkedAt: "Проверено %@",
        .error: "Ошибка: %@",
        .manualBlock: "Блокировать вручную",
        .recheck: "Проверить сейчас",
        .openLog: "Открыть лог",
        .launchAtLogin: "Запускать при входе",
        .language: "Язык",
        .services: "Сервисы",
        .quit: "Выход",
    ]

    static func text(_ key: Key, _ args: CVarArg...) -> String {
        let table = Language.current == .russian ? ru : en
        let format = table[key] ?? en[key] ?? ""
        return args.isEmpty ? format : String(format: format, arguments: args)
    }
}
