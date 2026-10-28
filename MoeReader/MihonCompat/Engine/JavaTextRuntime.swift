//
//  JavaTextRuntime.swift
//  MihonCompat
//
//  `java.util.Date`, `java.util.Calendar`/`GregorianCalendar`, `java.util.TimeZone`
//  and `java.text` date/number formatting. A date is epoch milliseconds plus a
//  zone; field conversions use integer civil-date arithmetic, so a parsed date
//  never depends on the host locale or on a stray daylight-saving transition.
//

import Foundation

final class VMDatePayload {
    var millis: Int64
    init(_ millis: Int64 = 0) {
        self.millis = millis
    }
}

final class VMTimeZonePayload {
    var id: String
    var secondsFromGMT: Int
    init(id: String, secondsFromGMT: Int) {
        self.id = id
        self.secondsFromGMT = secondsFromGMT
    }
}

final class VMCalendarPayload {
    var millis: Int64
    var zone: VMTimeZonePayload
    var lenient = true
    var firstDayOfWeek = 1
    var minimalDaysInFirstWeek = 1

    init(millis: Int64, zone: VMTimeZonePayload) {
        self.millis = millis
        self.zone = zone
    }

    var copy: VMCalendarPayload {
        let clone = VMCalendarPayload(millis: millis, zone: VMTimeZonePayload(id: zone.id, secondsFromGMT: zone.secondsFromGMT))
        clone.lenient = lenient
        clone.firstDayOfWeek = firstDayOfWeek
        clone.minimalDaysInFirstWeek = minimalDaysInFirstWeek
        return clone
    }
}

final class VMDateFormatPayload {
    var pattern: String
    var language: String
    var zone: VMTimeZonePayload
    var lenient = true

    init(pattern: String, language: String, zone: VMTimeZonePayload) {
        self.pattern = pattern
        self.language = language
        self.zone = zone
    }
}

final class VMParsePositionPayload {
    var index: Int
    var errorIndex = -1
    init(index: Int = 0) {
        self.index = index
    }
}

final class VMDecimalFormatPayload {
    var pattern: String
    var positivePrefix = ""
    var positiveSuffix = ""
    var negativePrefix = "-"
    var negativeSuffix = ""
    var groupingUsed = false
    var groupingSize = 3
    var minIntegerDigits = 1
    var minFractionDigits = 0
    var maxFractionDigits = 3
    var multiplier = 1
    var decimalSeparator: Character = "."
    var groupingSeparator: Character = ","
    var percentSuffix = false

    init(pattern: String) {
        self.pattern = pattern
    }
}

/// Month and weekday names for one language. Index 0 of the weekday arrays is
/// Sunday, matching `java.util.Calendar`.
struct VMDateNames {
    var language: String
    var monthsFull: [String]
    var monthsShort: [String]
    var weekdaysFull: [String]
    var weekdaysShort: [String]
    var am: String
    var pm: String
}

extension VMDateNames {
    static let english = VMDateNames(
        language: "en",
        monthsFull: [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December",
        ],
        monthsShort: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
        weekdaysFull: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
        weekdaysShort: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
        am: "AM",
        pm: "PM"
    )

    static func forLanguage(_ code: String) -> VMDateNames {
        switch code.lowercased() {
        case "es", "gl", "ca":
            return VMDateNames(
                language: "es",
                monthsFull: ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"],
                monthsShort: ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"],
                weekdaysFull: ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"],
                weekdaysShort: ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"],
                am: "a. m.",
                pm: "p. m."
            )
        case "fr":
            return VMDateNames(
                language: "fr",
                monthsFull: ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"],
                monthsShort: ["janv", "févr", "mars", "avr", "mai", "juin", "juil", "août", "sept", "oct", "nov", "déc"],
                weekdaysFull: ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"],
                weekdaysShort: ["dim", "lun", "mar", "mer", "jeu", "ven", "sam"],
                am: "AM",
                pm: "PM"
            )
        case "de":
            return VMDateNames(
                language: "de",
                monthsFull: ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"],
                monthsShort: ["Jan", "Feb", "März", "Apr", "Mai", "Juni", "Juli", "Aug", "Sept", "Okt", "Nov", "Dez"],
                weekdaysFull: ["Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"],
                weekdaysShort: ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"],
                am: "AM",
                pm: "PM"
            )
        case "it":
            return VMDateNames(
                language: "it",
                monthsFull: ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"],
                monthsShort: ["gen", "feb", "mar", "apr", "mag", "giu", "lug", "ago", "set", "ott", "nov", "dic"],
                weekdaysFull: ["domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"],
                weekdaysShort: ["dom", "lun", "mar", "mer", "gio", "ven", "sab"],
                am: "AM",
                pm: "PM"
            )
        case "pt", "pt-br":
            return VMDateNames(
                language: "pt",
                monthsFull: ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"],
                monthsShort: ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"],
                weekdaysFull: ["domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado"],
                weekdaysShort: ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"],
                am: "AM",
                pm: "PM"
            )
        case "ru":
            return VMDateNames(
                language: "ru",
                monthsFull: ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"],
                monthsShort: ["янв", "фев", "мар", "апр", "май", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"],
                weekdaysFull: ["воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота"],
                weekdaysShort: ["вс", "пн", "вт", "ср", "чт", "пт", "сб"],
                am: "AM",
                pm: "PM"
            )
        case "ja":
            return VMDateNames(
                language: "ja",
                monthsFull: ["1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月"],
                monthsShort: ["1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月"],
                weekdaysFull: ["日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日"],
                weekdaysShort: ["日", "月", "火", "水", "木", "金", "土"],
                am: "午前",
                pm: "午後"
            )
        case "ko":
            return VMDateNames(
                language: "ko",
                monthsFull: ["1월", "2월", "3월", "4월", "5월", "6월", "7월", "8월", "9월", "10월", "11월", "12월"],
                monthsShort: ["1월", "2월", "3월", "4월", "5월", "6월", "7월", "8월", "9월", "10월", "11월", "12월"],
                weekdaysFull: ["일요일", "월요일", "화요일", "수요일", "목요일", "금요일", "토요일"],
                weekdaysShort: ["일", "월", "화", "수", "목", "금", "토"],
                am: "오전",
                pm: "오후"
            )
        case "zh", "zh-cn", "zh-tw":
            return VMDateNames(
                language: "zh",
                monthsFull: ["一月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "十一月", "十二月"],
                monthsShort: ["1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月"],
                weekdaysFull: ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"],
                weekdaysShort: ["周日", "周一", "周二", "周三", "周四", "周五", "周六"],
                am: "上午",
                pm: "下午"
            )
        case "id", "ms":
            return VMDateNames(
                language: "id",
                monthsFull: ["Januari", "Februari", "Maret", "April", "Mei", "Juni", "Juli", "Agustus", "September", "Oktober", "November", "Desember"],
                monthsShort: ["Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des"],
                weekdaysFull: ["Minggu", "Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu"],
                weekdaysShort: ["Min", "Sen", "Sel", "Rab", "Kam", "Jum", "Sab"],
                am: "AM",
                pm: "PM"
            )
        case "tr":
            return VMDateNames(
                language: "tr",
                monthsFull: ["Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"],
                monthsShort: ["Oca", "Şub", "Mar", "Nis", "May", "Haz", "Tem", "Ağu", "Eyl", "Eki", "Kas", "Ara"],
                weekdaysFull: ["Pazar", "Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma", "Cumartesi"],
                weekdaysShort: ["Paz", "Pzt", "Sal", "Çar", "Per", "Cum", "Cmt"],
                am: "ÖÖ",
                pm: "ÖS"
            )
        case "pl":
            return VMDateNames(
                language: "pl",
                monthsFull: ["stycznia", "lutego", "marca", "kwietnia", "maja", "czerwca", "lipca", "sierpnia", "września", "października", "listopada", "grudnia"],
                monthsShort: ["sty", "lut", "mar", "kwi", "maj", "cze", "lip", "sie", "wrz", "paź", "lis", "gru"],
                weekdaysFull: ["niedziela", "poniedziałek", "wtorek", "środa", "czwartek", "piątek", "sobota"],
                weekdaysShort: ["niedz", "pon", "wt", "śr", "czw", "pt", "sob"],
                am: "AM",
                pm: "PM"
            )
        case "nl":
            return VMDateNames(
                language: "nl",
                monthsFull: ["januari", "februari", "maart", "april", "mei", "juni", "juli", "augustus", "september", "oktober", "november", "december"],
                monthsShort: ["jan", "feb", "mrt", "apr", "mei", "jun", "jul", "aug", "sep", "okt", "nov", "dec"],
                weekdaysFull: ["zondag", "maandag", "dinsdag", "woensdag", "donderdag", "vrijdag", "zaterdag"],
                weekdaysShort: ["zo", "ma", "di", "wo", "do", "vr", "za"],
                am: "AM",
                pm: "PM"
            )
        case "vi":
            return VMDateNames(
                language: "vi",
                monthsFull: ["tháng 1", "tháng 2", "tháng 3", "tháng 4", "tháng 5", "tháng 6", "tháng 7", "tháng 8", "tháng 9", "tháng 10", "tháng 11", "tháng 12"],
                monthsShort: ["thg 1", "thg 2", "thg 3", "thg 4", "thg 5", "thg 6", "thg 7", "thg 8", "thg 9", "thg 10", "thg 11", "thg 12"],
                weekdaysFull: ["Chủ Nhật", "Thứ Hai", "Thứ Ba", "Thứ Tư", "Thứ Năm", "Thứ Sáu", "Thứ Bảy"],
                weekdaysShort: ["CN", "T2", "T3", "T4", "T5", "T6", "T7"],
                am: "SA",
                pm: "CH"
            )
        default:
            return .english
        }
    }
}

enum JavaTextRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += dateClasses()
        result += calendarClasses()
        result += timeZoneClasses()
        result += formatClasses()
        return result
    }

    // MARK: - Civil date arithmetic

    /// Days since 1970-01-01 for a proleptic Gregorian date.
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        var y = year
        if month <= 2 { y -= 1 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp + (mp < 10 ? 3 : -9)
        return (y + (month <= 2 ? 1 : 0), month, day)
    }

    @inline(__always) static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return (value % divisor != 0 && ((value < 0) != (divisor < 0))) ? quotient - 1 : quotient
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        default:
            return 30
        }
    }

    static func epochMillis(
        year: Int, month: Int, day: Int,
        hour: Int = 0, minute: Int = 0, second: Int = 0, millis: Int = 0
    ) -> Int64 {
        let days = Int64(daysFromCivil(year, month, day))
        return days * 86_400_000
            + Int64(hour) * 3_600_000
            + Int64(minute) * 60_000
            + Int64(second) * 1000
            + Int64(millis)
    }

    static func offsetSeconds(_ zone: VMTimeZonePayload, at millis: Int64) -> Int {
        if let resolved = TimeZone(identifier: zone.id) {
            return resolved.secondsFromGMT(for: Date(timeIntervalSince1970: Double(millis) / 1000))
        }
        return zone.secondsFromGMT
    }

    /// Wall-clock components of an instant in the given zone.
    static func components(millis: Int64, zone: VMTimeZonePayload) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, millis: Int, days: Int, offset: Int) {
        let offset = offsetSeconds(zone, at: millis)
        let local = millis + Int64(offset) * 1000
        let days = Int(floorDivide(local, 86_400_000))
        var rest = local - Int64(days) * 86_400_000
        let hour = Int(rest / 3_600_000)
        rest -= Int64(hour) * 3_600_000
        let minute = Int(rest / 60_000)
        rest -= Int64(minute) * 60_000
        let second = Int(rest / 1000)
        let milli = Int(rest - Int64(second) * 1000)
        let civil = civilFromDays(days)
        return (civil.year, civil.month, civil.day, hour, minute, second, milli, days, offset)
    }

    /// Instant for wall-clock components in the given zone. Region zones with
    /// daylight saving need the offset at the instant being built, so the
    /// conversion is retried once with the offset found there.
    static func millis(
        year: Int, month: Int, day: Int,
        hour: Int = 0, minute: Int = 0, second: Int = 0, millis: Int = 0,
        zone: VMTimeZonePayload
    ) -> Int64 {
        let local = epochMillis(year: year, month: month, day: day, hour: hour, minute: minute, second: second, millis: millis)
        var offset = offsetSeconds(zone, at: local)
        var candidate = local - Int64(offset) * 1000
        let adjusted = offsetSeconds(zone, at: candidate)
        if adjusted != offset {
            offset = adjusted
            candidate = local - Int64(offset) * 1000
        }
        return candidate
    }

    // MARK: - Zone values

    static func defaultZone() -> VMTimeZonePayload {
        let zone = TimeZone.current
        return VMTimeZonePayload(id: zone.identifier, secondsFromGMT: zone.secondsFromGMT())
    }

    static func resolveZone(_ id: String) -> VMTimeZonePayload {
        if let zone = TimeZone(identifier: id) {
            return VMTimeZonePayload(id: zone.identifier, secondsFromGMT: zone.secondsFromGMT())
        }
        let upper = id.uppercased()
        if upper.hasPrefix("GMT") || upper.hasPrefix("UTC") {
            let rest = String(id.dropFirst(3))
            if rest.isEmpty { return VMTimeZonePayload(id: id, secondsFromGMT: 0) }
            if let parsed = parseZoneOffset(rest) { return VMTimeZonePayload(id: id, secondsFromGMT: parsed) }
            return VMTimeZonePayload(id: id, secondsFromGMT: 0)
        }
        if let parsed = parseZoneOffset(id) { return VMTimeZonePayload(id: id, secondsFromGMT: parsed) }
        return VMTimeZonePayload(id: id, secondsFromGMT: 0)
    }

    /// Parses `+09:00`, `-0500`, `+9` or `Z` into seconds east of UTC.
    static func parseZoneOffset(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.uppercased() == "Z" { return 0 }
        guard let first = trimmed.first, first == "+" || first == "-" else { return nil }
        let sign = first == "-" ? -1 : 1
        let digits = trimmed.dropFirst().replacingOccurrences(of: ":", with: "")
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return nil }
        let padded = digits.count <= 2 ? digits + "00" : digits
        guard let hours = Int(padded.prefix(2)), let minutes = Int(padded.dropFirst(2).prefix(2)) else { return nil }
        let seconds = padded.count >= 6 ? (Int(padded.dropFirst(4).prefix(2)) ?? 0) : 0
        return sign * (hours * 3600 + minutes * 60 + seconds)
    }

    static func zoneID(_ payload: VMTimeZonePayload) -> String {
        payload.id
    }

    // MARK: - java.util.Date

    private static func dateClasses() -> [NativeClass] {
        let date = NativeClass("Ljava/util/Date;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;", "Ljava/lang/Cloneable;", "Ljava/lang/Comparable;"])
        date.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMDatePayload(Int64(Date().timeIntervalSince1970 * 1000)))
            return .zero
        }
        date.method("<init>", "(J)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMDatePayload(args[1].asInt64))
            return .zero
        }
        date.method("getTime", "()J") { runtime, args, _ in
            .int64(runtime.datePayload(args[0])?.millis ?? 0)
        }
        date.method("setTime", "(J)V") { runtime, args, _ in
            runtime.mutableDate(args[0]).millis = args[1].asInt64
            return .zero
        }
        date.method("before", "(Ljava/util/Date;)Z") { runtime, args, _ in
            let mine = runtime.datePayload(args[0])?.millis ?? 0
            let other = runtime.datePayload(args[1])?.millis ?? 0
            return .boolean(mine < other)
        }
        date.method("after", "(Ljava/util/Date;)Z") { runtime, args, _ in
            let mine = runtime.datePayload(args[0])?.millis ?? 0
            let other = runtime.datePayload(args[1])?.millis ?? 0
            return .boolean(mine > other)
        }
        date.method("compareTo", "(Ljava/util/Date;)I") { runtime, args, _ in
            let mine = runtime.datePayload(args[0])?.millis ?? 0
            let other = runtime.datePayload(args[1])?.millis ?? 0
            return .int32(mine < other ? -1 : (mine > other ? 1 : 0))
        }
        date.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let other = runtime.datePayload(args[1]) else { return .boolean(false) }
            return .boolean((runtime.datePayload(args[0])?.millis ?? 0) == other.millis)
        }
        date.method("hashCode", "()I") { runtime, args, _ in
            .int32(Int32(truncatingIfNeeded: (runtime.datePayload(args[0])?.millis ?? 0) ^ ((runtime.datePayload(args[0])?.millis ?? 0) >> 32)))
        }
        date.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let millis = runtime.datePayload(args[0])?.millis ?? 0
            let zone = defaultZone()
            let names = VMDateNames.english
            let formatted = format(millis, pattern: "EEE MMM dd HH:mm:ss zzz yyyy", names: names, zone: zone)
            return runtime.newString(formatted)
        }
        return [date]
    }

    // MARK: - java.util.TimeZone

    private static func timeZoneClasses() -> [NativeClass] {
        let zone = NativeClass("Ljava/util/TimeZone;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;", "Ljava/lang/Cloneable;"])
        zone.method("getID", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.timeZonePayload(args[0])?.id ?? "UTC")
        }
        zone.method("setID", "(Ljava/lang/String;)V") { runtime, args, _ in
            let resolved = resolveZone(runtime.stringValue(args[1]) ?? "UTC")
            let payload = runtime.mutableTimeZone(args[0])
            payload.id = resolved.id
            payload.secondsFromGMT = resolved.secondsFromGMT
            return .zero
        }
        zone.method("getRawOffset", "()I") { runtime, args, _ in
            .int32(Int32(runtime.timeZonePayload(args[0])?.secondsFromGMT ?? 0))
        }
        zone.method("setRawOffset", "(I)V") { runtime, args, _ in
            runtime.mutableTimeZone(args[0]).secondsFromGMT = Int(args[1].asInt32)
            return .zero
        }
        zone.method("getOffset", "(J)I") { runtime, args, _ in
            let payload = runtime.timeZonePayload(args[0]) ?? VMTimeZonePayload(id: "UTC", secondsFromGMT: 0)
            return .int32(Int32(offsetSeconds(payload, at: args[1].asInt64)))
        }
        zone.method("getOffset", "(IIIIII)I") { runtime, args, _ in
            // getOffset(era, year, month, day, dayOfWeek, milliseconds):
            // the last argument is the millisecond within the local day.
            let payload = runtime.timeZonePayload(args[0]) ?? VMTimeZonePayload(id: "UTC", secondsFromGMT: 0)
            let era = Int(args[1].asInt32)
            let year = era == 0 ? 1 - Int(args[2].asInt32) : Int(args[2].asInt32)
            let dayMillis = Int(args[6].asInt32)
            let instant = millis(
                year: year, month: Int(args[3].asInt32) + 1, day: Int(args[4].asInt32),
                hour: dayMillis / 3_600_000,
                minute: (dayMillis % 3_600_000) / 60_000,
                second: (dayMillis % 60_000) / 1000,
                millis: dayMillis % 1000,
                zone: payload
            )
            return .int32(Int32(offsetSeconds(payload, at: instant)))
        }
        zone.method("inDaylightTime", "(Ljava/util/Date;)Z") { runtime, args, _ in
            let payload = runtime.timeZonePayload(args[0]) ?? VMTimeZonePayload(id: "UTC", secondsFromGMT: 0)
            let instant = runtime.datePayload(args[1])?.millis ?? 0
            let offset = offsetSeconds(payload, at: instant)
            return .boolean(offset != payload.secondsFromGMT)
        }
        zone.method("useDaylightTime", "()Z") { runtime, args, _ in
            .boolean((runtime.timeZonePayload(args[0])?.id ?? "UTC").contains("/"))
        }
        zone.method("clone", "()Ljava/lang/Object;") { runtime, args, _ in
            let payload = runtime.timeZonePayload(args[0]) ?? VMTimeZonePayload(id: "UTC", secondsFromGMT: 0)
            return runtime.makeNative("Ljava/util/TimeZone;", payload: VMTimeZonePayload(id: payload.id, secondsFromGMT: payload.secondsFromGMT))
        }
        zone.method("hasSameRules", "(Ljava/util/TimeZone;)Z") { runtime, args, _ in
            let mine = runtime.timeZonePayload(args[0])?.id
            return .boolean(mine == runtime.timeZonePayload(args[1])?.id)
        }
        zone.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let mine = runtime.timeZonePayload(args[0])?.id
            guard let other = runtime.timeZonePayload(args[1]) else { return .boolean(false) }
            return .boolean(mine == other.id)
        }
        zone.method("hashCode", "()I") { runtime, args, _ in
            .int32(Int32(truncatingIfNeeded: (runtime.timeZonePayload(args[0])?.id ?? "UTC").hashValue))
        }
        zone.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.timeZonePayload(args[0])?.id ?? "UTC")
        }
        zone.staticMethod("getDefault", "()Ljava/util/TimeZone;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/TimeZone;", payload: defaultZone())
        }
        zone.staticMethod("getTimeZone", "(Ljava/lang/String;)Ljava/util/TimeZone;") { runtime, args, _ in
            let id = runtime.stringValue(args[0]) ?? "UTC"
            return runtime.makeNative("Ljava/util/TimeZone;", payload: resolveZone(id))
        }
        zone.staticMethod("setDefault", "(Ljava/util/TimeZone;)V") { _, _, _ in .zero }
        return [zone]
    }

    // MARK: - java.util.Calendar

    private static let calendarConstants: [(String, Int32)] = [
        ("ERA", 0), ("YEAR", 1), ("MONTH", 2), ("WEEK_OF_YEAR", 3), ("WEEK_OF_MONTH", 4),
        ("DATE", 5), ("DAY_OF_MONTH", 5), ("DAY_OF_YEAR", 6), ("DAY_OF_WEEK", 7),
        ("DAY_OF_WEEK_IN_MONTH", 8), ("AM_PM", 9), ("HOUR", 10), ("HOUR_OF_DAY", 11),
        ("MINUTE", 12), ("SECOND", 13), ("MILLISECOND", 14), ("ZONE_OFFSET", 15), ("DST_OFFSET", 16),
        ("SUNDAY", 1), ("MONDAY", 2), ("TUESDAY", 3), ("WEDNESDAY", 4), ("THURSDAY", 5),
        ("FRIDAY", 6), ("SATURDAY", 7),
        ("JANUARY", 0), ("FEBRUARY", 1), ("MARCH", 2), ("APRIL", 3), ("MAY", 4), ("JUNE", 5),
        ("JULY", 6), ("AUGUST", 7), ("SEPTEMBER", 8), ("OCTOBER", 9), ("NOVEMBER", 10), ("DECEMBER", 11),
        ("UNDECIMBER", 12), ("AM", 0), ("PM", 1),
    ]

    private static func calendarClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let calendar = NativeClass(
            "Ljava/util/Calendar;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/io/Serializable;", "Ljava/lang/Cloneable;", "Ljava/lang/Comparable;"]
        )
        for (name, _) in calendarConstants { calendar.staticField(name, "I") }
        calendar.prepare = { _, cls in
            for (name, value) in calendarConstants {
                if let field = cls.staticField(named: name) { cls.setStaticValue(field, .int32(value)) }
            }
        }
        for signature in ["()V", "(Ljava/util/TimeZone;)V", "(Ljava/util/Locale;)V"] {
            calendar.method("<init>", signature) { runtime, args, _ in
                let zone: VMTimeZonePayload
                if signature.contains("TimeZone"), let provided = runtime.timeZonePayload(args[1]) {
                    zone = VMTimeZonePayload(id: provided.id, secondsFromGMT: provided.secondsFromGMT)
                } else {
                    zone = defaultZone()
                }
                runtime.setPayload(args[0], VMCalendarPayload(millis: Int64(Date().timeIntervalSince1970 * 1000), zone: zone))
                return .zero
            }
        }
        calendar.staticMethod("getInstance", "()Ljava/util/Calendar;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/GregorianCalendar;", payload: VMCalendarPayload(
                millis: Int64(Date().timeIntervalSince1970 * 1000), zone: defaultZone()
            ))
        }
        calendar.staticMethod("getInstance", "(Ljava/util/TimeZone;)Ljava/util/Calendar;") { runtime, args, _ in
            let zone = runtime.timeZonePayload(args[0]) ?? defaultZone()
            return runtime.makeNative("Ljava/util/GregorianCalendar;", payload: VMCalendarPayload(
                millis: Int64(Date().timeIntervalSince1970 * 1000),
                zone: VMTimeZonePayload(id: zone.id, secondsFromGMT: zone.secondsFromGMT)
            ))
        }
        calendar.staticMethod("getInstance", "(Ljava/util/Locale;)Ljava/util/Calendar;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/GregorianCalendar;", payload: VMCalendarPayload(
                millis: Int64(Date().timeIntervalSince1970 * 1000), zone: defaultZone()
            ))
        }
        calendar.method("get", "(I)I") { runtime, args, _ in
            let payload: VMCalendarPayload = try runtime.payloadBox(args[0])
            return .int32(Int32(fieldValue(payload, field: Int(args[1].asInt32))))
        }
        calendar.method("getTimeInMillis", "()J") { runtime, args, _ in
            .int64(runtime.calendarPayload(args[0])?.millis ?? 0)
        }
        calendar.method("getTime", "()Ljava/util/Date;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/Date;", payload: VMDatePayload(runtime.calendarPayload(args[0])?.millis ?? 0))
        }
        calendar.method("setTimeInMillis", "(J)V") { runtime, args, _ in
            runtime.mutableCalendar(args[0]).millis = args[1].asInt64
            return .zero
        }
        calendar.method("setTime", "(Ljava/util/Date;)V") { runtime, args, _ in
            runtime.mutableCalendar(args[0]).millis = runtime.datePayload(args[1])?.millis ?? 0
            return .zero
        }
        calendar.method("set", "(II)V") { runtime, args, _ in
            let payload = runtime.mutableCalendar(args[0])
            applyField(payload, field: Int(args[1].asInt32), value: Int(args[2].asInt32))
            return .zero
        }
        calendar.method("set", "(III)V") { runtime, args, _ in
            let payload = runtime.mutableCalendar(args[0])
            let components = components(millis: payload.millis, zone: payload.zone)
            payload.millis = millis(
                year: Int(args[1].asInt32), month: Int(args[2].asInt32) + 1, day: Int(args[3].asInt32),
                hour: components.hour, minute: components.minute, second: components.second, millis: components.millis,
                zone: payload.zone
            )
            return .zero
        }
        calendar.method("set", "(IIIII)V") { runtime, args, _ in
            let payload = runtime.mutableCalendar(args[0])
            let components = components(millis: payload.millis, zone: payload.zone)
            payload.millis = millis(
                year: Int(args[1].asInt32), month: Int(args[2].asInt32) + 1, day: Int(args[3].asInt32),
                hour: Int(args[4].asInt32), minute: Int(args[5].asInt32), second: components.second, millis: components.millis,
                zone: payload.zone
            )
            return .zero
        }
        calendar.method("set", "(IIIIII)V") { runtime, args, _ in
            let payload = runtime.mutableCalendar(args[0])
            payload.millis = millis(
                year: Int(args[1].asInt32), month: Int(args[2].asInt32) + 1, day: Int(args[3].asInt32),
                hour: Int(args[4].asInt32), minute: Int(args[5].asInt32), second: Int(args[6].asInt32),
                zone: payload.zone
            )
            return .zero
        }
        calendar.method("add", "(II)V") { runtime, args, _ in
            let payload = runtime.mutableCalendar(args[0])
            add(payload, field: Int(args[1].asInt32), amount: Int(args[2].asInt32))
            return .zero
        }
        calendar.method("roll", "(II)V") { runtime, args, _ in
            let payload = runtime.mutableCalendar(args[0])
            let field = Int(args[1].asInt32)
            let amount = Int(args[2].asInt32)
            guard field == 5 || field == 6 || field == 11 || field == 12 || field == 13 else {
                add(payload, field: field, amount: amount)
                return .zero
            }
            add(payload, field: field, amount: amount)
            return .zero
        }
        calendar.method("clear", "()V") { runtime, args, _ in
            let payload = runtime.mutableCalendar(args[0])
            payload.millis = millis(year: 1970, month: 1, day: 1, zone: payload.zone)
            return .zero
        }
        calendar.method("clear", "(I)V") { runtime, args, _ in
            let payload = runtime.mutableCalendar(args[0])
            let components = components(millis: payload.millis, zone: payload.zone)
            switch Int(args[1].asInt32) {
            case 1: payload.millis = millis(year: 1970, month: components.month, day: components.day, hour: components.hour, minute: components.minute, second: components.second, millis: components.millis, zone: payload.zone)
            case 2: payload.millis = millis(year: components.year, month: 1, day: components.day, hour: components.hour, minute: components.minute, second: components.second, millis: components.millis, zone: payload.zone)
            case 5: payload.millis = millis(year: components.year, month: components.month, day: 1, hour: components.hour, minute: components.minute, second: components.second, millis: components.millis, zone: payload.zone)
            case 11: payload.millis = millis(year: components.year, month: components.month, day: components.day, hour: 0, minute: components.minute, second: components.second, millis: components.millis, zone: payload.zone)
            case 12: payload.millis = millis(year: components.year, month: components.month, day: components.day, hour: components.hour, minute: 0, second: components.second, millis: components.millis, zone: payload.zone)
            case 13: payload.millis = millis(year: components.year, month: components.month, day: components.day, hour: components.hour, minute: components.minute, second: 0, millis: components.millis, zone: payload.zone)
            case 14: payload.millis = millis(year: components.year, month: components.month, day: components.day, hour: components.hour, minute: components.minute, second: components.second, millis: 0, zone: payload.zone)
            default: break
            }
            return .zero
        }
        calendar.method("getTimeZone", "()Ljava/util/TimeZone;") { runtime, args, _ in
            let zone = runtime.calendarPayload(args[0])?.zone ?? defaultZone()
            return runtime.makeNative("Ljava/util/TimeZone;", payload: VMTimeZonePayload(id: zone.id, secondsFromGMT: zone.secondsFromGMT))
        }
        calendar.method("setTimeZone", "(Ljava/util/TimeZone;)V") { runtime, args, _ in
            guard let zone = runtime.timeZonePayload(args[1]) else { return .zero }
            runtime.mutableCalendar(args[0]).zone = VMTimeZonePayload(id: zone.id, secondsFromGMT: zone.secondsFromGMT)
            return .zero
        }
        calendar.method("isLenient", "()Z") { runtime, args, _ in
            .boolean(runtime.calendarPayload(args[0])?.lenient ?? true)
        }
        calendar.method("setLenient", "(Z)V") { runtime, args, _ in
            runtime.mutableCalendar(args[0]).lenient = args[1].asBoolean
            return .zero
        }
        calendar.method("getFirstDayOfWeek", "()I") { runtime, args, _ in
            .int32(Int32(runtime.calendarPayload(args[0])?.firstDayOfWeek ?? 1))
        }
        calendar.method("setFirstDayOfWeek", "(I)V") { runtime, args, _ in
            runtime.mutableCalendar(args[0]).firstDayOfWeek = Int(args[1].asInt32)
            return .zero
        }
        calendar.method("getMinimalDaysInFirstWeek", "()I") { runtime, args, _ in
            .int32(Int32(runtime.calendarPayload(args[0])?.minimalDaysInFirstWeek ?? 1))
        }
        calendar.method("setMinimalDaysInFirstWeek", "(I)V") { runtime, args, _ in
            runtime.mutableCalendar(args[0]).minimalDaysInFirstWeek = Int(args[1].asInt32)
            return .zero
        }
        calendar.method("getActualMaximum", "(I)I") { runtime, args, _ in
            let payload: VMCalendarPayload = try runtime.payloadBox(args[0])
            let components = components(millis: payload.millis, zone: payload.zone)
            switch Int(args[1].asInt32) {
            case 5: return .int32(Int32(daysInMonth(year: components.year, month: components.month)))
            case 6:
                let leap = (components.year % 4 == 0 && components.year % 100 != 0) || components.year % 400 == 0
                return .int32(leap ? 366 : 365)
            case 2: return .int32(11)
            case 11: return .int32(23)
            default: return .int32(Int32(fieldValue(payload, field: Int(args[1].asInt32))))
            }
        }
        calendar.method("getActualMinimum", "(I)I") { runtime, args, _ in
            let field = Int(args[1].asInt32)
            return .int32(field == 5 || field == 6 || field == 11 || field == 12 || field == 13 || field == 14 ? 1 : 0)
        }
        calendar.method("compareTo", "(Ljava/util/Calendar;)I") { runtime, args, _ in
            let mine = runtime.calendarPayload(args[0])?.millis ?? 0
            let other = runtime.calendarPayload(args[1])?.millis ?? 0
            return .int32(mine < other ? -1 : (mine > other ? 1 : 0))
        }
        calendar.method("clone", "()Ljava/lang/Object;") { runtime, args, _ in
            let payload = runtime.calendarPayload(args[0]) ?? VMCalendarPayload(millis: 0, zone: defaultZone())
            return runtime.makeNative("Ljava/util/GregorianCalendar;", payload: payload.copy)
        }
        calendar.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let other = runtime.calendarPayload(args[1]) else { return .boolean(false) }
            return .boolean((runtime.calendarPayload(args[0])?.millis ?? 0) == other.millis)
        }
        calendar.method("hashCode", "()I") { runtime, args, _ in
            let millisValue = runtime.calendarPayload(args[0])?.millis ?? 0
            return .int32(Int32(truncatingIfNeeded: millisValue ^ (millisValue >> 32)))
        }
        calendar.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let payload = runtime.calendarPayload(args[0]) ?? VMCalendarPayload(millis: 0, zone: defaultZone())
            let components = components(millis: payload.millis, zone: payload.zone)
            let text = String(
                format: "java.util.GregorianCalendar[time=%lld,YEAR=%d,MONTH=%d,DAY_OF_MONTH=%d,HOUR_OF_DAY=%d,MINUTE=%d,SECOND=%d,MILLISECOND=%d]",
                payload.millis, components.year, components.month - 1, components.day,
                components.hour, components.minute, components.second, components.millis
            )
            return runtime.newString(text)
        }
        result.append(calendar)

        let gregorian = NativeClass("Ljava/util/GregorianCalendar;", superclass: "Ljava/util/Calendar;")
        gregorian.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMCalendarPayload(millis: Int64(Date().timeIntervalSince1970 * 1000), zone: defaultZone()))
            return .zero
        }
        gregorian.method("<init>", "(Ljava/util/TimeZone;)V") { runtime, args, _ in
            let zone = runtime.timeZonePayload(args[1]) ?? defaultZone()
            runtime.setPayload(args[0], VMCalendarPayload(
                millis: Int64(Date().timeIntervalSince1970 * 1000),
                zone: VMTimeZonePayload(id: zone.id, secondsFromGMT: zone.secondsFromGMT)
            ))
            return .zero
        }
        gregorian.method("<init>", "(IIIII)V") { runtime, args, _ in
            let zone = defaultZone()
            runtime.setPayload(args[0], VMCalendarPayload(
                millis: millis(
                    year: Int(args[1].asInt32), month: Int(args[2].asInt32) + 1, day: Int(args[3].asInt32),
                    hour: Int(args[4].asInt32), minute: Int(args[5].asInt32), zone: zone
                ),
                zone: zone
            ))
            return .zero
        }
        result.append(gregorian)
        return result
    }

    /// Reads one calendar field from the current instant.
    static func fieldValue(_ payload: VMCalendarPayload, field: Int) -> Int {
        let components = components(millis: payload.millis, zone: payload.zone)
        let weekday = ((components.days + 4) % 7 + 7) % 7 + 1
        switch field {
        case 0: return components.year > 0 ? 1 : 0
        case 1: return components.year
        case 2: return components.month - 1
        case 3:
            let dayOfYear = components.days - daysFromCivil(components.year, 1, 1) + 1
            let firstWeekday = weekday - (dayOfYear - 1) % 7
            let week = (dayOfYear - 1 + ((firstWeekday - payload.firstDayOfWeek + 7) % 7)) / 7 + 1
            return week
        case 4:
            let firstWeekday = weekday - (components.day - 1) % 7
            return (components.day - 1 + ((firstWeekday - payload.firstDayOfWeek + 7) % 7)) / 7 + 1
        case 5: return components.day
        case 6: return components.days - daysFromCivil(components.year, 1, 1) + 1
        case 7: return weekday
        case 8: return (components.day - 1) / 7 + 1
        case 9: return components.hour < 12 ? 0 : 1
        case 10: return components.hour % 12
        case 11: return components.hour
        case 12: return components.minute
        case 13: return components.second
        case 14: return components.millis
        case 15: return components.offset
        case 16: return 0
        default: return 0
        }
    }

    /// `Calendar.set(field, value)` for one field, preserving the others.
    static func applyField(_ payload: VMCalendarPayload, field: Int, value: Int) {
        let components = components(millis: payload.millis, zone: payload.zone)
        var year = components.year
        var month = components.month
        var day = components.day
        var hour = components.hour
        var minute = components.minute
        var second = components.second
        var millisValue = components.millis
        switch field {
        case 0: if value <= 0 { year = 1 - year }
        case 1: year = value
        case 2:
            // Normalise an out-of-range month the way a lenient calendar does.
            let total = year * 12 + value
            year = Int(floorDivide(Int64(total), 12))
            month = total - year * 12 + 1
        case 3, 4: break
        case 5: day = value
        case 6: day = value - (components.days - daysFromCivil(year, 1, 1))
        case 7:
            let current = ((components.days + 4) % 7 + 7) % 7 + 1
            let delta = value - current
            let shifted = civilFromDays(components.days + delta)
            year = shifted.year
            month = shifted.month
            day = shifted.day
        case 9: hour = (hour / 12) * 12 + (value == 0 ? 0 : 12)
        case 10: hour = (hour / 12) * 12 + value
        case 11: hour = value
        case 12: minute = value
        case 13: second = value
        case 14: millisValue = value
        case 15, 16: break
        default: break
        }
        payload.millis = millis(year: year, month: month, day: day, hour: hour, minute: minute, second: second, millis: millisValue, zone: payload.zone)
    }

    /// `Calendar.add(field, amount)`: wall-clock units for sub-day fields.
    static func add(_ payload: VMCalendarPayload, field: Int, amount: Int) {
        let components = components(millis: payload.millis, zone: payload.zone)
        switch field {
        case 1:
            payload.millis = millis(year: components.year + amount, month: components.month, day: components.day, hour: components.hour, minute: components.minute, second: components.second, millis: components.millis, zone: payload.zone)
        case 2:
            let total = components.year * 12 + (components.month - 1) + amount
            let year = Int(floorDivide(Int64(total), 12))
            let month = total - year * 12 + 1
            payload.millis = millis(year: year, month: month, day: components.day, hour: components.hour, minute: components.minute, second: components.second, millis: components.millis, zone: payload.zone)
        case 3:
            payload.millis = millis(year: components.year, month: components.month, day: components.day + amount * 7, hour: components.hour, minute: components.minute, second: components.second, millis: components.millis, zone: payload.zone)
        case 5, 6:
            payload.millis = millis(year: components.year, month: components.month, day: components.day + amount, hour: components.hour, minute: components.minute, second: components.second, millis: components.millis, zone: payload.zone)
        case 9:
            payload.millis = millis(year: components.year, month: components.month, day: components.day, hour: components.hour + amount * 12, minute: components.minute, second: components.second, millis: components.millis, zone: payload.zone)
        case 11, 10:
            payload.millis += Int64(amount) * 3_600_000
        case 12:
            payload.millis += Int64(amount) * 60_000
        case 13:
            payload.millis += Int64(amount) * 1000
        case 14:
            payload.millis += Int64(amount)
        default:
            payload.millis += Int64(amount) * 86_400_000
        }
    }

    // MARK: - java.text

    private static func formatClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let parsePosition = NativeClass("Ljava/text/ParsePosition;", superclass: "Ljava/lang/Object;")
        parsePosition.method("<init>", "(I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMParsePositionPayload(index: Int(args[1].asInt32)))
            return .zero
        }
        parsePosition.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMParsePositionPayload())
            return .zero
        }
        parsePosition.method("getIndex", "()I") { runtime, args, _ in
            .int32(Int32(runtime.parsePositionPayload(args[0])?.index ?? 0))
        }
        parsePosition.method("setIndex", "(I)V") { runtime, args, _ in
            runtime.mutableParsePosition(args[0]).index = Int(args[1].asInt32)
            return .zero
        }
        parsePosition.method("getErrorIndex", "()I") { runtime, args, _ in
            .int32(Int32(runtime.parsePositionPayload(args[0])?.errorIndex ?? -1))
        }
        parsePosition.method("setErrorIndex", "(I)V") { runtime, args, _ in
            runtime.mutableParsePosition(args[0]).errorIndex = Int(args[1].asInt32)
            return .zero
        }
        parsePosition.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let payload = runtime.parsePositionPayload(args[0]) ?? VMParsePositionPayload()
            return runtime.newString("java.text.ParsePosition[index=\(payload.index),errorIndex=\(payload.errorIndex)]")
        }
        result.append(parsePosition)

        let parseException = NativeClass("Ljava/text/ParseException;", superclass: "Ljava/lang/Exception;")
        parseException.method("<init>", "(Ljava/lang/String;I)V") { runtime, args, _ in
            runtime.setPayload(args[0], Int64(args[2].asInt32))
            return .zero
        }
        parseException.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            runtime.setPayload(args[0], Int64(0))
            return .zero
        }
        parseException.method("getErrorOffset", "()I") { runtime, args, _ in
            .int32(Int32(truncatingIfNeeded: runtime.payload(args[0], as: Int64.self) ?? 0))
        }
        result.append(parseException)

        let formatClass = NativeClass("Ljava/text/Format;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;", "Ljava/lang/Cloneable;"])
        formatClass.method("format", "(Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            try formatObject(runtime, value: args[1], selfValue: args[0])
        }
        formatClass.method("parseObject", "(Ljava/lang/String;)Ljava/lang/Object;") { runtime, args, _ in
            try parseObject(runtime, text: runtime.stringValue(args[1]) ?? "", selfValue: args[0])
        }
        result.append(formatClass)

        let dateFormat = NativeClass("Ljava/text/DateFormat;", superclass: "Ljava/text/Format;")
        dateFormat.method("format", "(Ljava/util/Date;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMDateFormatPayload = try runtime.payloadBox(args[0])
            let millisValue = runtime.datePayload(args[1])?.millis ?? 0
            return runtime.newString(format(millisValue, pattern: payload.pattern, names: VMDateNames.forLanguage(payload.language), zone: payload.zone))
        }
        dateFormat.method("parse", "(Ljava/lang/String;)Ljava/util/Date;") { runtime, args, _ in
            let payload: VMDateFormatPayload = try runtime.payloadBox(args[0])
            let text = runtime.stringValue(args[1]) ?? ""
            guard let parsed = parse(text, pattern: payload.pattern, names: VMDateNames.forLanguage(payload.language), lenient: payload.lenient) else {
                throw VMJavaException("Ljava/text/ParseException;", "Unparseable date: \"\(text)\"")
            }
            return runtime.makeNative("Ljava/util/Date;", payload: VMDatePayload(resolve(parsed.fields, payload: payload)))
        }
        dateFormat.method("parse", "(Ljava/lang/String;Ljava/text/ParsePosition;)Ljava/util/Date;") { runtime, args, _ in
            let payload: VMDateFormatPayload = try runtime.payloadBox(args[0])
            let text = runtime.stringValue(args[1]) ?? ""
            guard let position = runtime.parsePositionPayload(args[2]) else { return .null }
            let start = max(0, position.index)
            let slice = String(Array(text)[min(start, Array(text).count)...])
            guard let parsed = parse(slice, pattern: payload.pattern, names: VMDateNames.forLanguage(payload.language), lenient: payload.lenient) else {
                position.errorIndex = start
                return .null
            }
            position.index = start + parsed.consumed
            position.errorIndex = -1
            return runtime.makeNative("Ljava/util/Date;", payload: VMDatePayload(resolve(parsed.fields, payload: payload)))
        }
        dateFormat.method("getTimeZone", "()Ljava/util/TimeZone;") { runtime, args, _ in
            let payload: VMDateFormatPayload = try runtime.payloadBox(args[0])
            return runtime.makeNative("Ljava/util/TimeZone;", payload: VMTimeZonePayload(id: payload.zone.id, secondsFromGMT: payload.zone.secondsFromGMT))
        }
        dateFormat.method("setTimeZone", "(Ljava/util/TimeZone;)V") { runtime, args, _ in
            guard let zone = runtime.timeZonePayload(args[1]) else { return .zero }
            let payload: VMDateFormatPayload = try runtime.payloadBox(args[0])
            payload.zone = VMTimeZonePayload(id: zone.id, secondsFromGMT: zone.secondsFromGMT)
            return .zero
        }
        dateFormat.method("isLenient", "()Z") { runtime, args, _ in
            let payload: VMDateFormatPayload = try runtime.payloadBox(args[0])
            return .boolean(payload.lenient)
        }
        dateFormat.method("setLenient", "(Z)V") { runtime, args, _ in
            let payload: VMDateFormatPayload = try runtime.payloadBox(args[0])
            payload.lenient = args[1].asBoolean
            return .zero
        }
        result.append(dateFormat)

        let simple = NativeClass("Ljava/text/SimpleDateFormat;", superclass: "Ljava/text/DateFormat;")
        simple.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMDateFormatPayload(
                pattern: runtime.stringValue(args[1]) ?? "",
                language: "en",
                zone: defaultZone()
            ))
            return .zero
        }
        simple.method("<init>", "(Ljava/lang/String;Ljava/util/Locale;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMDateFormatPayload(
                pattern: runtime.stringValue(args[1]) ?? "",
                language: localeLanguage(runtime, args[2]),
                zone: defaultZone()
            ))
            return .zero
        }
        simple.method("applyPattern", "(Ljava/lang/String;)V") { runtime, args, _ in
            let payload: VMDateFormatPayload = try runtime.payloadBox(args[0])
            payload.pattern = runtime.stringValue(args[1]) ?? ""
            return .zero
        }
        simple.method("toPattern", "()Ljava/lang/String;") { runtime, args, _ in
            let payload: VMDateFormatPayload = try runtime.payloadBox(args[0])
            return runtime.newString(payload.pattern)
        }
        simple.method("toLocalizedPattern", "()Ljava/lang/String;") { runtime, args, _ in
            let payload: VMDateFormatPayload = try runtime.payloadBox(args[0])
            return runtime.newString(payload.pattern)
        }
        simple.method("clone", "()Ljava/lang/Object;") { runtime, args, _ in
            let payload: VMDateFormatPayload = try runtime.payloadBox(args[0])
            return runtime.makeNative("Ljava/text/SimpleDateFormat;", payload: VMDateFormatPayload(
                pattern: payload.pattern, language: payload.language,
                zone: VMTimeZonePayload(id: payload.zone.id, secondsFromGMT: payload.zone.secondsFromGMT)
            ))
        }
        result.append(simple)

        let numberFormat = NativeClass("Ljava/text/NumberFormat;", superclass: "Ljava/text/Format;")
        numberFormat.staticMethod("getNumberInstance", "()Ljava/text/NumberFormat;") { runtime, _, _ in
            runtime.makeNative("Ljava/text/DecimalFormat;", payload: decimalFormatPayload("#,##0.###"))
        }
        numberFormat.staticMethod("getInstance", "()Ljava/text/NumberFormat;") { runtime, _, _ in
            runtime.makeNative("Ljava/text/DecimalFormat;", payload: decimalFormatPayload("#,##0.###"))
        }
        result.append(numberFormat)

        let decimal = NativeClass("Ljava/text/DecimalFormat;", superclass: "Ljava/text/NumberFormat;")
        decimal.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            runtime.setPayload(args[0], decimalFormatPayload(runtime.stringValue(args[1]) ?? ""))
            return .zero
        }
        decimal.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], decimalFormatPayload("#,##0.###"))
            return .zero
        }
        decimal.method("applyPattern", "(Ljava/lang/String;)V") { runtime, args, _ in
            let parsed = decimalFormatPayload(runtime.stringValue(args[1]) ?? "")
            runtime.setPayload(args[0], parsed)
            return .zero
        }
        decimal.method("toPattern", "()Ljava/lang/String;") { runtime, args, _ in
            let payload: VMDecimalFormatPayload = try runtime.payloadBox(args[0])
            return runtime.newString(payload.pattern)
        }
        decimal.method("format", "(D)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMDecimalFormatPayload = try runtime.payloadBox(args[0])
            return runtime.newString(formatNumber(args[1].asDouble, payload))
        }
        decimal.method("format", "(J)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMDecimalFormatPayload = try runtime.payloadBox(args[0])
            return runtime.newString(formatNumber(Double(args[1].asInt64), payload))
        }
        decimal.method("setGroupingUsed", "(Z)V") { runtime, args, _ in
            let payload: VMDecimalFormatPayload = try runtime.payloadBox(args[0])
            payload.groupingUsed = args[1].asBoolean
            return .zero
        }
        decimal.method("isGroupingUsed", "()Z") { runtime, args, _ in
            let payload: VMDecimalFormatPayload = try runtime.payloadBox(args[0])
            return .boolean(payload.groupingUsed)
        }
        decimal.method("setMaximumFractionDigits", "(I)V") { runtime, args, _ in
            let payload: VMDecimalFormatPayload = try runtime.payloadBox(args[0])
            payload.maxFractionDigits = max(0, Int(args[1].asInt32))
            return .zero
        }
        decimal.method("getMaximumFractionDigits", "()I") { runtime, args, _ in
            let payload: VMDecimalFormatPayload = try runtime.payloadBox(args[0])
            return .int32(Int32(payload.maxFractionDigits))
        }
        decimal.method("setMinimumFractionDigits", "(I)V") { runtime, args, _ in
            let payload: VMDecimalFormatPayload = try runtime.payloadBox(args[0])
            payload.minFractionDigits = max(0, Int(args[1].asInt32))
            return .zero
        }
        decimal.method("getMinimumFractionDigits", "()I") { runtime, args, _ in
            let payload: VMDecimalFormatPayload = try runtime.payloadBox(args[0])
            return .int32(Int32(payload.minFractionDigits))
        }
        decimal.method("setMaximumIntegerDigits", "(I)V") { runtime, args, _ in
            let payload: VMDecimalFormatPayload = try runtime.payloadBox(args[0])
            payload.minIntegerDigits = max(0, Int(args[1].asInt32))
            return .zero
        }
        decimal.method("setMinimumIntegerDigits", "(I)V") { runtime, args, _ in
            let payload: VMDecimalFormatPayload = try runtime.payloadBox(args[0])
            payload.minIntegerDigits = max(0, Int(args[1].asInt32))
            return .zero
        }
        decimal.method("clone", "()Ljava/lang/Object;") { runtime, args, _ in
            let payload: VMDecimalFormatPayload = try runtime.payloadBox(args[0])
            return runtime.makeNative("Ljava/text/DecimalFormat;", payload: decimalFormatPayload(payload.pattern))
        }
        result.append(decimal)

        return result
    }

    static func localeLanguage(_ runtime: VMRuntime, _ value: VMValue) -> String {
        guard let locale = runtime.stringValue(value), !locale.isEmpty else { return "en" }
        let code = locale.split(separator: "_").first.map(String.init) ?? locale
        return code.isEmpty ? "en" : code
    }

    // MARK: - Date pattern parsing

    struct ParsedDate {
        var fields: DateFields
        var consumed: Int
    }

    struct DateFields {
        var year = 1970
        var month = 1
        var day = 1
        var hour = 0
        var minute = 0
        var second = 0
        var millis = 0
        var dayOfYear: Int?
        var offset: Int?
        var hour12: Int?
        var isPM: Bool?
        var parsed = false
    }

    /// Case- and punctuation-insensitive form used to match month and
    /// weekday names, which sites render with or without a trailing period.
    static func normalizeWord(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Month number (1-12) for a spelled-out name, preferring the longest name
    /// that matches. Falls back to English for locales whose sites still emit
    /// English dates.
    static func monthNumber(for word: String, names: VMDateNames) -> Int? {
        let cleaned = normalizeWord(word)
        guard cleaned.count >= 3 else { return nil }
        var best: (index: Int, length: Int)?
        func consider(_ candidates: [String]) {
            for (offset, name) in candidates.enumerated() {
                let candidate = normalizeWord(name)
                guard !candidate.isEmpty else { continue }
                if candidate.hasPrefix(cleaned) || cleaned.hasPrefix(candidate) {
                    if best == nil || candidate.count > best!.length { best = (offset + 1, candidate.count) }
                }
            }
        }
        consider(names.monthsFull)
        consider(names.monthsShort)
        if best == nil, names.language != "en" {
            consider(VMDateNames.english.monthsFull)
            consider(VMDateNames.english.monthsShort)
        }
        return best?.index
    }

    static func resolve(_ parsed: DateFields, payload: VMDateFormatPayload) -> Int64 {
        if let offset = parsed.offset {
            return epochMillis(
                year: parsed.year, month: parsed.month, day: parsed.day,
                hour: parsed.hour, minute: parsed.minute, second: parsed.second, millis: parsed.millis
            ) - Int64(offset) * 1000
        }
        return millis(
            year: parsed.year, month: parsed.month, day: parsed.day,
            hour: parsed.hour, minute: parsed.minute, second: parsed.second, millis: parsed.millis,
            zone: payload.zone
        )
    }

    static func parse(
        _ text: String,
        pattern: String,
        names: VMDateNames,
        lenient: Bool
    ) -> ParsedDate? {
        let input = Array(text)
        let tokens = Array(pattern)
        var fields = DateFields()
        var index = 0
        var tokenIndex = 0
        var failed = false

        func readDigits(_ maxDigits: Int) -> Int? {
            var count = 0
            var value = 0
            while index < input.count, count < maxDigits, input[index].isNumber {
                value = value * 10 + (Int(String(input[index])) ?? 0)
                index += 1
                count += 1
            }
            return count == 0 ? nil : value
        }

        func readWord() -> String {
            var word = ""
            while index < input.count, input[index].isLetter || input[index] == "." {
                word.append(input[index])
                index += 1
            }
            return word
        }

        func readOffset(_ allowZ: Bool) -> Int? {
            let save = index
            if index < input.count, input[index] == "Z" || input[index] == "z" {
                if allowZ { index += 1; return 0 }
            }
            var sign: Int?
            if index < input.count, input[index] == "+" || input[index] == "-" {
                sign = input[index] == "-" ? -1 : 1
                index += 1
            } else {
                var word = ""
                while index < input.count, input[index].isLetter { word.append(input[index]); index += 1 }
                let upper = word.uppercased()
                if upper == "GMT" || upper == "UTC" {
                    if index < input.count, input[index] == "+" || input[index] == "-" {
                        sign = input[index] == "-" ? -1 : 1
                        index += 1
                    } else {
                        return 0
                    }
                } else {
                    index = save
                    return nil
                }
            }
            guard let direction = sign, let hours = readDigits(2) else {
                index = save
                return nil
            }
            var minutes = 0
            if index < input.count, input[index] == ":" {
                index += 1
                minutes = readDigits(2) ?? 0
            } else if let value = readDigits(2) {
                minutes = value
            }
            var seconds = 0
            if index < input.count, input[index] == ":" {
                index += 1
                seconds = readDigits(2) ?? 0
            }
            return direction * (hours * 3600 + minutes * 60 + seconds)
        }

        func normalize(_ word: String) -> String {
            normalizeWord(word)
        }

        while tokenIndex < tokens.count, !failed {
            let token = tokens[tokenIndex]
            if token == "'" {
                tokenIndex += 1
                if tokenIndex < tokens.count, tokens[tokenIndex] == "'" {
                    if index < input.count, input[index] == "'" { index += 1 } else { failed = true }
                    tokenIndex += 1
                    continue
                }
                while tokenIndex < tokens.count, tokens[tokenIndex] != "'" {
                    if index < input.count, input[index] == tokens[tokenIndex] {
                        index += 1
                    } else {
                        failed = true
                        break
                    }
                    tokenIndex += 1
                }
                tokenIndex += 1
                continue
            }
            if !token.isLetter {
                if index < input.count, input[index] == token {
                    index += 1
                    tokenIndex += 1
                } else {
                    failed = true
                }
                continue
            }
            var length = 1
            while tokenIndex + length < tokens.count, tokens[tokenIndex + length] == token { length += 1 }
            switch token {
            case "y", "u":
                if let value = readDigits(length == 1 ? 4 : length) {
                    fields.year = (length == 2 && value < 100) ? 2000 + value : value
                    fields.parsed = true
                } else {
                    failed = true
                }
            case "M", "L":
                if length >= 3 {
                    let word = readWord()
                    _ = length
                    if let month = monthNumber(for: word, names: names) {
                        fields.month = month
                        fields.parsed = true
                    } else {
                        failed = true
                    }
                } else if let value = readDigits(2) {
                    fields.month = value
                    fields.parsed = true
                } else {
                    failed = true
                }
            case "d":
                if let value = readDigits(2) { fields.day = value; fields.parsed = true } else { failed = true }
            case "D":
                if let value = readDigits(3) { fields.dayOfYear = value; fields.parsed = true } else { failed = true }
            case "H":
                if let value = readDigits(2) { fields.hour = value; fields.parsed = true } else { failed = true }
            case "k":
                if let value = readDigits(2) { fields.hour = value == 24 ? 0 : value; fields.parsed = true } else { failed = true }
            case "h":
                if let value = readDigits(2) { fields.hour12 = value; fields.parsed = true } else { failed = true }
            case "K":
                if let value = readDigits(2) { fields.hour12 = value; fields.parsed = true } else { failed = true }
            case "m":
                if let value = readDigits(2) { fields.minute = value; fields.parsed = true } else { failed = true }
            case "s":
                if let value = readDigits(2) { fields.second = value; fields.parsed = true } else { failed = true }
            case "S":
                if let value = readDigits(9) {
                    fields.millis = min(999, value)
                    fields.parsed = true
                } else {
                    failed = true
                }
            case "E", "e", "c":
                let word = readWord()
                if word.isEmpty { failed = true }
            case "a":
                let cleaned = normalize(readWord())
                let pm = normalize(names.pm)
                let am = normalize(names.am)
                if cleaned.isEmpty {
                    failed = true
                } else if cleaned == pm || cleaned == "pm" || cleaned == "p" || pm.hasPrefix(cleaned) {
                    fields.isPM = true
                    fields.parsed = true
                } else if cleaned == am || cleaned == "am" || cleaned == "a" || am.hasPrefix(cleaned) {
                    fields.isPM = false
                    fields.parsed = true
                } else {
                    failed = true
                }
            case "G":
                let word = readWord().uppercased()
                if word.isEmpty { failed = true }
            case "Z", "X", "x":
                if let offset = readOffset(true) {
                    fields.offset = offset
                    fields.parsed = true
                } else {
                    failed = true
                }
            case "z":
                var word = ""
                while index < input.count, input[index].isLetter || input[index] == "/" || input[index] == "_" || input[index] == "+" || input[index] == "-" || input[index].isNumber {
                    word.append(input[index])
                    index += 1
                }
                if word.isEmpty { failed = true }
            case "w", "W":
                if readDigits(2) == nil { failed = true }
            default:
                if index < input.count, input[index] == token {
                    index += 1
                } else {
                    failed = true
                }
            }
            tokenIndex += length
        }

        guard !failed, fields.parsed else { return nil }

        if let hour12 = fields.hour12 {
            var hour = hour12
            if let isPM = fields.isPM {
                if isPM, hour < 12 { hour += 12 }
                if !isPM, hour == 12 { hour = 0 }
            }
            fields.hour = hour
        }

        if let dayOfYear = fields.dayOfYear {
            let shifted = civilFromDays(daysFromCivil(fields.year, 1, 1) + dayOfYear - 1)
            fields.month = shifted.month
            fields.day = shifted.day
        }

        if !lenient {
            guard fields.month >= 1, fields.month <= 12,
                  fields.day >= 1, fields.day <= daysInMonth(year: fields.year, month: fields.month),
                  fields.hour >= 0, fields.hour < 24,
                  fields.minute >= 0, fields.minute < 60,
                  fields.second >= 0, fields.second < 60,
                  fields.millis >= 0, fields.millis < 1000
            else { return nil }
        }

        // A lenient calendar rolls out-of-range values into the next unit, which
        // is also how the integer arithmetic below behaves.
        let total = fields.year * 12 + (fields.month - 1)
        let year = Int(floorDivide(Int64(total), 12))
        let month = total - year * 12 + 1
        let civil = civilFromDays(daysFromCivil(year, month, 1) + fields.day - 1)

        let result = DateFields(
            year: civil.year, month: civil.month, day: civil.day,
            hour: fields.hour, minute: fields.minute, second: fields.second,
            millis: fields.millis, dayOfYear: nil, offset: fields.offset,
            hour12: nil, isPM: nil, parsed: true
        )
        return ParsedDate(fields: result, consumed: index)
    }

    // MARK: - Date pattern formatting

    static func format(
        _ millisValue: Int64,
        pattern: String,
        names: VMDateNames,
        zone: VMTimeZonePayload
    ) -> String {
        let components = components(millis: millisValue, zone: zone)
        let weekday = ((components.days + 4) % 7 + 7) % 7
        let tokens = Array(pattern)
        var output = ""
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "'" {
                index += 1
                if index < tokens.count, tokens[index] == "'" {
                    output.append("'")
                    index += 1
                    continue
                }
                while index < tokens.count, tokens[index] != "'" {
                    output.append(tokens[index])
                    index += 1
                }
                index += 1
                continue
            }
            if !token.isLetter {
                output.append(token)
                index += 1
                continue
            }
            var length = 1
            while index + length < tokens.count, tokens[index + length] == token { length += 1 }
            switch token {
            case "y", "u":
                if length == 2 {
                    output += String(format: "%02d", ((components.year % 100) + 100) % 100)
                } else {
                    output += String(format: "%0\(max(4, length))d", components.year)
                }
            case "M", "L":
                let month = max(1, min(12, components.month))
                if length <= 2 {
                    output += String(format: "%0\(length)d", month)
                } else if length == 3 {
                    output += names.monthsShort[month - 1]
                } else {
                    output += names.monthsFull[month - 1]
                }
            case "d":
                output += String(format: "%0\(length)d", components.day)
            case "D":
                let dayOfYear = components.days - daysFromCivil(components.year, 1, 1) + 1
                output += String(format: "%0\(max(1, length))d", dayOfYear)
            case "E", "e", "c":
                if length >= 4 {
                    output += names.weekdaysFull[weekday]
                } else {
                    output += names.weekdaysShort[weekday]
                }
            case "H":
                output += String(format: "%0\(length)d", components.hour)
            case "k":
                output += String(format: "%0\(length)d", components.hour == 0 ? 24 : components.hour)
            case "h":
                let hour = components.hour % 12 == 0 ? 12 : components.hour % 12
                output += String(format: "%0\(length)d", hour)
            case "K":
                output += String(format: "%0\(length)d", components.hour % 12)
            case "m":
                output += String(format: "%0\(length)d", components.minute)
            case "s":
                output += String(format: "%0\(length)d", components.second)
            case "S":
                let digits = max(1, min(3, length))
                let scaled = components.millis / Int(pow(10, Double(3 - digits)))
                output += String(format: "%0\(digits)d", scaled)
            case "a":
                output += components.hour < 12 ? names.am : names.pm
            case "G":
                output += components.year <= 0 ? "BC" : "AD"
            case "Z":
                output += zoneText(components.offset, length: length, iso: false)
            case "X", "x":
                output += zoneText(components.offset, length: length, iso: true)
            case "z":
                output += zone.id
            case "w":
                let dayOfYear = components.days - daysFromCivil(components.year, 1, 1)
                output += String(format: "%0\(length)d", dayOfYear / 7 + 1)
            case "W":
                output += String(format: "%0\(length)d", (components.day - 1) / 7 + 1)
            default:
                output += String(repeating: token, count: length)
            }
            index += length
        }
        return output
    }

    static func zoneText(_ seconds: Int, length: Int, iso: Bool) -> String {
        if iso {
            if seconds == 0 { return "Z" }
            let sign = seconds < 0 ? "-" : "+"
            let magnitude = abs(seconds)
            if length == 1 {
                return magnitude % 3600 == 0
                    ? String(format: "%@%02d", sign, magnitude / 3600)
                    : String(format: "%@%02d%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
            }
            if length == 2 {
                return String(format: "%@%02d%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
            }
            return String(format: "%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
        }
        if length == 4 {
            if seconds == 0 { return "GMT" }
            let sign = seconds < 0 ? "-" : "+"
            let magnitude = abs(seconds)
            return String(format: "GMT%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
        }
        if length >= 5 {
            // ZZZZZ is the ISO 8601 extended offset, with "Z" for UTC.
            if seconds == 0 { return "Z" }
            let sign = seconds < 0 ? "-" : "+"
            let magnitude = abs(seconds)
            return String(format: "%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
        }
        if seconds == 0 { return "+0000" }
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        return String(format: "%@%02d%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
    }

    // MARK: - Number formatting

    static func decimalFormatPayload(_ pattern: String) -> VMDecimalFormatPayload {
        let payload = VMDecimalFormatPayload(pattern: pattern)
        let sections = splitPattern(pattern)
        let positive = sections.first ?? "#,##0.###"
        let negative = sections.count > 1 ? sections[1] : nil
        applyNumberPattern(positive, to: payload, negative: false)
        if let negative {
            applyNumberPattern(negative, to: payload, negative: true)
        } else {
            payload.negativePrefix = "-" + payload.positivePrefix
            payload.negativeSuffix = payload.positiveSuffix
        }
        return payload
    }

    private static func splitPattern(_ pattern: String) -> [String] {
        var sections: [String] = []
        var current = ""
        var quoted = false
        for character in pattern {
            if character == "'" { quoted.toggle() }
            if character == ";", !quoted {
                sections.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        sections.append(current)
        return sections
    }

    private static func applyNumberPattern(_ section: String, to payload: VMDecimalFormatPayload, negative: Bool) {
        var prefix = ""
        var suffix = ""
        var numeric = ""
        var quoted = false
        var seenDigit = false
        for character in section {
            if character == "'" {
                quoted.toggle()
                continue
            }
            if quoted {
                if seenDigit { suffix.append(character) } else { prefix.append(character) }
                continue
            }
            if character == "#" || character == "0" || character == "," || character == "." {
                numeric.append(character)
                seenDigit = true
            } else if character == "%" {
                payload.multiplier = 100
                if seenDigit { suffix.append(character) } else { prefix.append(character) }
            } else if seenDigit {
                suffix.append(character)
            } else {
                prefix.append(character)
            }
        }
        let parts = numeric.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerPart = parts.first.map(String.init) ?? ""
        let fractionPart = parts.count > 1 ? String(parts[1]) : ""
        payload.groupingUsed = integerPart.contains(",")
        if let comma = integerPart.lastIndex(of: ",") {
            payload.groupingSize = integerPart.distance(from: integerPart.index(after: comma), to: integerPart.endIndex)
        }
        payload.minIntegerDigits = max(1, integerPart.filter { $0 == "0" }.count)
        payload.maxFractionDigits = fractionPart.count
        payload.minFractionDigits = fractionPart.filter { $0 == "0" }.count
        if negative {
            payload.negativePrefix = prefix
            payload.negativeSuffix = suffix
        } else {
            payload.positivePrefix = prefix
            payload.positiveSuffix = suffix
        }
    }

    static func formatNumber(_ value: Double, _ payload: VMDecimalFormatPayload) -> String {
        let negative = value < 0 || (value == 0 && value.sign == .minus)
        var number = abs(value) * Double(payload.multiplier)
        if !number.isFinite { number = 0 }
        let scale = pow(10, Double(payload.maxFractionDigits))
        number = (number * scale).rounded() / scale
        var text = String(format: "%.\(payload.maxFractionDigits)f", number)
        var parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var integerPart = parts[0]
        var fraction = parts.count > 1 ? parts[1] : ""
        while fraction.count > payload.minFractionDigits, fraction.hasSuffix("0") {
            fraction.removeLast()
        }
        while integerPart.count < payload.minIntegerDigits {
            integerPart = "0" + integerPart
        }
        if payload.groupingUsed {
            integerPart = grouping(integerPart, size: max(1, payload.groupingSize), separator: String(payload.groupingSeparator))
        }
        text = fraction.isEmpty ? integerPart : integerPart + String(payload.decimalSeparator) + fraction
        return (negative ? payload.negativePrefix : payload.positivePrefix) + text
            + (negative ? payload.negativeSuffix : payload.positiveSuffix)
    }

    private static func grouping(_ digits: String, size: Int, separator: String) -> String {
        guard digits.count > size else { return digits }
        var output = ""
        var counter = 0
        for character in digits.reversed() {
            if counter == size {
                output += separator
                counter = 0
            }
            output.append(character)
            counter += 1
        }
        return String(output.reversed())
    }

    // MARK: - java.text.Format dispatch

    static func formatObject(_ runtime: VMRuntime, value: VMValue, selfValue: VMValue) throws -> VMValue {
        if let dateFormat: VMDateFormatPayload = runtime.payload(selfValue, as: VMDateFormatPayload.self) {
            let millisValue = runtime.datePayload(value)?.millis ?? numberValue(runtime, value).map { Int64($0) } ?? 0
            return runtime.newString(format(millisValue, pattern: dateFormat.pattern, names: VMDateNames.forLanguage(dateFormat.language), zone: dateFormat.zone))
        }
        if let decimal: VMDecimalFormatPayload = runtime.payload(selfValue, as: VMDecimalFormatPayload.self) {
            guard let number = numberValue(runtime, value) else { return runtime.newString("") }
            return runtime.newString(formatNumber(number, decimal))
        }
        throw VMJavaException("Ljava/lang/IllegalArgumentException;", "cannot format given Object as a Date or Number")
    }

    static func parseObject(_ runtime: VMRuntime, text: String, selfValue: VMValue) throws -> VMValue {
        if let dateFormat: VMDateFormatPayload = runtime.payload(selfValue, as: VMDateFormatPayload.self) {
            guard let parsed = parse(text, pattern: dateFormat.pattern, names: VMDateNames.forLanguage(dateFormat.language), lenient: dateFormat.lenient) else {
                throw VMJavaException("Ljava/text/ParseException;", "Unparseable date: \"\(text)\"")
            }
            return runtime.makeNative("Ljava/util/Date;", payload: VMDatePayload(resolve(parsed.fields, payload: dateFormat)))
        }
        if let decimal: VMDecimalFormatPayload = runtime.payload(selfValue, as: VMDecimalFormatPayload.self) {
            let cleaned = text
                .replacingOccurrences(of: String(decimal.groupingSeparator), with: "")
                .replacingOccurrences(of: String(decimal.decimalSeparator), with: ".")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Double(cleaned) else {
                throw VMJavaException("Ljava/text/ParseException;", "Unparseable number: \"\(text)\"")
            }
            return runtime.boxDouble(value / Double(decimal.multiplier))
        }
        throw VMJavaException("Ljava/lang/IllegalArgumentException;", "cannot parse given Object")
    }

    static func numberValue(_ runtime: VMRuntime, _ value: VMValue) -> Double? {
        guard value.bits != 0 else { return nil }
        if let pointer = value.object {
            let cls = VMObjectLayout.cls(pointer)
            if cls.isSubclass(of: runtime.cachedClass("Ljava/lang/Number;")) {
                if let method = cls.lookupVirtual(key: "doubleValue()D"), let result = try? runtime.invoke(method, [value]) {
                    return result.asDouble
                }
            }
        }
        return nil
    }
}

extension VMRuntime {
    func datePayload(_ value: VMValue) -> VMDatePayload? {
        payload(value, as: VMDatePayload.self)
    }

    func mutableDate(_ value: VMValue) -> VMDatePayload {
        if let existing: VMDatePayload = payload(value, as: VMDatePayload.self) { return existing }
        let created = VMDatePayload()
        setPayload(value, created)
        return created
    }

    func timeZonePayload(_ value: VMValue) -> VMTimeZonePayload? {
        payload(value, as: VMTimeZonePayload.self)
    }

    func mutableTimeZone(_ value: VMValue) -> VMTimeZonePayload {
        if let existing: VMTimeZonePayload = payload(value, as: VMTimeZonePayload.self) { return existing }
        let created = VMTimeZonePayload(id: "UTC", secondsFromGMT: 0)
        setPayload(value, created)
        return created
    }

    func calendarPayload(_ value: VMValue) -> VMCalendarPayload? {
        payload(value, as: VMCalendarPayload.self)
    }

    func mutableCalendar(_ value: VMValue) -> VMCalendarPayload {
        if let existing: VMCalendarPayload = payload(value, as: VMCalendarPayload.self) { return existing }
        let created = VMCalendarPayload(millis: 0, zone: JavaTextRuntime.defaultZone())
        setPayload(value, created)
        return created
    }

    func parsePositionPayload(_ value: VMValue) -> VMParsePositionPayload? {
        payload(value, as: VMParsePositionPayload.self)
    }

    func mutableParsePosition(_ value: VMValue) -> VMParsePositionPayload {
        if let existing: VMParsePositionPayload = payload(value, as: VMParsePositionPayload.self) { return existing }
        let created = VMParsePositionPayload()
        setPayload(value, created)
        return created
    }
}
