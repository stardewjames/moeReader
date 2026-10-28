//
//  JavaTimeRuntime.swift
//  MihonCompat
//
//  The slice of java.time extensions use for chapter dates. Parsing follows the
//  pattern the extension supplies. Zones are modelled as zone ids plus an
//  offset; region ids resolve through the platform time zone when available and
//  systemDefault always reflects `TimeZone.current`.
//

import Foundation

final class VMZonePayload: @unchecked Sendable {
    let id: String
    let secondsFromGMT: Int
    init(id: String, secondsFromGMT: Int) {
        self.id = id
        self.secondsFromGMT = secondsFromGMT
    }
}

/// One `appendText(field, map)` entry: a custom value-to-text table attached to
/// a formatter. The builder inserts a private-use marker token at the point the
/// table was appended, so formatting and parsing both use the table.
struct VMTextMapEntry {
    let field: String
    let values: [Int64: String]
}

final class VMDateTimeFormatterPayload {
    var pattern: String
    var zone: VMZonePayload?
    var language: String
    var caseInsensitive: Bool
    /// `ofLocalizedDate` style; the pattern is derived from it lazily so a later
    /// `withLocale` changes the localized form like the JDK.
    var localizedDateStyle: String?
    var textMaps: [VMTextMapEntry]
    /// `parseDefaulting` values keyed by `ChronoField` name.
    var defaults: [String: Int64]
    init(
        pattern: String,
        zone: VMZonePayload? = nil,
        language: String = "en",
        caseInsensitive: Bool = false,
        localizedDateStyle: String? = nil,
        textMaps: [VMTextMapEntry] = [],
        defaults: [String: Int64] = [:]
    ) {
        self.pattern = pattern
        self.zone = zone
        self.language = language
        self.caseInsensitive = caseInsensitive
        self.localizedDateStyle = localizedDateStyle
        self.textMaps = textMaps
        self.defaults = defaults
    }
}

final class VMYearPayload {
    var year: Int
    init(year: Int) { self.year = year }
}

final class VMDayOfWeekPayload {
    /// 1 = Monday ... 7 = Sunday, as `java.time.DayOfWeek`.
    var value: Int
    init(value: Int) { self.value = value }
}

final class VMTextStylePayload {
    let name: String
    init(name: String) { self.name = name }
}

final class VMChronoUnitPayload {
    let name: String
    init(name: String) { self.name = name }
}

final class VMFormatterBuilderPayload {
    var pattern = ""
    var caseInsensitive = false
    var textMaps: [VMTextMapEntry] = []
    var defaults: [String: Int64] = [:]
}

final class VMLocalDateTimePayload {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int
    var nano: Int
    init(year: Int = 1970, month: Int = 1, day: Int = 1, hour: Int = 0, minute: Int = 0, second: Int = 0, nano: Int = 0) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.nano = nano
    }

    /// java.time values are immutable, so derived values never share storage.
    func copy() -> VMLocalDateTimePayload {
        VMLocalDateTimePayload(year: year, month: month, day: day, hour: hour, minute: minute, second: second, nano: nano)
    }
}

final class VMLocalTimePayload {
    var hour: Int
    var minute: Int
    var second: Int
    var nano: Int
    init(hour: Int = 0, minute: Int = 0, second: Int = 0, nano: Int = 0) {
        self.hour = hour
        self.minute = minute
        self.second = second
        self.nano = nano
    }
}

final class VMLocalDatePayload {
    var year: Int
    var month: Int
    var day: Int
    init(year: Int = 1970, month: Int = 1, day: Int = 1) {
        self.year = year
        self.month = month
        self.day = day
    }
}

final class VMZonedDateTimePayload {
    let local: VMLocalDateTimePayload
    let zone: VMZonePayload
    init(local: VMLocalDateTimePayload, zone: VMZonePayload) {
        self.local = local
        self.zone = zone
    }
}

final class VMOffsetDateTimePayload {
    let local: VMLocalDateTimePayload
    let offset: VMZonePayload
    init(local: VMLocalDateTimePayload, offset: VMZonePayload) {
        self.local = local
        self.offset = offset
    }
}

final class VMInstantPayload {
    /// Floor milliseconds; `nano` holds the sub-millisecond remainder so
    /// nanosecond arithmetic keeps the value exact.
    var epochMilli: Int64
    var nano: Int32
    init(epochMilli: Int64, nano: Int32 = 0) {
        self.epochMilli = epochMilli
        self.nano = nano
    }
}

/// `java.time.temporal.ChronoField` (and the localized `WeekFields` field
/// objects, which share the payload shape).
final class VMChronoFieldPayload {
    let name: String
    /// `WeekFields.dayOfWeek()`: 1 = the first day of the week, not ISO Monday.
    let weekStart: Int?
    init(name: String, weekStart: Int? = nil) {
        self.name = name
        self.weekStart = weekStart
    }
}

final class VMWeekFieldsPayload {
    /// 1 = Monday ... 7 = Sunday, as `java.time.DayOfWeek`.
    let firstDayOfWeek: Int
    let minimalDays: Int
    init(firstDayOfWeek: Int, minimalDays: Int = 1) {
        self.firstDayOfWeek = firstDayOfWeek
        self.minimalDays = minimalDays
    }
}

final class VMMonthDayPayload {
    let month: Int
    let day: Int
    init(month: Int, day: Int) {
        self.month = month
        self.day = day
    }
}

final class VMDurationPayload {
    var seconds: Int64
    var nanos: Int32
    init(seconds: Int64, nanos: Int32 = 0) {
        self.seconds = seconds
        self.nanos = nanos
        normalize()
    }

    /// Keeps `nanos` in `0..<1_000_000_000` like `java.time.Duration`.
    func normalize() {
        var extra = Int64(nanos) / 1_000_000_000
        var rest = Int64(nanos) % 1_000_000_000
        if rest < 0 {
            rest += 1_000_000_000
            extra -= 1
        }
        seconds += extra
        nanos = Int32(rest)
    }
}

final class VMFormatStylePayload {
    let name: String
    init(name: String) { self.name = name }
}

final class VMSignStylePayload {
    let name: String
    init(name: String) { self.name = name }
}

enum JavaTimeRuntime {
    static let utc = VMZonePayload(id: "UTC", secondsFromGMT: 0)

    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(zoneIdClass())
        result.append(zoneOffsetClass())
        result.append(formatterClass())
        result.append(formatterBuilderClass())
        result.append(yearClass())
        result.append(dayOfWeekClass())
        result.append(textStyleClass())
        result.append(chronoUnitClass())
        result.append(localDateTimeClass())
        result.append(localDateClass())
        result.append(localTimeClass())
        result.append(zonedDateTimeClass())
        result.append(offsetDateTimeClass())
        result.append(instantClass())
        result.append(monthDayClass())
        result.append(durationClass())
        result.append(chronoFieldClass())
        result.append(weekFieldsClass())
        result.append(formatStyleClass())
        result.append(signStyleClass())
        result.append(marker("Ljava/time/temporal/TemporalAccessor;"))
        result.append(marker("Ljava/time/temporal/Temporal;"))
        result.append(marker("Ljava/time/temporal/TemporalField;"))
        result.append(marker("Ljava/time/temporal/TemporalUnit;"))
        result.append(marker("Ljava/time/temporal/TemporalAmount;"))
        result.append(marker("Ljava/time/chrono/ChronoLocalDate;", interfaces: ["Ljava/time/temporal/Temporal;"]))
        result.append(chronoZonedDateTimeClass())
        result.append(chronoLocalDateTimeClass())
        result.append(marker("Ljava/time/format/DateFormat;"))
        result.append(parseException())
        result.append(unsupportedTemporalTypeException())
        return result
    }

    private static func marker(_ descriptor: String, interfaces: [String] = []) -> NativeClass {
        NativeClass(descriptor, superclass: nil, interfaces: interfaces, access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
    }

    private static func zoneIdClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/ZoneId;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
        cls.method("getId", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString((runtime.payload(args[0], as: VMZonePayload.self) ?? utc).id)
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString((runtime.payload(args[0], as: VMZonePayload.self) ?? utc).id)
        }
        cls.staticMethod("systemDefault", "()Ljava/time/ZoneId;") { runtime, _, _ in
            runtime.makeNative("Ljava/time/ZoneId;", payload: systemDefaultZone())
        }
        cls.staticMethod("of", "(Ljava/lang/String;)Ljava/time/ZoneId;") { runtime, args, _ in
            let id = runtime.stringValue(args[0]) ?? "UTC"
            return runtime.makeNative("Ljava/time/ZoneId;", payload: parseZoneId(id))
        }
        return cls
    }

    private static func zoneOffsetClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/ZoneOffset;", superclass: "Ljava/time/ZoneId;")
        cls.staticField("UTC", "Ljava/time/ZoneOffset;")
        cls.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Ljava/time/ZoneOffset;", payload: utc)
        }
        cls.staticMethod("ofTotalSeconds", "(I)Ljava/time/ZoneOffset;") { runtime, args, _ in
            let seconds = Int(args[0].asInt32)
            guard abs(seconds) <= 18 * 3600 else {
                throw VMJavaException("Ljava/time/DateTimeException;", "Zone offset not in valid range: -18:00 to +18:00")
            }
            return runtime.makeNative("Ljava/time/ZoneOffset;", payload: VMZonePayload(id: offsetId(seconds), secondsFromGMT: seconds))
        }
        cls.staticMethod("ofHours", "(I)Ljava/time/ZoneOffset;") { runtime, args, _ in
            let hours = Int(args[0].asInt32)
            guard hours >= -18, hours <= 18 else {
                throw VMJavaException("Ljava/time/DateTimeException;", "Zone offset not in valid range: -18:00 to +18:00")
            }
            let seconds = hours * 3600
            return runtime.makeNative("Ljava/time/ZoneOffset;", payload: VMZonePayload(id: offsetId(seconds), secondsFromGMT: seconds))
        }
        cls.staticMethod("ofHoursMinutes", "(II)Ljava/time/ZoneOffset;") { runtime, args, _ in
            let hours = Int(args[0].asInt32)
            let minutes = Int(args[1].asInt32)
            guard hours >= -18, hours <= 18, minutes >= -59, minutes <= 59,
                  (hours > 0 && minutes >= 0) || (hours < 0 && minutes <= 0) || (hours == 0) else {
                throw VMJavaException("Ljava/time/DateTimeException;", "Zone offset not in valid range: -18:00 to +18:00")
            }
            let seconds = hours * 3600 + minutes * 60
            return runtime.makeNative("Ljava/time/ZoneOffset;", payload: VMZonePayload(id: offsetId(seconds), secondsFromGMT: seconds))
        }
        cls.staticMethod("of", "(Ljava/lang/String;)Ljava/time/ZoneOffset;") { runtime, args, _ in
            runtime.makeNative("Ljava/time/ZoneOffset;", payload: parseZoneId(runtime.stringValue(args[0]) ?? "+00:00"))
        }
        return cls
    }

    private static func formatterClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/format/DateTimeFormatter;", superclass: "Ljava/lang/Object;")
        cls.staticField("ISO_LOCAL_DATE", "Ljava/time/format/DateTimeFormatter;")
        cls.staticField("ISO_LOCAL_DATE_TIME", "Ljava/time/format/DateTimeFormatter;")
        cls.staticField("ISO_DATE_TIME", "Ljava/time/format/DateTimeFormatter;")
        cls.staticField("RFC_1123_DATE_TIME", "Ljava/time/format/DateTimeFormatter;")
        cls.staticField("ISO_OFFSET_DATE_TIME", "Ljava/time/format/DateTimeFormatter;")
        cls.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(pattern: "yyyy-MM-dd"))
            cls.staticValues[1] = runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(pattern: "yyyy-MM-dd'T'HH:mm:ss"))
            cls.staticValues[2] = runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(pattern: "yyyy-MM-dd'T'HH:mm:ss"))
            // RFC 1123 wants a two-digit day; the lenient parse pass also takes one.
            cls.staticValues[3] = runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(pattern: "EEE, dd MMM yyyy HH:mm:ss zzz"))
            cls.staticValues[4] = runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(pattern: "yyyy-MM-dd'T'HH:mm:ss[.SSSSSSSSS]XXX"))
        }
        cls.staticMethod("ofPattern", "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatter;") { runtime, args, _ in
            runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(pattern: runtime.stringValue(args[0]) ?? ""))
        }
        cls.staticMethod("ofLocalizedDate", "(Ljava/time/format/FormatStyle;)Ljava/time/format/DateTimeFormatter;") { runtime, args, _ in
            let style = runtime.payload(args[0], as: VMFormatStylePayload.self)?.name ?? "SHORT"
            let language = Locale.current.language.languageCode?.identifier ?? "en"
            return runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(
                pattern: localizedDatePattern(style, language: language),
                language: language,
                localizedDateStyle: style
            ))
        }
        cls.staticMethod("ofPattern", "(Ljava/lang/String;Ljava/util/Locale;)Ljava/time/format/DateTimeFormatter;") { runtime, args, _ in
            runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(
                pattern: runtime.stringValue(args[0]) ?? "",
                language: JavaTextRuntime.localeLanguage(runtime, args[1])
            ))
        }
        cls.method("withLocale", "(Ljava/util/Locale;)Ljava/time/format/DateTimeFormatter;") { runtime, args, _ in
            let source: VMDateTimeFormatterPayload? = runtime.payload(args[0], as: VMDateTimeFormatterPayload.self)
            let language = JavaTextRuntime.localeLanguage(runtime, args[1])
            let style = source?.localizedDateStyle
            return runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(
                pattern: style.map { localizedDatePattern($0, language: language) } ?? source?.pattern ?? "",
                zone: source?.zone,
                language: language,
                caseInsensitive: source?.caseInsensitive ?? false,
                localizedDateStyle: style,
                textMaps: source?.textMaps ?? [],
                defaults: source?.defaults ?? [:]
            ))
        }
        cls.method("getLocale", "()Ljava/util/Locale;") { runtime, args, _ in
            let source: VMDateTimeFormatterPayload? = runtime.payload(args[0], as: VMDateTimeFormatterPayload.self)
            return runtime.localeValue(code: source?.language ?? "en")
        }
        cls.method("withZone", "(Ljava/time/ZoneId;)Ljava/time/format/DateTimeFormatter;") { runtime, args, _ in
            let source: VMDateTimeFormatterPayload? = runtime.payload(args[0], as: VMDateTimeFormatterPayload.self)
            let zone: VMZonePayload? = runtime.payload(args[1], as: VMZonePayload.self)
            return runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(
                pattern: source?.pattern ?? "",
                zone: zone ?? utc,
                language: source?.language ?? "en",
                caseInsensitive: source?.caseInsensitive ?? false,
                localizedDateStyle: source?.localizedDateStyle,
                textMaps: source?.textMaps ?? [],
                defaults: source?.defaults ?? [:]
            ))
        }
        cls.method("getZone", "()Ljava/time/ZoneId;") { runtime, args, _ in
            let source: VMDateTimeFormatterPayload? = runtime.payload(args[0], as: VMDateTimeFormatterPayload.self)
            guard let zone = source?.zone else { return .null }
            return runtime.makeNative("Ljava/time/ZoneId;", payload: zone)
        }
        cls.method("format", "(Ljava/time/temporal/TemporalAccessor;)Ljava/lang/String;") { runtime, args, _ in
            let source: VMDateTimeFormatterPayload? = runtime.payload(args[0], as: VMDateTimeFormatterPayload.self)
            let names = VMDateNames.forLanguage(source?.language ?? "en")
            let pattern = formatterPattern(source)
            let textMaps = source?.textMaps ?? []
            let formatterZone = source.flatMap { $0.zone }
            let temporal = args[1]
            if let local: VMLocalDateTimePayload = runtime.payload(temporal, as: VMLocalDateTimePayload.self) {
                return runtime.newString(try formatLocal(local, pattern: pattern, zone: formatterZone.map { resolvedZone(local, zone: $0) }, names: names, textMaps: textMaps))
            }
            if let date: VMLocalDatePayload = runtime.payload(temporal, as: VMLocalDatePayload.self) {
                let local = VMLocalDateTimePayload(year: date.year, month: date.month, day: date.day)
                return runtime.newString(try formatLocal(local, pattern: pattern, zone: formatterZone.map { resolvedZone(local, zone: $0) }, hasTime: false, names: names, textMaps: textMaps))
            }
            if let zoned: VMZonedDateTimePayload = runtime.payload(temporal, as: VMZonedDateTimePayload.self) {
                let local = zoned.local
                let zone = formatterZone.map { resolvedZone(local, zone: $0) } ?? resolvedZone(local, zone: zoned.zone)
                return runtime.newString(try formatLocal(local, pattern: pattern, zone: zone, names: names, textMaps: textMaps))
            }
            if let offsetDateTime: VMOffsetDateTimePayload = runtime.payload(temporal, as: VMOffsetDateTimePayload.self) {
                let local = offsetDateTime.local
                let zone = formatterZone.map { resolvedZone(local, zone: $0) } ?? offsetDateTime.offset
                return runtime.newString(try formatLocal(local, pattern: pattern, zone: zone, names: names, textMaps: textMaps))
            }
            if let time: VMLocalTimePayload = runtime.payload(temporal, as: VMLocalTimePayload.self) {
                let local = VMLocalDateTimePayload(hour: time.hour, minute: time.minute, second: time.second, nano: time.nano)
                // LocalTime has no offset field in java.time.
                return runtime.newString(try formatLocal(local, pattern: pattern, hasDate: false, names: names, textMaps: textMaps))
            }
            if let instant: VMInstantPayload = runtime.payload(temporal, as: VMInstantPayload.self) {
                let date = Date(timeIntervalSince1970: Double(instant.epochMilli) / 1000)
                // java.time formats instants by projecting through the override
                // zone, falling back to the system default zone.
                let zone = formatterZone.map { adjustZone($0, at: date) } ?? systemDefaultZone(for: date)
                return runtime.newString(try formatLocal(localFromDate(date, zone: zone), pattern: pattern, zone: zone, names: names, textMaps: textMaps))
            }
            throw VMJavaException("Ljava/time/temporal/UnsupportedTemporalTypeException;", "unsupported temporal")
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let source: VMDateTimeFormatterPayload? = runtime.payload(args[0], as: VMDateTimeFormatterPayload.self)
            return runtime.newString(formatterPattern(source))
        }
        return cls
    }

    private static func localDateTimeClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/LocalDateTime;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/time/temporal/TemporalAccessor;", "Ljava/time/chrono/ChronoLocalDateTime;"])
        cls.staticMethod("parse", "(Ljava/lang/CharSequence;)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]), let parsed = parse(text, pattern: "yyyy-MM-dd'T'HH:mm:ss") else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", runtime.stringValue(args[0]))
            }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: parsed)
        }
        cls.staticMethod("parse", "(Ljava/lang/CharSequence;Ljava/time/format/DateTimeFormatter;)Ljava/time/LocalDateTime;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let formatter: VMDateTimeFormatterPayload? = runtime.payload(args[1], as: VMDateTimeFormatterPayload.self)
            guard let parsed = parse(
                text,
                pattern: formatterPattern(formatter),
                zone: formatter?.zone,
                language: formatter?.language ?? "en",
                caseInsensitive: formatter?.caseInsensitive ?? false,
                textMaps: formatter?.textMaps ?? [],
                defaults: formatter?.defaults ?? [:]
            ) else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", text)
            }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: parsed)
        }
        cls.staticMethod("now", "()Ljava/time/LocalDateTime;") { runtime, _, _ in
            runtime.makeNative("Ljava/time/LocalDateTime;", payload: localFromDate(Date(), zone: systemDefaultZone()))
        }
        cls.staticMethod("now", "(Ljava/time/ZoneId;)Ljava/time/LocalDateTime;") { runtime, args, _ in
            let zone = runtime.payload(args[0], as: VMZonePayload.self) ?? systemDefaultZone()
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: localFromDate(Date(), zone: zone))
        }
        cls.method("minusDays", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            let amount = try multiplied(args[1].asInt64, -1)
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addDays(local, amount))
        }
        cls.method("plusDays", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addDays(local, args[1].asInt64))
        }
        cls.method("minusWeeks", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addUnit(local, try multiplied(args[1].asInt64, -1), unit: "WEEKS"))
        }
        cls.method("plusWeeks", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addUnit(local, args[1].asInt64, unit: "WEEKS"))
        }
        cls.method("minusMonths", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addMonths(local, try multiplied(args[1].asInt64, -1)))
        }
        cls.method("plusMonths", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addMonths(local, args[1].asInt64))
        }
        cls.method("minusYears", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addYears(local, try multiplied(args[1].asInt64, -1)))
        }
        cls.method("plusYears", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addYears(local, args[1].asInt64))
        }
        cls.method("minusHours", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addUnit(local, try multiplied(args[1].asInt64, -1), unit: "HOURS"))
        }
        cls.method("plusHours", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addUnit(local, args[1].asInt64, unit: "HOURS"))
        }
        cls.method("minusMinutes", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addUnit(local, try multiplied(args[1].asInt64, -1), unit: "MINUTES"))
        }
        cls.method("plusMinutes", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addUnit(local, args[1].asInt64, unit: "MINUTES"))
        }
        cls.method("minusSeconds", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addUnit(local, try multiplied(args[1].asInt64, -1), unit: "SECONDS"))
        }
        cls.method("plusSeconds", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addUnit(local, args[1].asInt64, unit: "SECONDS"))
        }
        cls.method("plus", "(JLjava/time/temporal/TemporalUnit;)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            let unit = runtime.payload(args[2], as: VMChronoUnitPayload.self)?.name ?? "NANOS"
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addUnit(local, args[1].asInt64, unit: unit))
        }
        cls.method("minus", "(JLjava/time/temporal/TemporalUnit;)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            let unit = runtime.payload(args[2], as: VMChronoUnitPayload.self)?.name ?? "NANOS"
            let amount = try multiplied(args[1].asInt64, -1)
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try addUnit(local, amount, unit: unit))
        }
        cls.method("truncatedTo", "(Ljava/time/temporal/TemporalUnit;)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            let unit = runtime.payload(args[1], as: VMChronoUnitPayload.self)?.name ?? "NANOS"
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: try truncate(local, unit: unit))
        }
        cls.method("getDayOfWeek", "()Ljava/time/DayOfWeek;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            let days = JavaTextRuntime.daysFromCivil(local.year, local.month, local.day)
            let value = ((days + 3) % 7 + 7) % 7 + 1
            return runtime.makeNative("Ljava/time/DayOfWeek;", payload: VMDayOfWeekPayload(value: value))
        }
        cls.method("getDayOfYear", "()I") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .int32(0) }
            let days = JavaTextRuntime.daysFromCivil(local.year, local.month, local.day)
            return .int32(Int32(days - JavaTextRuntime.daysFromCivil(local.year, 1, 1) + 1))
        }
        cls.staticMethod("of", "(IIIIII)Ljava/time/LocalDateTime;") { runtime, args, _ in
            let year = Int(args[0].asInt32)
            let month = Int(args[1].asInt32)
            let day = Int(args[2].asInt32)
            let hour = Int(args[3].asInt32)
            let minute = Int(args[4].asInt32)
            let second = Int(args[5].asInt32)
            try requireValidDate(year: year, month: month, day: day)
            guard (0..<24).contains(hour) else {
                throw VMJavaException("Ljava/time/DateTimeException;", "Invalid value for HourOfDay (valid values 0 - 23): \(hour)")
            }
            guard (0..<60).contains(minute) else {
                throw VMJavaException("Ljava/time/DateTimeException;", "Invalid value for MinuteOfHour (valid values 0 - 59): \(minute)")
            }
            guard (0..<60).contains(second) else {
                throw VMJavaException("Ljava/time/DateTimeException;", "Invalid value for SecondOfMinute (valid values 0 - 59): \(second)")
            }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: VMLocalDateTimePayload(
                year: year, month: month, day: day,
                hour: hour, minute: minute, second: second
            ))
        }
        cls.method("atZone", "(Ljava/time/ZoneId;)Ljava/time/ZonedDateTime;") { runtime, args, _ in
            let local: VMLocalDateTimePayload? = runtime.payload(args[0], as: VMLocalDateTimePayload.self)
            let zone: VMZonePayload? = runtime.payload(args[1], as: VMZonePayload.self)
            guard let local else { return .null }
            let source = zone ?? utc
            let resolution = resolveLocal(local, zone: source)
            let resolved = VMZonePayload(id: source.id, secondsFromGMT: resolution.offsetSeconds)
            let resolvedLocal = localFromDate(Date(timeIntervalSince1970: Double(resolution.epochMilli) / 1000), zone: resolved)
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: VMZonedDateTimePayload(local: resolvedLocal, zone: resolved))
        }
        cls.method("toLocalDate", "()Ljava/time/LocalDate;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: local.year, month: local.month, day: local.day))
        }
        cls.method("toLocalTime", "()Ljava/time/LocalTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalTime;", payload: VMLocalTimePayload(hour: local.hour, minute: local.minute, second: local.second, nano: local.nano))
        }
        cls.method("getYear", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalDateTimePayload.self) ?? VMLocalDateTimePayload()).year)) }
        cls.method("getMonthValue", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalDateTimePayload.self) ?? VMLocalDateTimePayload()).month)) }
        cls.method("getDayOfMonth", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalDateTimePayload.self) ?? VMLocalDateTimePayload()).day)) }
        cls.method("getHour", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalDateTimePayload.self) ?? VMLocalDateTimePayload()).hour)) }
        cls.method("getMinute", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalDateTimePayload.self) ?? VMLocalDateTimePayload()).minute)) }
        cls.method("getSecond", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalDateTimePayload.self) ?? VMLocalDateTimePayload()).second)) }
        cls.method("format", "(Ljava/time/format/DateTimeFormatter;)Ljava/lang/String;") { runtime, args, _ in
            let local: VMLocalDateTimePayload? = runtime.payload(args[0], as: VMLocalDateTimePayload.self)
            let formatter: VMDateTimeFormatterPayload? = runtime.payload(args[1], as: VMDateTimeFormatterPayload.self)
            guard let local else { return .null }
            let overrideZone = formatter.flatMap { $0.zone }
            return runtime.newString(try formatLocal(
                local,
                pattern: formatterPattern(formatter),
                zone: overrideZone.map { resolvedZone(local, zone: $0) },
                textMaps: formatter?.textMaps ?? []
            ))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.newString(try formatLocal(local, pattern: "yyyy-MM-dd'T'HH:mm:ss"))
        }
        return cls
    }

    private static func localDateClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/LocalDate;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/time/temporal/TemporalAccessor;", "Ljava/time/chrono/ChronoLocalDate;"])
        cls.staticMethod("parse", "(Ljava/lang/CharSequence;)Ljava/time/LocalDate;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let parsed = parse(text, pattern: "yyyy-MM-dd") else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", text)
            }
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: parsed.year, month: parsed.month, day: parsed.day))
        }
        cls.staticMethod("parse", "(Ljava/lang/CharSequence;Ljava/time/format/DateTimeFormatter;)Ljava/time/LocalDate;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let formatter: VMDateTimeFormatterPayload? = runtime.payload(args[1], as: VMDateTimeFormatterPayload.self)
            guard let parsed = parse(
                text,
                pattern: formatterPattern(formatter),
                language: formatter?.language ?? "en",
                caseInsensitive: formatter?.caseInsensitive ?? false,
                textMaps: formatter?.textMaps ?? [],
                defaults: formatter?.defaults ?? [:]
            ) else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", text)
            }
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: parsed.year, month: parsed.month, day: parsed.day))
        }
        cls.staticMethod("of", "(III)Ljava/time/LocalDate;") { runtime, args, _ in
            let year = Int(args[0].asInt32)
            let month = Int(args[1].asInt32)
            let day = Int(args[2].asInt32)
            try requireValidDate(year: year, month: month, day: day)
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: year, month: month, day: day))
        }
        cls.staticMethod("ofEpochDay", "(J)Ljava/time/LocalDate;") { runtime, args, _ in
            let epochDay = args[0].asInt64
            guard epochDay >= Int64(JavaTextRuntime.daysFromCivil(minYear, 1, 1)),
                  epochDay <= Int64(JavaTextRuntime.daysFromCivil(maxYear, 12, 31)) else {
                throw VMJavaException("Ljava/time/DateTimeException;", "Invalid value for EpochDay: \(epochDay)")
            }
            let civil = JavaTextRuntime.civilFromDays(Int(epochDay))
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: civil.year, month: civil.month, day: civil.day))
        }
        cls.staticMethod("now", "()Ljava/time/LocalDate;") { runtime, _, _ in
            let local = localFromDate(Date(), zone: systemDefaultZone())
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: local.year, month: local.month, day: local.day))
        }
        cls.staticMethod("now", "(Ljava/time/ZoneId;)Ljava/time/LocalDate;") { runtime, args, _ in
            let zone = runtime.payload(args[0], as: VMZonePayload.self) ?? systemDefaultZone()
            let local = localFromDate(Date(), zone: zone)
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: local.year, month: local.month, day: local.day))
        }
        cls.method("atStartOfDay", "()Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: VMLocalDateTimePayload(year: date.year, month: date.month, day: date.day))
        }
        cls.method("atStartOfDay", "(Ljava/time/ZoneId;)Ljava/time/ZonedDateTime;") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
            let zone = runtime.payload(args[1], as: VMZonePayload.self) ?? utc
            let local = VMLocalDateTimePayload(year: date.year, month: date.month, day: date.day)
            let resolution = resolveLocal(local, zone: zone)
            let resolved = VMZonePayload(id: zone.id, secondsFromGMT: resolution.offsetSeconds)
            let resolvedLocal = localFromDate(Date(timeIntervalSince1970: Double(resolution.epochMilli) / 1000), zone: resolved)
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: VMZonedDateTimePayload(local: resolvedLocal, zone: resolved))
        }
        cls.method("atTime", "(Ljava/time/LocalTime;)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self),
                  let time: VMLocalTimePayload = runtime.payload(args[1], as: VMLocalTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: VMLocalDateTimePayload(
                year: date.year, month: date.month, day: date.day,
                hour: time.hour, minute: time.minute, second: time.second, nano: time.nano
            ))
        }
        cls.method("atTime", "(II)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: VMLocalDateTimePayload(
                year: date.year, month: date.month, day: date.day,
                hour: Int(args[1].asInt32), minute: Int(args[2].asInt32)
            ))
        }
        cls.method("atTime", "(III)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: VMLocalDateTimePayload(
                year: date.year, month: date.month, day: date.day,
                hour: Int(args[1].asInt32), minute: Int(args[2].asInt32), second: Int(args[3].asInt32)
            ))
        }
        cls.method("getYear", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalDatePayload.self) ?? VMLocalDatePayload()).year)) }
        cls.method("getMonthValue", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalDatePayload.self) ?? VMLocalDatePayload()).month)) }
        cls.method("getDayOfMonth", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalDatePayload.self) ?? VMLocalDatePayload()).day)) }
        cls.method("getDayOfYear", "()I") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .int32(0) }
            let days = JavaTextRuntime.daysFromCivil(date.year, date.month, date.day)
            return .int32(Int32(days - JavaTextRuntime.daysFromCivil(date.year, 1, 1) + 1))
        }
        cls.method("getDayOfWeek", "()Ljava/time/DayOfWeek;") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
            let days = JavaTextRuntime.daysFromCivil(date.year, date.month, date.day)
            let value = ((days + 3) % 7 + 7) % 7 + 1
            return runtime.makeNative("Ljava/time/DayOfWeek;", payload: VMDayOfWeekPayload(value: value))
        }
        cls.method("get", "(Ljava/time/temporal/TemporalField;)I") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self),
                  let field = runtime.payload(args[1], as: VMChronoFieldPayload.self) else {
                return .int32(0)
            }
            let days = JavaTextRuntime.daysFromCivil(date.year, date.month, date.day)
            let isoDayOfWeek = ((days + 3) % 7 + 7) % 7 + 1
            switch field.name {
            case "DAY_OF_MONTH": return .int32(Int32(date.day))
            case "MONTH_OF_YEAR": return .int32(Int32(date.month))
            case "YEAR": return .int32(Int32(date.year))
            case "YEAR_OF_ERA":
                return .int32(Int32(date.year <= 0 ? 1 - date.year : date.year))
            case "ERA": return .int32(date.year <= 0 ? 0 : 1)
            case "DAY_OF_YEAR": return .int32(Int32(days - JavaTextRuntime.daysFromCivil(date.year, 1, 1) + 1))
            case "DAY_OF_WEEK":
                // A WeekFields field localizes the first day of the week.
                if let start = field.weekStart {
                    return .int32(Int32((isoDayOfWeek - start + 7) % 7 + 1))
                }
                return .int32(Int32(isoDayOfWeek))
            case "EPOCH_DAY": return .int64(Int64(days))
            case "ALIGNED_DAY_OF_WEEK_IN_MONTH":
                return .int32(Int32((date.day - 1) % 7 + 1))
            default:
                throw VMJavaException(
                    "Ljava/time/temporal/UnsupportedTemporalTypeException;",
                    "Unsupported field: \(field.name)"
                )
            }
        }
        cls.method("isAfter", "(Ljava/time/chrono/ChronoLocalDate;)Z") { runtime, args, _ in
            guard let mine: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self),
                  let other: VMLocalDatePayload = runtime.payload(args[1], as: VMLocalDatePayload.self) else { return .boolean(false) }
            return .boolean(JavaTextRuntime.daysFromCivil(mine.year, mine.month, mine.day) > JavaTextRuntime.daysFromCivil(other.year, other.month, other.day))
        }
        cls.method("isBefore", "(Ljava/time/chrono/ChronoLocalDate;)Z") { runtime, args, _ in
            guard let mine: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self),
                  let other: VMLocalDatePayload = runtime.payload(args[1], as: VMLocalDatePayload.self) else { return .boolean(false) }
            return .boolean(JavaTextRuntime.daysFromCivil(mine.year, mine.month, mine.day) < JavaTextRuntime.daysFromCivil(other.year, other.month, other.day))
        }
        cls.method("isEqual", "(Ljava/time/chrono/ChronoLocalDate;)Z") { runtime, args, _ in
            guard let mine: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self),
                  let other: VMLocalDatePayload = runtime.payload(args[1], as: VMLocalDatePayload.self) else { return .boolean(false) }
            return .boolean(JavaTextRuntime.daysFromCivil(mine.year, mine.month, mine.day) == JavaTextRuntime.daysFromCivil(other.year, other.month, other.day))
        }
        for (name, sign) in [("minusDays", Int64(-1)), ("plusDays", Int64(1))] {
            cls.method(name, "(J)Ljava/time/LocalDate;") { runtime, args, _ in
                guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
                let amount = try multiplied(args[1].asInt64, sign)
                let base = VMLocalDateTimePayload(year: date.year, month: date.month, day: date.day)
                let shifted = try addDays(base, amount)
                return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: shifted.year, month: shifted.month, day: shifted.day))
            }
        }
        for (name, sign) in [("minusWeeks", Int64(-1)), ("plusWeeks", Int64(1))] {
            cls.method(name, "(J)Ljava/time/LocalDate;") { runtime, args, _ in
                guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
                let weeks = try multiplied(args[1].asInt64, sign)
                let (days, overflow) = weeks.multipliedReportingOverflow(by: 7)
                guard !overflow else { throw arithmeticOverflow("long overflow") }
                let base = VMLocalDateTimePayload(year: date.year, month: date.month, day: date.day)
                let shifted = try addDays(base, days)
                return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: shifted.year, month: shifted.month, day: shifted.day))
            }
        }
        for (name, sign) in [("minusMonths", Int64(-1)), ("plusMonths", Int64(1))] {
            cls.method(name, "(J)Ljava/time/LocalDate;") { runtime, args, _ in
                guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
                let amount = try multiplied(args[1].asInt64, sign)
                let base = VMLocalDateTimePayload(year: date.year, month: date.month, day: date.day)
                let shifted = try addMonths(base, amount)
                return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: shifted.year, month: shifted.month, day: shifted.day))
            }
        }
        for (name, sign) in [("minusYears", Int64(-1)), ("plusYears", Int64(1))] {
            cls.method(name, "(J)Ljava/time/LocalDate;") { runtime, args, _ in
                guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
                let amount = try multiplied(args[1].asInt64, sign)
                let base = VMLocalDateTimePayload(year: date.year, month: date.month, day: date.day)
                let shifted = try addYears(base, amount)
                return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: shifted.year, month: shifted.month, day: shifted.day))
            }
        }
        cls.method("toEpochDay", "()J") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .int64(0) }
            return .int64(Int64(JavaTextRuntime.daysFromCivil(date.year, date.month, date.day)))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
            return runtime.newString(String(format: "%04d-%02d-%02d", date.year, date.month, date.day))
        }
        cls.method("format", "(Ljava/time/format/DateTimeFormatter;)Ljava/lang/String;") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
            let formatter: VMDateTimeFormatterPayload? = runtime.payload(args[1], as: VMDateTimeFormatterPayload.self)
            let local = VMLocalDateTimePayload(year: date.year, month: date.month, day: date.day)
            let overrideZone = formatter.flatMap { $0.zone }
            return runtime.newString(try formatLocal(
                local,
                pattern: formatterPattern(formatter),
                zone: overrideZone.map { resolvedZone(local, zone: $0) },
                hasTime: false,
                textMaps: formatter?.textMaps ?? []
            ))
        }
        return cls
    }

    private static func localTimeClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/LocalTime;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/time/temporal/TemporalAccessor;"])
        cls.staticMethod("now", "()Ljava/time/LocalTime;") { runtime, _, _ in
            let local = localFromDate(Date(), zone: systemDefaultZone())
            return runtime.makeNative("Ljava/time/LocalTime;", payload: VMLocalTimePayload(hour: local.hour, minute: local.minute, second: local.second, nano: local.nano))
        }
        cls.staticMethod("now", "(Ljava/time/ZoneId;)Ljava/time/LocalTime;") { runtime, args, _ in
            let zone = runtime.payload(args[0], as: VMZonePayload.self) ?? systemDefaultZone()
            let local = localFromDate(Date(), zone: zone)
            return runtime.makeNative("Ljava/time/LocalTime;", payload: VMLocalTimePayload(hour: local.hour, minute: local.minute, second: local.second, nano: local.nano))
        }
        cls.staticMethod("parse", "(Ljava/lang/CharSequence;)Ljava/time/LocalTime;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let parsed = parse(text, pattern: "HH:mm:ss", defaults: ["HOUR_OF_DAY": 0]) else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", text)
            }
            return runtime.makeNative("Ljava/time/LocalTime;", payload: VMLocalTimePayload(hour: parsed.hour, minute: parsed.minute, second: parsed.second, nano: parsed.nano))
        }
        cls.staticMethod("parse", "(Ljava/lang/CharSequence;Ljava/time/format/DateTimeFormatter;)Ljava/time/LocalTime;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let formatter: VMDateTimeFormatterPayload? = runtime.payload(args[1], as: VMDateTimeFormatterPayload.self)
            guard let parsed = parse(
                text,
                pattern: formatterPattern(formatter),
                language: formatter?.language ?? "en",
                caseInsensitive: formatter?.caseInsensitive ?? false,
                textMaps: formatter?.textMaps ?? [],
                defaults: formatter?.defaults ?? [:]
            ) else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", text)
            }
            return runtime.makeNative("Ljava/time/LocalTime;", payload: VMLocalTimePayload(hour: parsed.hour, minute: parsed.minute, second: parsed.second, nano: parsed.nano))
        }
        cls.staticMethod("of", "(II)Ljava/time/LocalTime;") { runtime, args, _ in
            runtime.makeNative("Ljava/time/LocalTime;", payload: VMLocalTimePayload(hour: Int(args[0].asInt32), minute: Int(args[1].asInt32)))
        }
        cls.staticMethod("of", "(III)Ljava/time/LocalTime;") { runtime, args, _ in
            runtime.makeNative("Ljava/time/LocalTime;", payload: VMLocalTimePayload(hour: Int(args[0].asInt32), minute: Int(args[1].asInt32), second: Int(args[2].asInt32)))
        }
        cls.staticMethod("of", "(IIII)Ljava/time/LocalTime;") { runtime, args, _ in
            runtime.makeNative("Ljava/time/LocalTime;", payload: VMLocalTimePayload(
                hour: Int(args[0].asInt32), minute: Int(args[1].asInt32),
                second: Int(args[2].asInt32), nano: Int(args[3].asInt32)
            ))
        }
        cls.method("getHour", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalTimePayload.self) ?? VMLocalTimePayload()).hour)) }
        cls.method("getMinute", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalTimePayload.self) ?? VMLocalTimePayload()).minute)) }
        cls.method("getSecond", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalTimePayload.self) ?? VMLocalTimePayload()).second)) }
        cls.method("getNano", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalTimePayload.self) ?? VMLocalTimePayload()).nano)) }
        cls.method("atDate", "(Ljava/time/LocalDate;)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let time: VMLocalTimePayload = runtime.payload(args[0], as: VMLocalTimePayload.self),
                  let date: VMLocalDatePayload = runtime.payload(args[1], as: VMLocalDatePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: VMLocalDateTimePayload(
                year: date.year, month: date.month, day: date.day,
                hour: time.hour, minute: time.minute, second: time.second, nano: time.nano
            ))
        }
        cls.method("format", "(Ljava/time/format/DateTimeFormatter;)Ljava/lang/String;") { runtime, args, _ in
            guard let time: VMLocalTimePayload = runtime.payload(args[0], as: VMLocalTimePayload.self) else { return .null }
            let formatter: VMDateTimeFormatterPayload? = runtime.payload(args[1], as: VMDateTimeFormatterPayload.self)
            let local = VMLocalDateTimePayload(hour: time.hour, minute: time.minute, second: time.second, nano: time.nano)
            return runtime.newString(try formatLocal(
                local,
                pattern: formatterPattern(formatter),
                hasDate: false,
                textMaps: formatter?.textMaps ?? []
            ))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let time: VMLocalTimePayload = runtime.payload(args[0], as: VMLocalTimePayload.self) else { return .null }
            let local = VMLocalDateTimePayload(hour: time.hour, minute: time.minute, second: time.second, nano: time.nano)
            return runtime.newString(try formatLocal(local, pattern: "HH:mm:ss", hasDate: false))
        }
        return cls
    }

    private static func zonedDateTimeClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/ZonedDateTime;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/time/chrono/ChronoZonedDateTime;", "Ljava/time/temporal/TemporalAccessor;"])
        cls.staticMethod("now", "()Ljava/time/ZonedDateTime;") { runtime, _, _ in
            let zone = systemDefaultZone()
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: VMZonedDateTimePayload(local: localFromDate(Date(), zone: zone), zone: zone))
        }
        cls.staticMethod("now", "(Ljava/time/ZoneId;)Ljava/time/ZonedDateTime;") { runtime, args, _ in
            let zone = runtime.payload(args[0], as: VMZonePayload.self) ?? systemDefaultZone()
            let resolved = adjustZone(zone, at: Date())
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: VMZonedDateTimePayload(local: localFromDate(Date(), zone: resolved), zone: resolved))
        }
        cls.staticMethod("of", "(Ljava/time/LocalDateTime;Ljava/time/ZoneId;)Ljava/time/ZonedDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            let zone = runtime.payload(args[1], as: VMZonePayload.self) ?? utc
            let resolved = resolvedLocal(local, zone: zone)
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: VMZonedDateTimePayload(local: resolved.local, zone: resolved.zone))
        }
        cls.staticMethod("of", "(IIIIIIILjava/time/ZoneId;)Ljava/time/ZonedDateTime;") { runtime, args, _ in
            let local = VMLocalDateTimePayload(
                year: Int(args[0].asInt32), month: Int(args[1].asInt32), day: Int(args[2].asInt32),
                hour: Int(args[3].asInt32), minute: Int(args[4].asInt32), second: Int(args[5].asInt32),
                nano: Int(args[6].asInt32)
            )
            try requireValidDate(year: local.year, month: local.month, day: local.day)
            let zone = runtime.payload(args[7], as: VMZonePayload.self) ?? utc
            let resolved = resolvedLocal(local, zone: zone)
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: VMZonedDateTimePayload(local: resolved.local, zone: resolved.zone))
        }
        cls.staticMethod("parse", "(Ljava/lang/CharSequence;Ljava/time/format/DateTimeFormatter;)Ljava/time/ZonedDateTime;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let formatter: VMDateTimeFormatterPayload? = runtime.payload(args[1], as: VMDateTimeFormatterPayload.self)
            guard let parsed = parseDetailed(
                text,
                pattern: formatterPattern(formatter),
                language: formatter?.language ?? "en",
                caseInsensitive: formatter?.caseInsensitive ?? false,
                textMaps: formatter?.textMaps ?? [],
                defaults: formatter?.defaults ?? [:]
            ) else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", text)
            }
            let zone: VMZonePayload
            if let formatterZone = formatter?.zone {
                zone = formatterZone
            } else if let offsetSeconds = parsed.offsetSeconds {
                zone = VMZonePayload(id: offsetId(offsetSeconds), secondsFromGMT: offsetSeconds)
            } else if let zoneText = parsed.zoneText {
                zone = parseZoneId(zoneText)
            } else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", "Unable to obtain ZoneId from TemporalAccessor: \(text)")
            }
            let resolved = resolvedLocal(parsed.local, zone: zone)
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: VMZonedDateTimePayload(local: resolved.local, zone: resolved.zone))
        }
        cls.method("toInstant", "()Ljava/time/Instant;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/Instant;", payload: VMInstantPayload(epochMilli: epochMilli(zoned.local, zone: zoned.zone)))
        }
        cls.method("toLocalDateTime", "()Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: zoned.local.copy())
        }
        cls.method("toLocalDate", "()Ljava/time/LocalDate;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: zoned.local.year, month: zoned.local.month, day: zoned.local.day))
        }
        cls.method("toLocalTime", "()Ljava/time/LocalTime;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            let local = zoned.local
            return runtime.makeNative("Ljava/time/LocalTime;", payload: VMLocalTimePayload(hour: local.hour, minute: local.minute, second: local.second, nano: local.nano))
        }
        cls.method("getZone", "()Ljava/time/ZoneId;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/ZoneId;", payload: zoned.zone)
        }
        cls.method("getOffset", "()Ljava/time/ZoneOffset;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/ZoneOffset;", payload: resolvedZone(zoned.local, zone: zoned.zone))
        }
        cls.method("getDayOfWeek", "()Ljava/time/DayOfWeek;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            let days = JavaTextRuntime.daysFromCivil(zoned.local.year, zoned.local.month, zoned.local.day)
            let value = ((days + 3) % 7 + 7) % 7 + 1
            return runtime.makeNative("Ljava/time/DayOfWeek;", payload: VMDayOfWeekPayload(value: value))
        }
        for (name, get) in [
            ("getYear", { (l: VMLocalDateTimePayload) in l.year }),
            ("getMonthValue", { (l: VMLocalDateTimePayload) in l.month }),
            ("getDayOfMonth", { (l: VMLocalDateTimePayload) in l.day }),
            ("getDayOfYear", { (l: VMLocalDateTimePayload) in l.day }),
            ("getHour", { (l: VMLocalDateTimePayload) in l.hour }),
            ("getMinute", { (l: VMLocalDateTimePayload) in l.minute }),
            ("getSecond", { (l: VMLocalDateTimePayload) in l.second }),
            ("getNano", { (l: VMLocalDateTimePayload) in l.nano }),
        ] {
            cls.method(name, "()I") { runtime, args, _ in
                guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .int32(0) }
                if name == "getDayOfYear" {
                    let days = JavaTextRuntime.daysFromCivil(zoned.local.year, zoned.local.month, zoned.local.day)
                    return .int32(Int32(days - JavaTextRuntime.daysFromCivil(zoned.local.year, 1, 1) + 1))
                }
                return .int32(Int32(get(zoned.local)))
            }
        }
        for (name, sign) in [
            ("minusDays", Int64(-1)), ("plusDays", Int64(1)),
            ("minusWeeks", Int64(-1)), ("plusWeeks", Int64(1)),
            ("minusMonths", Int64(-1)), ("plusMonths", Int64(1)),
            ("minusYears", Int64(-1)), ("plusYears", Int64(1)),
            ("minusHours", Int64(-1)), ("plusHours", Int64(1)),
            ("minusMinutes", Int64(-1)), ("plusMinutes", Int64(1)),
            ("minusSeconds", Int64(-1)), ("plusSeconds", Int64(1)),
        ] {
            let unit: String
            switch name {
            case "minusDays", "plusDays": unit = "DAYS"
            case "minusWeeks", "plusWeeks": unit = "WEEKS"
            case "minusMonths", "plusMonths": unit = "MONTHS"
            case "minusYears", "plusYears": unit = "YEARS"
            case "minusHours", "plusHours": unit = "HOURS"
            case "minusMinutes", "plusMinutes": unit = "MINUTES"
            default: unit = "SECONDS"
            }
            cls.method(name, "(J)Ljava/time/ZonedDateTime;") { runtime, args, _ in
                guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
                let amount = try multiplied(args[1].asInt64, sign)
                return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: try shiftedZoned(zoned, amount: amount, unit: unit))
            }
        }
        cls.method("plus", "(JLjava/time/temporal/TemporalUnit;)Ljava/time/ZonedDateTime;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            let unit = runtime.payload(args[2], as: VMChronoUnitPayload.self)?.name ?? "NANOS"
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: try shiftedZoned(zoned, amount: args[1].asInt64, unit: unit))
        }
        cls.method("minus", "(JLjava/time/temporal/TemporalUnit;)Ljava/time/ZonedDateTime;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            let unit = runtime.payload(args[2], as: VMChronoUnitPayload.self)?.name ?? "NANOS"
            let amount = try multiplied(args[1].asInt64, -1)
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: try shiftedZoned(zoned, amount: amount, unit: unit))
        }
        cls.method("truncatedTo", "(Ljava/time/temporal/TemporalUnit;)Ljava/time/ZonedDateTime;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            let unit = runtime.payload(args[1], as: VMChronoUnitPayload.self)?.name ?? "NANOS"
            let truncated = try truncate(zoned.local, unit: unit)
            let resolved = resolvedLocal(truncated, zone: zoned.zone)
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: VMZonedDateTimePayload(local: resolved.local, zone: resolved.zone))
        }
        cls.method("withZoneSameInstant", "(Ljava/time/ZoneId;)Ljava/time/ZonedDateTime;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            let zone = runtime.payload(args[1], as: VMZonePayload.self) ?? utc
            let millis = epochMilli(zoned.local, zone: zoned.zone)
            let resolved = adjustZone(zone, at: Date(timeIntervalSince1970: Double(millis) / 1000))
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: VMZonedDateTimePayload(
                local: localFromDate(Date(timeIntervalSince1970: Double(millis) / 1000), zone: resolved),
                zone: resolved
            ))
        }
        cls.method("format", "(Ljava/time/format/DateTimeFormatter;)Ljava/lang/String;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            let formatter: VMDateTimeFormatterPayload? = runtime.payload(args[1], as: VMDateTimeFormatterPayload.self)
            let overrideZone = formatter.flatMap { $0.zone }
            let zone = overrideZone.map { resolvedZone(zoned.local, zone: $0) } ?? resolvedZone(zoned.local, zone: zoned.zone)
            return runtime.newString(try formatLocal(
                zoned.local,
                pattern: formatterPattern(formatter),
                zone: zone,
                textMaps: formatter?.textMaps ?? []
            ))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            let zone = resolvedZone(zoned.local, zone: zoned.zone)
            let body = try formatLocal(zoned.local, pattern: "yyyy-MM-dd'T'HH:mm:ss", zone: zone)
            return runtime.newString(body + zoneSuffix(zone))
        }
        return cls
    }

    private static func chronoZonedDateTimeClass() -> NativeClass {
        let cls = marker("Ljava/time/chrono/ChronoZonedDateTime;", interfaces: ["Ljava/time/temporal/Temporal;"])
        cls.method("toEpochSecond", "()J") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .int64(0) }
            return .int64(JavaTextRuntime.floorDivide(epochMilli(zoned.local, zone: zoned.zone), 1000))
        }
        return cls
    }

    private static func chronoLocalDateTimeClass() -> NativeClass {
        let cls = marker("Ljava/time/chrono/ChronoLocalDateTime;")
        cls.method("toInstant", "(Ljava/time/ZoneOffset;)Ljava/time/Instant;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            let offset = runtime.payload(args[1], as: VMZonePayload.self) ?? utc
            return runtime.makeNative("Ljava/time/Instant;", payload: VMInstantPayload(epochMilli: epochMilli(local, zone: offset)))
        }
        return cls
    }

    private static func offsetDateTimeClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/OffsetDateTime;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/time/temporal/TemporalAccessor;", "Ljava/time/temporal/Temporal;"])
        cls.staticMethod("now", "()Ljava/time/OffsetDateTime;") { runtime, _, _ in
            let zone = systemDefaultZone()
            return runtime.makeNative("Ljava/time/OffsetDateTime;", payload: VMOffsetDateTimePayload(local: localFromDate(Date(), zone: zone), offset: zone))
        }
        cls.staticMethod("now", "(Ljava/time/ZoneId;)Ljava/time/OffsetDateTime;") { runtime, args, _ in
            let zone = adjustZone(runtime.payload(args[0], as: VMZonePayload.self) ?? systemDefaultZone(), at: Date())
            return runtime.makeNative("Ljava/time/OffsetDateTime;", payload: VMOffsetDateTimePayload(local: localFromDate(Date(), zone: zone), offset: zone))
        }
        cls.staticMethod("parse", "(Ljava/lang/CharSequence;)Ljava/time/OffsetDateTime;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let parsed = parseDetailed(text, pattern: "yyyy-MM-dd'T'HH:mm:ss[.SSSSSSSSS]XXX") else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", text)
            }
            guard let offsetSeconds = parsed.offsetSeconds else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", "Unable to obtain ZoneOffset from TemporalAccessor: \(text)")
            }
            return runtime.makeNative("Ljava/time/OffsetDateTime;", payload: VMOffsetDateTimePayload(
                local: parsed.local,
                offset: VMZonePayload(id: offsetId(offsetSeconds), secondsFromGMT: offsetSeconds)
            ))
        }
        cls.staticMethod("of", "(Ljava/time/LocalDateTime;Ljava/time/ZoneOffset;)Ljava/time/OffsetDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self),
                  let offset: VMZonePayload = runtime.payload(args[1], as: VMZonePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/OffsetDateTime;", payload: VMOffsetDateTimePayload(local: local.copy(), offset: offset))
        }
        cls.staticMethod("of", "(IIIIIIILjava/time/ZoneOffset;)Ljava/time/OffsetDateTime;") { runtime, args, _ in
            let local = VMLocalDateTimePayload(
                year: Int(args[0].asInt32), month: Int(args[1].asInt32), day: Int(args[2].asInt32),
                hour: Int(args[3].asInt32), minute: Int(args[4].asInt32),
                second: Int(args[5].asInt32), nano: Int(args[6].asInt32)
            )
            try requireValidDate(year: local.year, month: local.month, day: local.day)
            let offset = runtime.payload(args[7], as: VMZonePayload.self) ?? utc
            return runtime.makeNative("Ljava/time/OffsetDateTime;", payload: VMOffsetDateTimePayload(local: local, offset: offset))
        }
        cls.method("toLocalDateTime", "()Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let value: VMOffsetDateTimePayload = runtime.payload(args[0], as: VMOffsetDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: value.local.copy())
        }
        cls.method("toLocalDate", "()Ljava/time/LocalDate;") { runtime, args, _ in
            guard let value: VMOffsetDateTimePayload = runtime.payload(args[0], as: VMOffsetDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: value.local.year, month: value.local.month, day: value.local.day))
        }
        cls.method("toLocalTime", "()Ljava/time/LocalTime;") { runtime, args, _ in
            guard let value: VMOffsetDateTimePayload = runtime.payload(args[0], as: VMOffsetDateTimePayload.self) else { return .null }
            let local = value.local
            return runtime.makeNative("Ljava/time/LocalTime;", payload: VMLocalTimePayload(hour: local.hour, minute: local.minute, second: local.second, nano: local.nano))
        }
        cls.method("toInstant", "()Ljava/time/Instant;") { runtime, args, _ in
            guard let value: VMOffsetDateTimePayload = runtime.payload(args[0], as: VMOffsetDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/Instant;", payload: VMInstantPayload(epochMilli: epochMilli(value.local, zone: value.offset)))
        }
        cls.method("toEpochSecond", "()J") { runtime, args, _ in
            guard let value: VMOffsetDateTimePayload = runtime.payload(args[0], as: VMOffsetDateTimePayload.self) else { return .int64(0) }
            return .int64(JavaTextRuntime.floorDivide(epochMilli(value.local, zone: value.offset), 1000))
        }
        cls.method("getOffset", "()Ljava/time/ZoneOffset;") { runtime, args, _ in
            guard let value: VMOffsetDateTimePayload = runtime.payload(args[0], as: VMOffsetDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/ZoneOffset;", payload: value.offset)
        }
        for (name, sign, unit) in [
            ("minusHours", Int64(-1), "HOURS"), ("plusHours", Int64(1), "HOURS"),
            ("minusMinutes", Int64(-1), "MINUTES"), ("plusMinutes", Int64(1), "MINUTES"),
            ("minusSeconds", Int64(-1), "SECONDS"), ("plusSeconds", Int64(1), "SECONDS"),
            ("minusDays", Int64(-1), "DAYS"), ("plusDays", Int64(1), "DAYS"),
            ("minusWeeks", Int64(-1), "WEEKS"), ("plusWeeks", Int64(1), "WEEKS"),
            ("minusMonths", Int64(-1), "MONTHS"), ("plusMonths", Int64(1), "MONTHS"),
            ("minusYears", Int64(-1), "YEARS"), ("plusYears", Int64(1), "YEARS"),
        ] {
            cls.method(name, "(J)Ljava/time/OffsetDateTime;") { runtime, args, _ in
                guard let value: VMOffsetDateTimePayload = runtime.payload(args[0], as: VMOffsetDateTimePayload.self) else { return .null }
                let amount = try multiplied(args[1].asInt64, sign)
                let shifted = try addUnit(value.local, amount, unit: unit)
                return runtime.makeNative("Ljava/time/OffsetDateTime;", payload: VMOffsetDateTimePayload(local: shifted, offset: value.offset))
            }
        }
        for (name, get) in [
            ("getYear", { (l: VMLocalDateTimePayload) in l.year }),
            ("getMonthValue", { (l: VMLocalDateTimePayload) in l.month }),
            ("getDayOfMonth", { (l: VMLocalDateTimePayload) in l.day }),
            ("getHour", { (l: VMLocalDateTimePayload) in l.hour }),
            ("getMinute", { (l: VMLocalDateTimePayload) in l.minute }),
            ("getSecond", { (l: VMLocalDateTimePayload) in l.second }),
            ("getNano", { (l: VMLocalDateTimePayload) in l.nano }),
        ] {
            cls.method(name, "()I") { runtime, args, _ in
                guard let value: VMOffsetDateTimePayload = runtime.payload(args[0], as: VMOffsetDateTimePayload.self) else { return .int32(0) }
                return .int32(Int32(get(value.local)))
            }
        }
        cls.method("format", "(Ljava/time/format/DateTimeFormatter;)Ljava/lang/String;") { runtime, args, _ in
            guard let value: VMOffsetDateTimePayload = runtime.payload(args[0], as: VMOffsetDateTimePayload.self) else { return .null }
            let formatter: VMDateTimeFormatterPayload? = runtime.payload(args[1], as: VMDateTimeFormatterPayload.self)
            let overrideZone = formatter.flatMap { $0.zone }
            return runtime.newString(try formatLocal(
                value.local,
                pattern: formatterPattern(formatter),
                zone: overrideZone.map { resolvedZone(value.local, zone: $0) } ?? value.offset,
                textMaps: formatter?.textMaps ?? []
            ))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let value: VMOffsetDateTimePayload = runtime.payload(args[0], as: VMOffsetDateTimePayload.self) else { return .null }
            let body = try formatLocal(value.local, pattern: "yyyy-MM-dd'T'HH:mm:ss", zone: value.offset)
            return runtime.newString(body + zoneSuffix(value.offset))
        }
        return cls
    }

    private static func instantClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/Instant;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/time/temporal/TemporalAccessor;"])
        cls.staticMethod("now", "()Ljava/time/Instant;") { runtime, _, _ in
            runtime.makeNative("Ljava/time/Instant;", payload: VMInstantPayload(epochMilli: Int64(Date().timeIntervalSince1970 * 1000)))
        }
        cls.staticMethod("ofEpochMilli", "(J)Ljava/time/Instant;") { runtime, args, _ in
            runtime.makeNative("Ljava/time/Instant;", payload: VMInstantPayload(epochMilli: args[0].asInt64))
        }
        cls.staticMethod("ofEpochSecond", "(J)Ljava/time/Instant;") { runtime, args, _ in
            let (millis, overflow) = args[0].asInt64.multipliedReportingOverflow(by: 1000)
            guard !overflow else { throw arithmeticOverflow("long overflow") }
            return runtime.makeNative("Ljava/time/Instant;", payload: VMInstantPayload(epochMilli: millis))
        }
        cls.staticMethod("ofEpochSecond", "(JJ)Ljava/time/Instant;") { runtime, args, _ in
            let (millis, overflow) = args[0].asInt64.multipliedReportingOverflow(by: 1000)
            guard !overflow else { throw arithmeticOverflow("long overflow") }
            let adjustment = args[1].asInt64
            guard adjustment >= 0, adjustment <= 999_999_999 else {
                throw VMJavaException("Ljava/time/DateTimeException;", "Invalid value for NanoOfSecond (valid values 0 - 999999999): \(adjustment)")
            }
            let micros = adjustment / 1_000_000
            let rest = adjustment % 1_000_000
            var (adjusted, addOverflow) = millis.addingReportingOverflow(micros)
            guard !addOverflow else { throw arithmeticOverflow("long overflow") }
            var nano = Int32(rest)
            if nano < 0 {
                (adjusted, addOverflow) = adjusted.addingReportingOverflow(-1)
                guard !addOverflow else { throw arithmeticOverflow("long overflow") }
                nano += 1_000_000
            }
            return runtime.makeNative("Ljava/time/Instant;", payload: VMInstantPayload(epochMilli: adjusted, nano: nano))
        }
        cls.staticMethod("parse", "(Ljava/lang/CharSequence;)Ljava/time/Instant;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let parsed = parseInstant(text) else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", text)
            }
            return runtime.makeNative("Ljava/time/Instant;", payload: parsed)
        }
        cls.method("toEpochMilli", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: VMInstantPayload.self)?.epochMilli ?? 0)
        }
        cls.method("getEpochSecond", "()J") { runtime, args, _ in
            let millis = runtime.payload(args[0], as: VMInstantPayload.self)?.epochMilli ?? 0
            return .int64(JavaTextRuntime.floorDivide(millis, 1000))
        }
        cls.method("getNano", "()I") { runtime, args, _ in
            let instant = runtime.payload(args[0], as: VMInstantPayload.self)
            let millis = instant?.epochMilli ?? 0
            let milliOfSecond = Int32((millis % 1000 + 1000) % 1000)
            return .int32((instant?.nano ?? 0) + milliOfSecond * 1_000_000)
        }
        for (name, sign) in [("minus", Int64(-1)), ("plus", Int64(1))] {
            cls.method(name, "(JLjava/time/temporal/TemporalUnit;)Ljava/time/Instant;") { runtime, args, _ in
                let instant = runtime.payload(args[0], as: VMInstantPayload.self) ?? VMInstantPayload(epochMilli: 0)
                let unit = runtime.payload(args[2], as: VMChronoUnitPayload.self)?.name ?? "NANOS"
                let amount = try multiplied(args[1].asInt64, sign)
                return runtime.makeNative("Ljava/time/Instant;", payload: try instantPlus(instant, amount, unit: unit))
            }
        }
        for (name, sign) in [("minusMillis", Int64(-1)), ("plusMillis", Int64(1))] {
            cls.method(name, "(J)Ljava/time/Instant;") { runtime, args, _ in
                let instant = runtime.payload(args[0], as: VMInstantPayload.self) ?? VMInstantPayload(epochMilli: 0)
                let amount = try multiplied(args[1].asInt64, sign)
                return runtime.makeNative("Ljava/time/Instant;", payload: try instantPlus(instant, amount, unit: "MILLIS"))
            }
        }
        for (name, sign) in [("minusSeconds", Int64(-1)), ("plusSeconds", Int64(1))] {
            cls.method(name, "(J)Ljava/time/Instant;") { runtime, args, _ in
                let instant = runtime.payload(args[0], as: VMInstantPayload.self) ?? VMInstantPayload(epochMilli: 0)
                let amount = try multiplied(args[1].asInt64, sign)
                return runtime.makeNative("Ljava/time/Instant;", payload: try instantPlus(instant, amount, unit: "SECONDS"))
            }
        }
        cls.method("minus", "(Ljava/time/temporal/TemporalAmount;)Ljava/time/Instant;") { runtime, args, _ in
            let instant = runtime.payload(args[0], as: VMInstantPayload.self) ?? VMInstantPayload(epochMilli: 0)
            guard let duration = runtime.payload(args[1], as: VMDurationPayload.self) else {
                throw VMJavaException("Ljava/time/DateTimeException;", "Unsupported unit: unsupported TemporalAmount")
            }
            return runtime.makeNative("Ljava/time/Instant;", payload: try instantAddDuration(instant, duration, sign: -1))
        }
        cls.method("plus", "(Ljava/time/temporal/TemporalAmount;)Ljava/time/Instant;") { runtime, args, _ in
            let instant = runtime.payload(args[0], as: VMInstantPayload.self) ?? VMInstantPayload(epochMilli: 0)
            guard let duration = runtime.payload(args[1], as: VMDurationPayload.self) else {
                throw VMJavaException("Ljava/time/DateTimeException;", "Unsupported unit: unsupported TemporalAmount")
            }
            return runtime.makeNative("Ljava/time/Instant;", payload: try instantAddDuration(instant, duration, sign: 1))
        }
        cls.method("atZone", "(Ljava/time/ZoneId;)Ljava/time/ZonedDateTime;") { runtime, args, _ in
            let millis = runtime.payload(args[0], as: VMInstantPayload.self)?.epochMilli ?? 0
            let zone = runtime.payload(args[1], as: VMZonePayload.self) ?? utc
            let date = Date(timeIntervalSince1970: Double(millis) / 1000)
            let resolved = adjustZone(zone, at: date)
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: VMZonedDateTimePayload(local: localFromDate(date, zone: resolved), zone: resolved))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let millis = runtime.payload(args[0], as: VMInstantPayload.self)?.epochMilli ?? 0
            return runtime.newString(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(millis) / 1000)))
        }
        return cls
    }

    // MARK: - java.time enums and builders

    private static func monthDayClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/MonthDay;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/time/temporal/TemporalAccessor;"])
        cls.staticMethod("of", "(II)Ljava/time/MonthDay;") { runtime, args, _ in
            let month = Int(args[0].asInt32)
            let day = Int(args[1].asInt32)
            guard month >= 1, month <= 12 else {
                throw VMJavaException("Ljava/time/DateTimeException;", "Invalid value for MonthOfYear (valid values 1 - 12): \(month)")
            }
            guard day >= 1, day <= lengthOfMonth(year: 2000, month: month) else {
                throw VMJavaException("Ljava/time/DateTimeException;", "Invalid value for DayOfMonth: \(day)")
            }
            return runtime.makeNative("Ljava/time/MonthDay;", payload: VMMonthDayPayload(month: month, day: day))
        }
        cls.method("atYear", "(I)Ljava/time/LocalDate;") { runtime, args, _ in
            guard let value: VMMonthDayPayload = runtime.payload(args[0], as: VMMonthDayPayload.self) else { return .null }
            let year = Int(args[1].asInt32)
            try requireYear(year)
            let day = min(value.day, lengthOfMonth(year: year, month: value.month))
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: year, month: value.month, day: day))
        }
        cls.method("getMonthValue", "()I") { runtime, args, _ in
            .int32(Int32((runtime.payload(args[0], as: VMMonthDayPayload.self) ?? VMMonthDayPayload(month: 1, day: 1)).month))
        }
        cls.method("getDayOfMonth", "()I") { runtime, args, _ in
            .int32(Int32((runtime.payload(args[0], as: VMMonthDayPayload.self) ?? VMMonthDayPayload(month: 1, day: 1)).day))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let value = runtime.payload(args[0], as: VMMonthDayPayload.self) ?? VMMonthDayPayload(month: 1, day: 1)
            return runtime.newString(String(format: "--%02d-%02d", value.month, value.day))
        }
        return cls
    }

    private static func durationClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/Duration;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/time/temporal/TemporalAmount;", "Ljava/lang/Comparable;"])
        cls.staticMethod("ofDays", "(J)Ljava/time/Duration;") { runtime, args, _ in
            let (seconds, overflow) = args[0].asInt64.multipliedReportingOverflow(by: 86_400)
            guard !overflow else { throw arithmeticOverflow("long overflow") }
            return runtime.makeNative("Ljava/time/Duration;", payload: VMDurationPayload(seconds: seconds))
        }
        cls.staticMethod("ofHours", "(J)Ljava/time/Duration;") { runtime, args, _ in
            let (seconds, overflow) = args[0].asInt64.multipliedReportingOverflow(by: 3_600)
            guard !overflow else { throw arithmeticOverflow("long overflow") }
            return runtime.makeNative("Ljava/time/Duration;", payload: VMDurationPayload(seconds: seconds))
        }
        cls.staticMethod("ofMinutes", "(J)Ljava/time/Duration;") { runtime, args, _ in
            let (seconds, overflow) = args[0].asInt64.multipliedReportingOverflow(by: 60)
            guard !overflow else { throw arithmeticOverflow("long overflow") }
            return runtime.makeNative("Ljava/time/Duration;", payload: VMDurationPayload(seconds: seconds))
        }
        cls.staticMethod("ofSeconds", "(J)Ljava/time/Duration;") { runtime, args, _ in
            runtime.makeNative("Ljava/time/Duration;", payload: VMDurationPayload(seconds: args[0].asInt64))
        }
        cls.staticMethod("ofSeconds", "(JJ)Ljava/time/Duration;") { runtime, args, _ in
            runtime.makeNative("Ljava/time/Duration;", payload: VMDurationPayload(seconds: args[0].asInt64, nanos: Int32(truncatingIfNeeded: args[1].asInt64)))
        }
        cls.staticMethod("ofMillis", "(J)Ljava/time/Duration;") { runtime, args, _ in
            let value = args[0].asInt64
            return runtime.makeNative("Ljava/time/Duration;", payload: VMDurationPayload(seconds: value / 1000, nanos: Int32((value % 1000) * 1_000_000)))
        }
        cls.staticMethod("ofNanos", "(J)Ljava/time/Duration;") { runtime, args, _ in
            let value = args[0].asInt64
            return runtime.makeNative("Ljava/time/Duration;", payload: VMDurationPayload(seconds: value / 1_000_000_000, nanos: Int32(value % 1_000_000_000)))
        }
        cls.method("multipliedBy", "(J)Ljava/time/Duration;") { runtime, args, _ in
            let duration = runtime.payload(args[0], as: VMDurationPayload.self) ?? VMDurationPayload(seconds: 0)
            let factor = args[1].asInt64
            let (seconds, overflow) = duration.seconds.multipliedReportingOverflow(by: factor)
            guard !overflow else { throw arithmeticOverflow("long overflow") }
            let nanos = Int64(duration.nanos) * factor
            return runtime.makeNative("Ljava/time/Duration;", payload: VMDurationPayload(
                seconds: seconds + nanos / 1_000_000_000,
                nanos: Int32(nanos % 1_000_000_000)
            ))
        }
        cls.method("plus", "(Ljava/time/Duration;)Ljava/time/Duration;") { runtime, args, _ in
            let mine = runtime.payload(args[0], as: VMDurationPayload.self) ?? VMDurationPayload(seconds: 0)
            let other = runtime.payload(args[1], as: VMDurationPayload.self) ?? VMDurationPayload(seconds: 0)
            let (seconds, overflow) = mine.seconds.addingReportingOverflow(other.seconds)
            guard !overflow else { throw arithmeticOverflow("long overflow") }
            return runtime.makeNative("Ljava/time/Duration;", payload: VMDurationPayload(
                seconds: seconds,
                nanos: mine.nanos + other.nanos
            ))
        }
        cls.method("minus", "(Ljava/time/Duration;)Ljava/time/Duration;") { runtime, args, _ in
            let mine = runtime.payload(args[0], as: VMDurationPayload.self) ?? VMDurationPayload(seconds: 0)
            let other = runtime.payload(args[1], as: VMDurationPayload.self) ?? VMDurationPayload(seconds: 0)
            let (seconds, overflow) = mine.seconds.subtractingReportingOverflow(other.seconds)
            guard !overflow else { throw arithmeticOverflow("long overflow") }
            return runtime.makeNative("Ljava/time/Duration;", payload: VMDurationPayload(
                seconds: seconds,
                nanos: mine.nanos - other.nanos
            ))
        }
        cls.method("negated", "()Ljava/time/Duration;") { runtime, args, _ in
            let duration = runtime.payload(args[0], as: VMDurationPayload.self) ?? VMDurationPayload(seconds: 0)
            guard duration.seconds != Int64.min else { throw arithmeticOverflow("long overflow") }
            return runtime.makeNative("Ljava/time/Duration;", payload: VMDurationPayload(
                seconds: -duration.seconds,
                nanos: -duration.nanos
            ))
        }
        cls.method("getSeconds", "()J") { runtime, args, _ in
            .int64((runtime.payload(args[0], as: VMDurationPayload.self) ?? VMDurationPayload(seconds: 0)).seconds)
        }
        cls.method("getNano", "()I") { runtime, args, _ in
            .int32((runtime.payload(args[0], as: VMDurationPayload.self) ?? VMDurationPayload(seconds: 0)).nanos)
        }
        cls.method("toMillis", "()J") { runtime, args, _ in
            let duration = runtime.payload(args[0], as: VMDurationPayload.self) ?? VMDurationPayload(seconds: 0)
            let (millis, overflow) = duration.seconds.multipliedReportingOverflow(by: 1000)
            guard !overflow else { throw arithmeticOverflow("long overflow") }
            return .int64(millis + Int64(duration.nanos) / 1_000_000)
        }
        cls.method("toNanos", "()J") { runtime, args, _ in
            let duration = runtime.payload(args[0], as: VMDurationPayload.self) ?? VMDurationPayload(seconds: 0)
            let (nanos, overflow) = duration.seconds.multipliedReportingOverflow(by: 1_000_000_000)
            guard !overflow else { throw arithmeticOverflow("long overflow") }
            return .int64(nanos + Int64(duration.nanos))
        }
        cls.method("isNegative", "()Z") { runtime, args, _ in
            let duration = runtime.payload(args[0], as: VMDurationPayload.self) ?? VMDurationPayload(seconds: 0)
            return .boolean(duration.seconds < 0)
        }
        cls.method("isZero", "()Z") { runtime, args, _ in
            let duration = runtime.payload(args[0], as: VMDurationPayload.self) ?? VMDurationPayload(seconds: 0)
            return .boolean(duration.seconds == 0 && duration.nanos == 0)
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let duration = runtime.payload(args[0], as: VMDurationPayload.self) ?? VMDurationPayload(seconds: 0)
            var text = duration.seconds < 0 ? "-PT" : "PT"
            let seconds = abs(duration.seconds)
            var rest = seconds
            let hours = rest / 3_600
            rest -= hours * 3_600
            let minutes = rest / 60
            let secs = rest - minutes * 60
            if hours > 0 { text += "\(hours)H" }
            if minutes > 0 { text += "\(minutes)M" }
            if secs > 0 || duration.nanos > 0 || (seconds == 0 && duration.nanos == 0) {
                text += "\(secs)"
                if duration.nanos > 0 {
                    text += String(format: ".%09d", Int(duration.nanos)).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
                }
                text += "S"
            }
            return runtime.newString(text)
        }
        return cls
    }

    private static func chronoFieldClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/temporal/ChronoField;", superclass: "Ljava/lang/Enum;", interfaces: ["Ljava/time/temporal/TemporalField;"])
        let fields = [
            "NANO_OF_SECOND", "NANO_OF_DAY", "MICRO_OF_SECOND", "MICRO_OF_DAY", "MILLI_OF_SECOND",
            "MILLI_OF_DAY", "SECOND_OF_MINUTE", "SECOND_OF_DAY", "MINUTE_OF_HOUR", "MINUTE_OF_DAY",
            "HOUR_OF_AMPM", "CLOCK_HOUR_OF_AMPM", "HOUR_OF_DAY", "CLOCK_HOUR_OF_DAY", "AMPM_OF_DAY",
            "DAY_OF_WEEK", "ALIGNED_DAY_OF_WEEK_IN_MONTH", "ALIGNED_DAY_OF_WEEK_IN_YEAR",
            "DAY_OF_MONTH", "DAY_OF_YEAR", "EPOCH_DAY", "ALIGNED_WEEK_OF_MONTH",
            "ALIGNED_WEEK_OF_YEAR", "MONTH_OF_YEAR", "PROLEPTIC_MONTH", "YEAR_OF_ERA", "YEAR",
            "ERA", "INSTANT_SECONDS", "OFFSET_SECONDS",
        ]
        for field in fields { cls.staticField(field, "Ljava/time/temporal/ChronoField;") }
        cls.prepare = { runtime, cls in
            for (offset, field) in fields.enumerated() {
                if let existing = cls.staticField(named: field) {
                    cls.setStaticValue(existing, runtime.makeNative("Ljava/time/temporal/ChronoField;", payload: VMChronoFieldPayload(name: field)))
                }
                _ = offset
            }
        }
        cls.staticMethod("values", "()[Ljava/time/temporal/ChronoField;") { runtime, _, _ in
            let cls = runtime.cachedClass("Ljava/time/temporal/ChronoField;")
            let array = runtime.newArray(component: "Ljava/time/temporal/ChronoField;", count: fields.count)
            for (offset, field) in fields.enumerated() {
                if let existing = cls.staticField(named: field) {
                    runtime.setArrayElement(array, index: offset, value: cls.staticValue(existing))
                }
            }
            return array
        }
        cls.staticMethod("valueOf", "(Ljava/lang/String;)Ljava/time/temporal/ChronoField;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let cls = runtime.cachedClass("Ljava/time/temporal/ChronoField;")
            guard fields.contains(text), let existing = cls.staticField(named: text) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "No enum constant java.time.temporal.ChronoField.\(text)")
            }
            return cls.staticValue(existing)
        }
        cls.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMChronoFieldPayload.self)?.name ?? "NANO_OF_SECOND")
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMChronoFieldPayload.self)?.name ?? "NANO_OF_SECOND")
        }
        cls.method("ordinal", "()I") { runtime, args, _ in
            let name = runtime.payload(args[0], as: VMChronoFieldPayload.self)?.name ?? "NANO_OF_SECOND"
            return .int32(Int32(fields.firstIndex(of: name) ?? 0))
        }
        return cls
    }

    private static func weekFieldsClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/temporal/WeekFields;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
        cls.staticField("ISO", "Ljava/time/temporal/WeekFields;")
        cls.staticField("SUNDAY_START", "Ljava/time/temporal/WeekFields;")
        cls.prepare = { runtime, cls in
            if let field = cls.staticField(named: "ISO") {
                cls.setStaticValue(field, runtime.makeNative("Ljava/time/temporal/WeekFields;", payload: VMWeekFieldsPayload(firstDayOfWeek: 1, minimalDays: 4)))
            }
            if let field = cls.staticField(named: "SUNDAY_START") {
                cls.setStaticValue(field, runtime.makeNative("Ljava/time/temporal/WeekFields;", payload: VMWeekFieldsPayload(firstDayOfWeek: 7, minimalDays: 1)))
            }
        }
        cls.staticMethod("of", "(Ljava/time/DayOfWeek;I)Ljava/time/temporal/WeekFields;") { runtime, args, _ in
            let day = runtime.payload(args[0], as: VMDayOfWeekPayload.self)?.value ?? 1
            return runtime.makeNative("Ljava/time/temporal/WeekFields;", payload: VMWeekFieldsPayload(
                firstDayOfWeek: day,
                minimalDays: Int(args[1].asInt32)
            ))
        }
        cls.method("getFirstDayOfWeek", "()Ljava/time/DayOfWeek;") { runtime, args, _ in
            let value = runtime.payload(args[0], as: VMWeekFieldsPayload.self)?.firstDayOfWeek ?? 1
            return runtime.makeNative("Ljava/time/DayOfWeek;", payload: VMDayOfWeekPayload(value: value))
        }
        cls.method("getMinimalDaysInFirstWeek", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMWeekFieldsPayload.self)?.minimalDays ?? 1))
        }
        cls.method("dayOfWeek", "()Ljava/time/temporal/TemporalField;") { runtime, args, _ in
            let start = runtime.payload(args[0], as: VMWeekFieldsPayload.self)?.firstDayOfWeek ?? 1
            return runtime.makeNative("Ljava/time/temporal/TemporalField;", payload: VMChronoFieldPayload(name: "DAY_OF_WEEK", weekStart: start))
        }
        return cls
    }

    private static func formatStyleClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/format/FormatStyle;", superclass: "Ljava/lang/Enum;")
        let styles = ["FULL", "LONG", "MEDIUM", "SHORT"]
        for style in styles { cls.staticField(style, "Ljava/time/format/FormatStyle;") }
        cls.prepare = { runtime, cls in
            for style in styles {
                if let field = cls.staticField(named: style) {
                    cls.setStaticValue(field, runtime.makeNative("Ljava/time/format/FormatStyle;", payload: VMFormatStylePayload(name: style)))
                }
            }
        }
        cls.staticMethod("values", "()[Ljava/time/format/FormatStyle;") { runtime, _, _ in
            let cls = runtime.cachedClass("Ljava/time/format/FormatStyle;")
            let array = runtime.newArray(component: "Ljava/time/format/FormatStyle;", count: styles.count)
            for (offset, style) in styles.enumerated() {
                if let field = cls.staticField(named: style) {
                    runtime.setArrayElement(array, index: offset, value: cls.staticValue(field))
                }
            }
            return array
        }
        cls.staticMethod("valueOf", "(Ljava/lang/String;)Ljava/time/format/FormatStyle;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let cls = runtime.cachedClass("Ljava/time/format/FormatStyle;")
            guard styles.contains(text), let field = cls.staticField(named: text) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "No enum constant java.time.format.FormatStyle.\(text)")
            }
            return cls.staticValue(field)
        }
        cls.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMFormatStylePayload.self)?.name ?? "SHORT")
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMFormatStylePayload.self)?.name ?? "SHORT")
        }
        return cls
    }

    private static func signStyleClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/format/SignStyle;", superclass: "Ljava/lang/Enum;")
        let styles = ["NORMAL", "ALWAYS", "NEVER", "EXCEEDS_PAD", "NOT_NEGATIVE"]
        for style in styles { cls.staticField(style, "Ljava/time/format/SignStyle;") }
        cls.prepare = { runtime, cls in
            for style in styles {
                if let field = cls.staticField(named: style) {
                    cls.setStaticValue(field, runtime.makeNative("Ljava/time/format/SignStyle;", payload: VMSignStylePayload(name: style)))
                }
            }
        }
        cls.staticMethod("values", "()[Ljava/time/format/SignStyle;") { runtime, _, _ in
            let cls = runtime.cachedClass("Ljava/time/format/SignStyle;")
            let array = runtime.newArray(component: "Ljava/time/format/SignStyle;", count: styles.count)
            for (offset, style) in styles.enumerated() {
                if let field = cls.staticField(named: style) {
                    runtime.setArrayElement(array, index: offset, value: cls.staticValue(field))
                }
            }
            return array
        }
        cls.staticMethod("valueOf", "(Ljava/lang/String;)Ljava/time/format/SignStyle;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let cls = runtime.cachedClass("Ljava/time/format/SignStyle;")
            guard styles.contains(text), let field = cls.staticField(named: text) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "No enum constant java.time.format.SignStyle.\(text)")
            }
            return cls.staticValue(field)
        }
        cls.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMSignStylePayload.self)?.name ?? "NORMAL")
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMSignStylePayload.self)?.name ?? "NORMAL")
        }
        return cls
    }

    private static func yearClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/Year;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/time/temporal/TemporalAccessor;", "Ljava/time/temporal/Temporal;", "Ljava/lang/Comparable;"])
        cls.staticMethod("now", "()Ljava/time/Year;") { runtime, _, _ in
            let local = localFromDate(Date(), zone: systemDefaultZone())
            return runtime.makeNative("Ljava/time/Year;", payload: VMYearPayload(year: local.year))
        }
        cls.staticMethod("now", "(Ljava/time/ZoneId;)Ljava/time/Year;") { runtime, args, _ in
            let zone = runtime.payload(args[0], as: VMZonePayload.self) ?? systemDefaultZone()
            let local = localFromDate(Date(), zone: zone)
            return runtime.makeNative("Ljava/time/Year;", payload: VMYearPayload(year: local.year))
        }
        cls.staticMethod("of", "(I)Ljava/time/Year;") { runtime, args, _ in
            runtime.makeNative("Ljava/time/Year;", payload: VMYearPayload(year: Int(args[0].asInt32)))
        }
        cls.staticMethod("isLeap", "(J)Z") { _, args, _ in .boolean(isLeapYear(Int(args[0].asInt64))) }
        cls.method("getValue", "()I") { runtime, args, _ in
            .int32(Int32((runtime.payload(args[0], as: VMYearPayload.self) ?? VMYearPayload(year: 1970)).year))
        }
        cls.method("isLeap", "()Z") { runtime, args, _ in
            .boolean(isLeapYear((runtime.payload(args[0], as: VMYearPayload.self) ?? VMYearPayload(year: 1970)).year))
        }
        cls.method("atDay", "(I)Ljava/time/LocalDate;") { runtime, args, _ in
            let year = (runtime.payload(args[0], as: VMYearPayload.self) ?? VMYearPayload(year: 1970)).year
            let civil = JavaTextRuntime.civilFromDays(JavaTextRuntime.daysFromCivil(year, 1, 1) + Int(args[1].asInt32) - 1)
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: civil.year, month: civil.month, day: civil.day))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(String((runtime.payload(args[0], as: VMYearPayload.self) ?? VMYearPayload(year: 1970)).year))
        }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let mine = runtime.payload(args[0], as: VMYearPayload.self),
                  let other = runtime.payload(args[1], as: VMYearPayload.self) else { return .boolean(false) }
            return .boolean(mine.year == other.year)
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            .int32(Int32(truncatingIfNeeded: (runtime.payload(args[0], as: VMYearPayload.self) ?? VMYearPayload(year: 1970)).year))
        }
        cls.method("compareTo", "(Ljava/time/Year;)I") { runtime, args, _ in
            let mine = (runtime.payload(args[0], as: VMYearPayload.self) ?? VMYearPayload(year: 0)).year
            let other = (runtime.payload(args[1], as: VMYearPayload.self) ?? VMYearPayload(year: 0)).year
            return .int32(mine < other ? -1 : (mine > other ? 1 : 0))
        }
        return cls
    }

    private static func dayOfWeekClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/DayOfWeek;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/time/temporal/TemporalAccessor;", "Ljava/time/temporal/Temporal;", "Ljava/lang/Comparable;"])
        let names = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]
        for name in names { cls.staticField(name, "Ljava/time/DayOfWeek;") }
        cls.prepare = { runtime, cls in
            for (offset, name) in names.enumerated() {
                if let field = cls.staticField(named: name) {
                    cls.setStaticValue(field, runtime.makeNative("Ljava/time/DayOfWeek;", payload: VMDayOfWeekPayload(value: offset + 1)))
                }
            }
        }
        cls.staticMethod("values", "()[Ljava/time/DayOfWeek;") { runtime, _, _ in
            let cls = runtime.cachedClass("Ljava/time/DayOfWeek;")
            let array = runtime.newArray(component: "Ljava/time/DayOfWeek;", count: names.count)
            for (offset, name) in names.enumerated() {
                if let field = cls.staticField(named: name) {
                    runtime.setArrayElement(array, index: offset, value: cls.staticValue(field))
                }
            }
            return array
        }
        cls.staticMethod("valueOf", "(Ljava/lang/String;)Ljava/time/DayOfWeek;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let cls = runtime.cachedClass("Ljava/time/DayOfWeek;")
            guard let field = cls.staticField(named: text) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "No enum constant java.time.DayOfWeek.\(text)")
            }
            return cls.staticValue(field)
        }
        cls.staticMethod("of", "(I)Ljava/time/DayOfWeek;") { runtime, args, _ in
            let value = Int(args[0].asInt32)
            guard value >= 1, value <= 7 else {
                throw VMJavaException("Ljava/time/DateTimeException;", "Invalid value for DayOfWeek: \(value)")
            }
            return runtime.makeNative("Ljava/time/DayOfWeek;", payload: VMDayOfWeekPayload(value: value))
        }
        cls.method("getValue", "()I") { runtime, args, _ in
            .int32(Int32((runtime.payload(args[0], as: VMDayOfWeekPayload.self) ?? VMDayOfWeekPayload(value: 1)).value))
        }
        cls.method("getDisplayName", "(Ljava/time/format/TextStyle;Ljava/util/Locale;)Ljava/lang/String;") { runtime, args, _ in
            let value = (runtime.payload(args[0], as: VMDayOfWeekPayload.self) ?? VMDayOfWeekPayload(value: 1)).value
            let style = runtime.payload(args[1], as: VMTextStylePayload.self)?.name ?? "FULL"
            let names = VMDateNames.forLanguage(JavaTextRuntime.localeLanguage(runtime, args[2]))
            let index = value % 7
            if style.hasPrefix("NARROW") { return runtime.newString(String(names.weekdaysFull[index].prefix(1))) }
            if style.hasPrefix("SHORT") { return runtime.newString(names.weekdaysShort[index]) }
            return runtime.newString(names.weekdaysFull[index])
        }
        cls.method("plus", "(J)Ljava/time/DayOfWeek;") { runtime, args, _ in
            let value = (runtime.payload(args[0], as: VMDayOfWeekPayload.self) ?? VMDayOfWeekPayload(value: 1)).value
            let shifted = ((value - 1 + Int(args[1].asInt64)) % 7 + 7) % 7 + 1
            return runtime.makeNative("Ljava/time/DayOfWeek;", payload: VMDayOfWeekPayload(value: shifted))
        }
        cls.method("minus", "(J)Ljava/time/DayOfWeek;") { runtime, args, _ in
            let value = (runtime.payload(args[0], as: VMDayOfWeekPayload.self) ?? VMDayOfWeekPayload(value: 1)).value
            let shifted = ((value - 1 - Int(args[1].asInt64)) % 7 + 7) % 7 + 1
            return runtime.makeNative("Ljava/time/DayOfWeek;", payload: VMDayOfWeekPayload(value: shifted))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let value = (runtime.payload(args[0], as: VMDayOfWeekPayload.self) ?? VMDayOfWeekPayload(value: 1)).value
            return runtime.newString(names[max(0, min(6, value - 1))])
        }
        cls.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            let value = (runtime.payload(args[0], as: VMDayOfWeekPayload.self) ?? VMDayOfWeekPayload(value: 1)).value
            return runtime.newString(names[max(0, min(6, value - 1))])
        }
        cls.method("ordinal", "()I") { runtime, args, _ in
            .int32(Int32((runtime.payload(args[0], as: VMDayOfWeekPayload.self) ?? VMDayOfWeekPayload(value: 1)).value - 1))
        }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let mine = runtime.payload(args[0], as: VMDayOfWeekPayload.self),
                  let other = runtime.payload(args[1], as: VMDayOfWeekPayload.self) else { return .boolean(false) }
            return .boolean(mine.value == other.value)
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            .int32(Int32((runtime.payload(args[0], as: VMDayOfWeekPayload.self) ?? VMDayOfWeekPayload(value: 1)).value))
        }
        return cls
    }

    private static func textStyleClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/format/TextStyle;", superclass: "Ljava/lang/Enum;")
        let styles = ["FULL", "FULL_STANDALONE", "SHORT", "SHORT_STANDALONE", "NARROW", "NARROW_STANDALONE"]
        for style in styles { cls.staticField(style, "Ljava/time/format/TextStyle;") }
        cls.prepare = { runtime, cls in
            for (offset, style) in styles.enumerated() {
                if let field = cls.staticField(named: style) {
                    cls.setStaticValue(field, runtime.makeNative("Ljava/time/format/TextStyle;", payload: VMTextStylePayload(name: style)))
                }
            }
        }
        cls.staticMethod("values", "()[Ljava/time/format/TextStyle;") { runtime, _, _ in
            let cls = runtime.cachedClass("Ljava/time/format/TextStyle;")
            let array = runtime.newArray(component: "Ljava/time/format/TextStyle;", count: styles.count)
            for (offset, style) in styles.enumerated() {
                if let field = cls.staticField(named: style) {
                    runtime.setArrayElement(array, index: offset, value: cls.staticValue(field))
                }
            }
            return array
        }
        cls.staticMethod("valueOf", "(Ljava/lang/String;)Ljava/time/format/TextStyle;") { runtime, args, _ in
            let name = runtime.stringValue(args[0]) ?? ""
            let cls = runtime.cachedClass("Ljava/time/format/TextStyle;")
            guard styles.contains(name), let field = cls.staticField(named: name) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "No enum constant java.time.format.TextStyle.\(name)")
            }
            return cls.staticValue(field)
        }
        cls.method("isStandalone", "()Z") { runtime, args, _ in
            .boolean((runtime.payload(args[0], as: VMTextStylePayload.self)?.name ?? "").hasSuffix("_STANDALONE"))
        }
        cls.method("asStandalone", "()Ljava/time/format/TextStyle;") { runtime, args, _ in
            let name = runtime.payload(args[0], as: VMTextStylePayload.self)?.name ?? "FULL"
            let standalone = name.hasSuffix("_STANDALONE") ? name : name + "_STANDALONE"
            return runtime.makeNative("Ljava/time/format/TextStyle;", payload: VMTextStylePayload(name: standalone))
        }
        cls.method("asNormal", "()Ljava/time/format/TextStyle;") { runtime, args, _ in
            let name = runtime.payload(args[0], as: VMTextStylePayload.self)?.name ?? "FULL"
            let normal = name.replacingOccurrences(of: "_STANDALONE", with: "")
            return runtime.makeNative("Ljava/time/format/TextStyle;", payload: VMTextStylePayload(name: normal))
        }
        cls.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMTextStylePayload.self)?.name ?? "FULL")
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMTextStylePayload.self)?.name ?? "FULL")
        }
        cls.method("ordinal", "()I") { runtime, args, _ in
            let name = runtime.payload(args[0], as: VMTextStylePayload.self)?.name ?? "FULL"
            return .int32(Int32(styles.firstIndex(of: name) ?? 0))
        }
        return cls
    }

    private static func chronoUnitClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/temporal/ChronoUnit;", superclass: "Ljava/lang/Enum;")
        let units = [
            "NANOS", "MICROS", "MILLIS", "SECONDS", "MINUTES", "HOURS", "HALF_DAYS", "DAYS",
            "WEEKS", "MONTHS", "YEARS", "DECADES", "CENTURIES", "MILLENNIA", "ERAS", "FOREVER",
        ]
        for unit in units { cls.staticField(unit, "Ljava/time/temporal/ChronoUnit;") }
        cls.prepare = { runtime, cls in
            for (offset, unit) in units.enumerated() {
                if let field = cls.staticField(named: unit) {
                    cls.setStaticValue(field, runtime.makeNative("Ljava/time/temporal/ChronoUnit;", payload: VMChronoUnitPayload(name: unit)))
                }
                _ = offset
            }
        }
        cls.staticMethod("values", "()[Ljava/time/temporal/ChronoUnit;") { runtime, _, _ in
            let cls = runtime.cachedClass("Ljava/time/temporal/ChronoUnit;")
            let array = runtime.newArray(component: "Ljava/time/temporal/ChronoUnit;", count: units.count)
            for (offset, unit) in units.enumerated() {
                if let field = cls.staticField(named: unit) {
                    runtime.setArrayElement(array, index: offset, value: cls.staticValue(field))
                }
            }
            return array
        }
        cls.staticMethod("valueOf", "(Ljava/lang/String;)Ljava/time/temporal/ChronoUnit;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let cls = runtime.cachedClass("Ljava/time/temporal/ChronoUnit;")
            guard let field = cls.staticField(named: text) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "No enum constant java.time.temporal.ChronoUnit.\(text)")
            }
            return cls.staticValue(field)
        }
        cls.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMChronoUnitPayload.self)?.name ?? "NANOS")
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMChronoUnitPayload.self)?.name ?? "NANOS")
        }
        cls.method("isDateBased", "()Z") { runtime, args, _ in
            let name = runtime.payload(args[0], as: VMChronoUnitPayload.self)?.name ?? "NANOS"
            return .boolean(["DAYS", "WEEKS", "MONTHS", "YEARS", "DECADES", "CENTURIES", "MILLENNIA", "ERAS"].contains(name))
        }
        cls.method("isTimeBased", "()Z") { runtime, args, _ in
            let name = runtime.payload(args[0], as: VMChronoUnitPayload.self)?.name ?? "NANOS"
            return .boolean(["NANOS", "MICROS", "MILLIS", "SECONDS", "MINUTES", "HOURS", "HALF_DAYS"].contains(name))
        }
        return cls
    }

    private static func formatterBuilderClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/format/DateTimeFormatterBuilder;", superclass: "Ljava/lang/Object;")
        cls.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMFormatterBuilderPayload())
            return .zero
        }
        cls.method("appendPattern", "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            runtime.mutableFormatterBuilder(args[0]).pattern += runtime.stringValue(args[1]) ?? ""
            return args[0]
        }
        cls.method("appendLiteral", "(C)Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            let text = String(UnicodeScalar(args[1].asUInt32) ?? " ")
            runtime.mutableFormatterBuilder(args[0]).pattern += quoteLiteral(text)
            return args[0]
        }
        cls.method("appendLiteral", "(Ljava/lang/CharSequence;)Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            runtime.mutableFormatterBuilder(args[0]).pattern += quoteLiteral(runtime.stringValue(args[1]) ?? "")
            return args[0]
        }
        cls.method("appendOptional", "(Ljava/time/format/DateTimeFormatter;)Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            let source: VMDateTimeFormatterPayload? = runtime.payload(args[1], as: VMDateTimeFormatterPayload.self)
            runtime.mutableFormatterBuilder(args[0]).pattern += "[" + (source?.pattern ?? "") + "]"
            return args[0]
        }
        cls.method("append", "(Ljava/time/format/DateTimeFormatter;)Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            let source: VMDateTimeFormatterPayload? = runtime.payload(args[1], as: VMDateTimeFormatterPayload.self)
            runtime.mutableFormatterBuilder(args[0]).pattern += source?.pattern ?? ""
            return args[0]
        }
        cls.method("optionalStart", "()Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            runtime.mutableFormatterBuilder(args[0]).pattern += "["
            return args[0]
        }
        cls.method("optionalEnd", "()Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            runtime.mutableFormatterBuilder(args[0]).pattern += "]"
            return args[0]
        }
        cls.method("parseCaseInsensitive", "()Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            runtime.mutableFormatterBuilder(args[0]).caseInsensitive = true
            return args[0]
        }
        cls.method("parseCaseSensitive", "()Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            runtime.mutableFormatterBuilder(args[0]).caseInsensitive = false
            return args[0]
        }
        cls.method("parseLenient", "()Ljava/time/format/DateTimeFormatterBuilder;") { _, args, _ in args[0] }
        cls.method("parseStrict", "()Ljava/time/format/DateTimeFormatterBuilder;") { _, args, _ in args[0] }
        cls.method("appendValue", "(Ljava/time/temporal/TemporalField;I)Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            let builder = runtime.mutableFormatterBuilder(args[0])
            let field = runtime.payload(args[1], as: VMChronoFieldPayload.self)?.name ?? "YEAR"
            builder.pattern += temporalFieldPattern(field, width: Int(args[2].asInt32))
            return args[0]
        }
        cls.method("appendValue", "(Ljava/time/temporal/TemporalField;IILjava/time/format/SignStyle;)Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            let builder = runtime.mutableFormatterBuilder(args[0])
            let field = runtime.payload(args[1], as: VMChronoFieldPayload.self)?.name ?? "YEAR"
            let minimum = Int(args[2].asInt32)
            let maximum = Int(args[3].asInt32)
            let width = maximum == 19 ? max(1, minimum) : max(minimum, maximum)
            builder.pattern += temporalFieldPattern(field, width: width)
            return args[0]
        }
        cls.method("appendFraction", "(Ljava/time/temporal/TemporalField;IIZ)Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            let builder = runtime.mutableFormatterBuilder(args[0])
            let maximum = Int(args[3].asInt32)
            if args[4].asUInt32 != 0 { builder.pattern += "." }
            builder.pattern += String(repeating: "S", count: max(1, min(9, maximum)))
            return args[0]
        }
        cls.method("appendText", "(Ljava/time/temporal/TemporalField;Ljava/util/Map;)Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            let builder = runtime.mutableFormatterBuilder(args[0])
            let field = runtime.payload(args[1], as: VMChronoFieldPayload.self)?.name ?? "MONTH_OF_YEAR"
            var values: [Int64: String] = [:]
            if let map: VMMapPayload = runtime.payload(args[2], as: VMMapPayload.self) {
                for entry in map.entries {
                    guard let text = runtime.stringValue(entry.value) else { continue }
                    values[entry.key.asInt64] = text
                }
            }
            builder.textMaps.append(VMTextMapEntry(field: field, values: values))
            // Private-use marker token consumed by format/parse for this table.
            if let scalar = UnicodeScalar(0xE000 + builder.textMaps.count) {
                builder.pattern.append(Character(scalar))
            }
            return args[0]
        }
        cls.method("parseDefaulting", "(Ljava/time/temporal/TemporalField;J)Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            let builder = runtime.mutableFormatterBuilder(args[0])
            let field = runtime.payload(args[1], as: VMChronoFieldPayload.self)?.name ?? "YEAR"
            builder.defaults[field] = args[2].asInt64
            return args[0]
        }
        cls.method("toFormatter", "()Ljava/time/format/DateTimeFormatter;") { runtime, args, _ in
            let builder = runtime.formatterBuilderPayload(args[0]) ?? VMFormatterBuilderPayload()
            return runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(
                pattern: builder.pattern,
                language: "en",
                caseInsensitive: builder.caseInsensitive,
                textMaps: builder.textMaps,
                defaults: builder.defaults
            ))
        }
        cls.method("toFormatter", "(Ljava/util/Locale;)Ljava/time/format/DateTimeFormatter;") { runtime, args, _ in
            let builder = runtime.formatterBuilderPayload(args[0]) ?? VMFormatterBuilderPayload()
            return runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(
                pattern: builder.pattern,
                language: JavaTextRuntime.localeLanguage(runtime, args[1]),
                caseInsensitive: builder.caseInsensitive,
                textMaps: builder.textMaps,
                defaults: builder.defaults
            ))
        }
        return cls
    }

    /// Pattern letters for `appendValue`/`appendText`, mirroring how the JDK
    /// renders a field that was added programmatically.
    static func temporalFieldPattern(_ field: String, width: Int) -> String {
        let count = max(1, width)
        switch field {
        case "YEAR", "YEAR_OF_ERA", "PROLEPTIC_MONTH": return String(repeating: "u", count: count)
        case "MONTH_OF_YEAR": return String(repeating: "M", count: min(4, count))
        case "DAY_OF_MONTH": return String(repeating: "d", count: count)
        case "DAY_OF_YEAR": return String(repeating: "D", count: count)
        case "HOUR_OF_DAY": return String(repeating: "H", count: count)
        case "MINUTE_OF_HOUR": return String(repeating: "m", count: count)
        case "SECOND_OF_MINUTE": return String(repeating: "s", count: count)
        case "NANO_OF_SECOND": return String(repeating: "S", count: min(9, count))
        case "MILLI_OF_SECOND": return String(repeating: "S", count: 3)
        case "DAY_OF_WEEK": return String(repeating: "e", count: count)
        default: return ""
        }
    }

    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    static func quoteLiteral(_ text: String) -> String {
        if text.isEmpty { return "''" }
        return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func parseException() -> NativeClass {
        let cls = NativeClass("Ljava/time/format/DateTimeParseException;", superclass: "Ljava/lang/RuntimeException;")
        cls.method("<init>", "(Ljava/lang/String;)V") { _, _, _ in .zero }
        cls.method("<init>", "(Ljava/lang/String;Ljava/lang/CharSequence;)V") { _, _, _ in .zero }
        return cls
    }

    private static func unsupportedTemporalTypeException() -> NativeClass {
        NativeClass("Ljava/time/temporal/UnsupportedTemporalTypeException;", superclass: "Ljava/lang/RuntimeException;")
    }

    // MARK: - Zone helpers

    /// The device zone, resolved for the given instant so region zones keep
    /// their daylight-saving offset.
    static func systemDefaultZone(for date: Date = Date()) -> VMZonePayload {
        let zone = TimeZone.current
        return VMZonePayload(id: zone.identifier, secondsFromGMT: zone.secondsFromGMT(for: date))
    }

    static func foundationTimeZone(_ zone: VMZonePayload) -> TimeZone {
        TimeZone(identifier: zone.id) ?? TimeZone(secondsFromGMT: zone.secondsFromGMT) ?? TimeZone(secondsFromGMT: 0)!
    }

    /// Region zones carry daylight-saving rules; fixed offsets keep their value.
    static func adjustZone(_ zone: VMZonePayload, at date: Date) -> VMZonePayload {
        guard let timeZone = TimeZone(identifier: zone.id) else { return zone }
        let seconds = timeZone.secondsFromGMT(for: date)
        return seconds == zone.secondsFromGMT ? zone : VMZonePayload(id: zone.id, secondsFromGMT: seconds)
    }

    static func resolvedZone(_ local: VMLocalDateTimePayload, zone: VMZonePayload) -> VMZonePayload {
        let resolution = resolveLocal(local, zone: zone)
        return VMZonePayload(id: zone.id, secondsFromGMT: resolution.offsetSeconds)
    }

    /// Offset in effect for `zone` at an absolute instant.
    static func zoneOffsetSeconds(_ zone: VMZonePayload, atEpochMilli millis: Int64) -> Int {
        guard let timeZone = TimeZone(identifier: zone.id) else { return zone.secondsFromGMT }
        return timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    /// Civil date-time rendered as if it were UTC, in milliseconds.
    static func localEpochMilli(_ local: VMLocalDateTimePayload) -> Int64 {
        let days = Int64(JavaTextRuntime.daysFromCivil(local.year, local.month, local.day))
        return days * 86_400_000
            + Int64(local.hour) * 3_600_000
            + Int64(local.minute) * 60_000
            + Int64(local.second) * 1000
            + Int64(local.nano / 1_000_000)
    }

    /// Resolves a wall-clock value in `zone` the way `ZonedDateTime.of` does:
    /// in a spring-forward gap the local time moves forward by the gap length
    /// and in a fall-back overlap the earlier offset wins.
    static func resolveLocal(_ local: VMLocalDateTimePayload, zone: VMZonePayload) -> (epochMilli: Int64, offsetSeconds: Int) {
        let localMillis = localEpochMilli(local)
        guard TimeZone(identifier: zone.id) != nil else {
            let offset = zone.secondsFromGMT
            return (localMillis - Int64(offset) * 1000, offset)
        }
        // Candidate offsets around the wall clock; one is valid away from a
        // transition, two are valid inside a fall-back overlap and none are
        // valid inside a spring-forward gap.
        let candidates = Set([
            zoneOffsetSeconds(zone, atEpochMilli: localMillis),
            zoneOffsetSeconds(zone, atEpochMilli: localMillis - 86_400_000),
            zoneOffsetSeconds(zone, atEpochMilli: localMillis + 86_400_000),
        ])
        var valid: [Int] = []
        for offset in candidates {
            let epoch = localMillis - Int64(offset) * 1000
            if zoneOffsetSeconds(zone, atEpochMilli: epoch) == offset { valid.append(offset) }
        }
        // Overlap: the JDK keeps the offset in force before the transition,
        // which is the larger of the two offsets (fall-back decreases it).
        if let chosen = valid.max() {
            return (localMillis - Int64(chosen) * 1000, chosen)
        }
        // Gap: apply the pre-transition offset so the wall clock jumps forward.
        let before = candidates.min() ?? zone.secondsFromGMT
        let after = candidates.max() ?? zone.secondsFromGMT
        return (localMillis - Int64(before) * 1000, after)
    }

    /// Java renders the offset first and appends the region id in brackets;
    /// pure offsets stop at the offset.
    static func zoneSuffix(_ zone: VMZonePayload) -> String {
        let offset = zone.secondsFromGMT == 0 ? "Z" : offsetId(zone.secondsFromGMT)
        let id = zone.id
        if id.hasPrefix("+") || id.hasPrefix("-") || id == "Z" { return offset }
        return offset + "[" + id + "]"
    }

    static func parseZoneId(_ text: String) -> VMZonePayload {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value == "UTC" || value == "Z" || value == "GMT" || value == "UT" { return utc }
        if value.hasPrefix("+") || value.hasPrefix("-") {
            let sign = value.hasPrefix("-") ? -1 : 1
            let body = value.dropFirst()
            let parts = body.split(separator: ":")
            let hours = Int(parts.first ?? "0") ?? 0
            let minutes = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let seconds = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            return VMZonePayload(id: value, secondsFromGMT: sign * (hours * 3600 + minutes * 60 + seconds))
        }
        if let zone = TimeZone(identifier: value) {
            return VMZonePayload(id: value, secondsFromGMT: zone.secondsFromGMT())
        }
        return utc
    }

    static func offsetId(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        if magnitude % 60 != 0 {
            return String(format: "%@%02d:%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60, magnitude % 60)
        }
        return String(format: "%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
    }

    // MARK: - Civil arithmetic

    static let minYear = -999_999_999
    static let maxYear = 999_999_999

    static func requireYear(_ year: Int) throws {
        guard year >= minYear, year <= maxYear else {
            throw VMJavaException("Ljava/time/DateTimeException;", "Invalid value for Year (valid values \(minYear) - \(maxYear)): \(year)")
        }
    }

    static func lengthOfMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// `LocalDate.of` validation: disqualifying values raise `DateTimeException`.
    static func requireValidDate(year: Int, month: Int, day: Int) throws {
        try requireYear(year)
        guard month >= 1, month <= 12 else {
            throw VMJavaException("Ljava/time/DateTimeException;", "Invalid value for MonthOfYear (valid values 1 - 12): \(month)")
        }
        guard day >= 1 else {
            throw VMJavaException("Ljava/time/DateTimeException;", "Invalid value for DayOfMonth (valid values 1 - 28/31): \(day)")
        }
        let length = lengthOfMonth(year: year, month: month)
        guard day <= length else {
            throw VMJavaException("Ljava/time/DateTimeException;", "Invalid date 'DayOfMonth \(day)' for month \(month)")
        }
    }

    /// `LocalDate.plusDays` keeps the time of day; overflow raises
    /// `ArithmeticException`, matching the JDK's `addExact`.
    static func addDays(_ local: VMLocalDateTimePayload, _ amount: Int64) throws -> VMLocalDateTimePayload {
        let epochDay = Int64(JavaTextRuntime.daysFromCivil(local.year, local.month, local.day))
        let (sum, overflow) = epochDay.addingReportingOverflow(amount)
        guard !overflow else { throw arithmeticOverflow("long overflow") }
        guard sum >= Int64(JavaTextRuntime.daysFromCivil(minYear, 1, 1)),
              sum <= Int64(JavaTextRuntime.daysFromCivil(maxYear, 12, 31)) else {
            throw VMJavaException("Ljava/time/DateTimeException;", "Invalid value for Year (valid values \(minYear) - \(maxYear))")
        }
        let civil = JavaTextRuntime.civilFromDays(Int(sum))
        let copy = local.copy()
        copy.year = civil.year
        copy.month = civil.month
        copy.day = civil.day
        return copy
    }

    static func addMonths(_ local: VMLocalDateTimePayload, _ amount: Int64) throws -> VMLocalDateTimePayload {
        let packed = Int64(local.year) * 12 + Int64(local.month - 1)
        let (sum, overflow) = packed.addingReportingOverflow(amount)
        guard !overflow else { throw arithmeticOverflow("long overflow") }
        let year = Int(JavaTextRuntime.floorDivide(sum, 12))
        let month = Int(sum - Int64(year) * 12) + 1
        try requireYear(year)
        let copy = local.copy()
        copy.year = year
        copy.month = month
        copy.day = min(copy.day, lengthOfMonth(year: year, month: month))
        return copy
    }

    static func addYears(_ local: VMLocalDateTimePayload, _ amount: Int64) throws -> VMLocalDateTimePayload {
        let (yearValue, overflow) = Int64(local.year).addingReportingOverflow(amount)
        guard !overflow else { throw arithmeticOverflow("long overflow") }
        let year = Int(yearValue)
        try requireYear(year)
        let copy = local.copy()
        copy.year = year
        copy.day = min(copy.day, lengthOfMonth(year: year, month: copy.month))
        return copy
    }

    static func arithmeticOverflow(_ message: String) -> VMJavaException {
        VMJavaException("Ljava/lang/ArithmeticException;", message)
    }

    /// `Math.multiplyExact` for the `minus`/`plus` negative-amount path.
    static func multiplied(_ value: Int64, _ factor: Int64) throws -> Int64 {
        let (result, overflow) = value.multipliedReportingOverflow(by: factor)
        guard !overflow else { throw arithmeticOverflow("long overflow") }
        return result
    }

    static func truncate(_ local: VMLocalDateTimePayload, unit: String) throws -> VMLocalDateTimePayload {
        let copy = local.copy()
        switch unit {
        case "NANOS": break
        case "MICROS": copy.nano = copy.nano / 1000 * 1000
        case "MILLIS": copy.nano = copy.nano / 1_000_000 * 1_000_000
        case "SECONDS": copy.nano = 0
        case "MINUTES": copy.second = 0; copy.nano = 0
        case "HOURS": copy.minute = 0; copy.second = 0; copy.nano = 0
        case "HALF_DAYS":
            copy.hour = copy.hour / 12 * 12
            copy.minute = 0; copy.second = 0; copy.nano = 0
        case "DAYS":
            copy.hour = 0; copy.minute = 0; copy.second = 0; copy.nano = 0
        default:
            throw VMJavaException("Ljava/time/temporal/UnsupportedTemporalTypeException;", "Unit is too large to truncate to: \(unit)")
        }
        return copy
    }

    /// Applies a `ChronoUnit` to a local date-time. Date-based units move the
    /// calendar fields (day-of-month is clamped), time-based units move the
    /// wall clock; both match `LocalDateTime.plus(long, TemporalUnit)`.
    static func addUnit(_ local: VMLocalDateTimePayload, _ amount: Int64, unit: String) throws -> VMLocalDateTimePayload {
        switch unit {
        case "NANOS": return try addTime(local, amount, nanosPerUnit: 1)
        case "MICROS": return try addTime(local, amount, nanosPerUnit: 1_000)
        case "MILLIS": return try addTime(local, amount, nanosPerUnit: 1_000_000)
        case "SECONDS": return try addTime(local, amount, nanosPerUnit: 1_000_000_000)
        case "MINUTES": return try addTime(local, amount, nanosPerUnit: 60 * 1_000_000_000)
        case "HOURS": return try addTime(local, amount, nanosPerUnit: 3_600 * 1_000_000_000)
        case "HALF_DAYS": return try addTime(local, amount, nanosPerUnit: 43_200 * 1_000_000_000)
        case "DAYS": return try addDays(local, amount)
        case "WEEKS":
            let (days, overflow) = amount.multipliedReportingOverflow(by: 7)
            guard !overflow else { throw arithmeticOverflow("long overflow") }
            return try addDays(local, days)
        case "MONTHS": return try addMonths(local, amount)
        case "YEARS": return try addYears(local, amount)
        case "DECADES":
            let (years, overflow) = amount.multipliedReportingOverflow(by: 10)
            guard !overflow else { throw arithmeticOverflow("long overflow") }
            return try addYears(local, years)
        case "CENTURIES":
            let (years, overflow) = amount.multipliedReportingOverflow(by: 100)
            guard !overflow else { throw arithmeticOverflow("long overflow") }
            return try addYears(local, years)
        case "MILLENNIA":
            let (years, overflow) = amount.multipliedReportingOverflow(by: 1_000)
            guard !overflow else { throw arithmeticOverflow("long overflow") }
            return try addYears(local, years)
        default:
            throw VMJavaException("Ljava/time/temporal/UnsupportedTemporalTypeException;", "Invalid unit for addTo: \(unit)")
        }
    }

    private static func addTime(_ local: VMLocalDateTimePayload, _ amount: Int64, nanosPerUnit: Int64) throws -> VMLocalDateTimePayload {
        let (delta, multiplied) = amount.multipliedReportingOverflow(by: nanosPerUnit)
        guard !multiplied else { throw arithmeticOverflow("long overflow") }
        let timeNanos = Int64(local.hour) * 3_600_000_000_000
            + Int64(local.minute) * 60_000_000_000
            + Int64(local.second) * 1_000_000_000
            + Int64(local.nano)
        let (total, overflow) = timeNanos.addingReportingOverflow(delta)
        guard !overflow else { throw arithmeticOverflow("long overflow") }
        let dayShift = JavaTextRuntime.floorDivide(total, 86_400_000_000_000)
        let rest = total - dayShift * 86_400_000_000_000
        var shifted = try addDays(local, dayShift)
        shifted.hour = Int(rest / 3_600_000_000_000)
        shifted.minute = Int((rest % 3_600_000_000_000) / 60_000_000_000)
        shifted.second = Int((rest % 60_000_000_000) / 1_000_000_000)
        shifted.nano = Int(rest % 1_000_000_000)
        return shifted
    }

    // MARK: - Zoned and instant arithmetic

    /// Resolves a wall-clock value against a zone and returns the value the JDK
    /// would keep: identical outside transitions, shifted forward inside a gap.
    static func resolvedLocal(_ local: VMLocalDateTimePayload, zone: VMZonePayload) -> (local: VMLocalDateTimePayload, zone: VMZonePayload) {
        let resolution = resolveLocal(local, zone: zone)
        let delta = resolution.epochMilli + Int64(resolution.offsetSeconds) * 1000 - localEpochMilli(local)
        let shifted = (try? addUnit(local, delta, unit: "MILLIS")) ?? local.copy()
        return (shifted, VMZonePayload(id: zone.id, secondsFromGMT: resolution.offsetSeconds))
    }

    /// `ZonedDateTime.plus(long, TemporalUnit)`: units move the local timeline
    /// first and the offset is resolved afterwards, which is what the JDK does.
    static func shiftedZoned(_ zoned: VMZonedDateTimePayload, amount: Int64, unit: String) throws -> VMZonedDateTimePayload {
        let updated = try addUnit(zoned.local, amount, unit: unit)
        let resolved = resolvedLocal(updated, zone: zoned.zone)
        return VMZonedDateTimePayload(local: resolved.local, zone: resolved.zone)
    }

    static func instantPlus(_ instant: VMInstantPayload, _ amount: Int64, unit: String) throws -> VMInstantPayload {
        let millisPerUnit: Int64
        switch unit {
        case "NANOS": millisPerUnit = 0
        case "MICROS": millisPerUnit = 0
        case "MILLIS": millisPerUnit = 1
        case "SECONDS": millisPerUnit = 1_000
        case "MINUTES": millisPerUnit = 60_000
        case "HOURS": millisPerUnit = 3_600_000
        case "HALF_DAYS": millisPerUnit = 43_200_000
        case "DAYS": millisPerUnit = 86_400_000
        case "WEEKS": millisPerUnit = 604_800_000
        default:
            throw VMJavaException("Ljava/time/temporal/UnsupportedTemporalTypeException;", "Unsupported unit: \(unit)")
        }
        let (delta, overflow) = amount.multipliedReportingOverflow(by: millisPerUnit)
        guard !overflow else { throw arithmeticOverflow("long overflow") }
        let (sum, addOverflow) = instant.epochMilli.addingReportingOverflow(delta)
        guard !addOverflow else { throw arithmeticOverflow("long overflow") }
        var nano = instant.nano
        if millisPerUnit == 0 {
            // Sub-millisecond units accumulate in the nanosecond remainder.
            let nanosPerUnit: Int64 = unit == "NANOS" ? 1 : 1_000
            let (nanoDelta, nanoOverflow) = amount.multipliedReportingOverflow(by: nanosPerUnit)
            guard !nanoOverflow else { throw arithmeticOverflow("long overflow") }
            let (total, carry) = Int64(nano).addingReportingOverflow(nanoDelta)
            guard !carry else { throw arithmeticOverflow("long overflow") }
            let carriedMillis = total / 1_000_000
            let remainder = total % 1_000_000
            let (withCarry, carryOverflow) = sum.addingReportingOverflow(carriedMillis)
            guard !carryOverflow else { throw arithmeticOverflow("long overflow") }
            nano = Int32((remainder + 1_000_000) % 1_000_000)
            return VMInstantPayload(epochMilli: withCarry + (remainder < 0 ? -1 : 0), nano: nano)
        }
        return VMInstantPayload(epochMilli: sum, nano: nano)
    }

    static func instantAddDuration(_ instant: VMInstantPayload, _ duration: VMDurationPayload, sign: Int64) throws -> VMInstantPayload {
        let (seconds, overflow) = duration.seconds.multipliedReportingOverflow(by: sign)
        guard !overflow else { throw arithmeticOverflow("long overflow") }
        let (millis, millisOverflow) = seconds.multipliedReportingOverflow(by: 1000)
        guard !millisOverflow else { throw arithmeticOverflow("long overflow") }
        var (sum, addOverflow) = instant.epochMilli.addingReportingOverflow(millis)
        guard !addOverflow else { throw arithmeticOverflow("long overflow") }
        let nanoDelta = Int64(duration.nanos) * sign
        var total = Int64(instant.nano) + nanoDelta
        let carry = total / 1_000_000
        total %= 1_000_000
        if total < 0 {
            total += 1_000_000
            (sum, addOverflow) = sum.addingReportingOverflow(carry - 1)
        } else {
            (sum, addOverflow) = sum.addingReportingOverflow(carry)
        }
        guard !addOverflow else { throw arithmeticOverflow("long overflow") }
        return VMInstantPayload(epochMilli: sum, nano: Int32(total))
    }

    /// ISO-8601 instant: `yyyy-MM-ddTHH:mm:ss[.fffffffff](Z|+HH:MM)`.
    static func parseInstant(_ text: String) -> VMInstantPayload? {
        guard let fields = parseDetailed(text, pattern: "yyyy-MM-dd'T'HH:mm:ss[.SSSSSSSSS]XXX") else { return nil }
        let offsetSeconds = fields.offsetSeconds ?? 0
        let millis = localEpochMilli(fields.local) - Int64(offsetSeconds) * 1000
        return VMInstantPayload(epochMilli: millis, nano: Int32(fields.local.nano % 1_000_000))
    }


    static func epochMilli(_ local: VMLocalDateTimePayload, zone: VMZonePayload) -> Int64 {
        resolveLocal(local, zone: zone).epochMilli
    }

    static func localFromDate(_ date: Date, zone: VMZonePayload) -> VMLocalDateTimePayload {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = foundationTimeZone(zone)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        return VMLocalDateTimePayload(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1,
            hour: components.hour ?? 0,
            minute: components.minute ?? 0,
            second: components.second ?? 0,
            nano: components.nanosecond ?? 0
        )
    }

    // MARK: - Formatter patterns

    static func formatterPattern(_ payload: VMDateTimeFormatterPayload?) -> String {
        guard let payload else { return "yyyy-MM-dd" }
        if let style = payload.localizedDateStyle {
            return localizedDatePattern(style, language: payload.language)
        }
        return payload.pattern
    }

    /// CLDR short/medium/long/full date skeletons for the locales extensions
    /// run under; the JDK's `ofLocalizedDate` uses the same shapes.
    static func localizedDatePattern(_ style: String, language: String) -> String {
        switch language {
        case "ja":
            switch style {
            case "FULL", "LONG": return "y年M月d日"
            case "MEDIUM": return "y/MM/dd"
            default: return "y/MM/dd"
            }
        case "zh":
            switch style {
            case "FULL", "LONG": return "y年M月d日"
            case "MEDIUM": return "y-M-d"
            default: return "y/M/d"
            }
        case "ko":
            switch style {
            case "FULL", "LONG": return "y년 M월 d일"
            case "MEDIUM": return "y. M. d."
            default: return "yy. M. d."
            }
        default:
            switch style {
            case "FULL": return "EEEE, MMMM d, y"
            case "LONG": return "MMMM d, y"
            case "MEDIUM": return "MMM d, y"
            default: return "M/d/yy"
            }
        }
    }

    // MARK: - Pattern parse

    /// Parse result including the offset text the pattern consumed, which
    /// `ZonedDateTime.parse` uses when the formatter has no zone.
    struct ParsedFields {
        var local: VMLocalDateTimePayload
        var offsetSeconds: Int?
        var zoneText: String?
    }

    /// Parses `text` with a java.time pattern. Optional sections (`[yyyy]`)
    /// are attempted and rolled back, so alternatives such as
    /// `"[MMMM][MMM] d, yyyy"` match the form the site actually rendered.
    static func parse(
        _ text: String,
        pattern: String,
        zone: VMZonePayload? = nil,
        language: String = "en",
        caseInsensitive: Bool = false,
        textMaps: [VMTextMapEntry] = [],
        defaults: [String: Int64] = [:]
    ) -> VMLocalDateTimePayload? {
        parseDetailed(
            text,
            pattern: pattern,
            zone: zone,
            language: language,
            caseInsensitive: caseInsensitive,
            textMaps: textMaps,
            defaults: defaults
        )?.local
    }

    static func parseDetailed(
        _ text: String,
        pattern: String,
        zone: VMZonePayload? = nil,
        language: String = "en",
        caseInsensitive: Bool = false,
        textMaps: [VMTextMapEntry] = [],
        defaults: [String: Int64] = [:]
    ) -> ParsedFields? {
        _ = zone
        // java.time requires exact field widths; a second, lenient pass keeps
        // inputs without leading zeros working for sites that omit them.
        let tokens = Array(pattern)
        for strict in [true, false] {
            let parser = VMDateTimePatternParser(
                text: text,
                names: VMDateNames.forLanguage(language),
                caseInsensitive: caseInsensitive,
                strict: strict,
                textMaps: textMaps,
                defaults: defaults
            )
            if parser.run(tokens), let result = parser.result {
                return ParsedFields(local: result, offsetSeconds: parser.parsedOffsetSeconds, zoneText: parser.parsedZoneText)
            }
        }
        return nil
    }

    // MARK: - Pattern format

    /// Renders a date-time the way java.time does for the pattern letters the
    /// extensions use. Width controls zero padding (`d` vs `dd`) and names
    /// (`E`/`EEE` vs `EEEE`). Fields the temporal does not carry throw instead
    /// of being rendered as invented values.
    static func formatLocal(
        _ local: VMLocalDateTimePayload,
        pattern: String,
        zone: VMZonePayload? = nil,
        hasDate: Bool = true,
        hasTime: Bool = true,
        names: VMDateNames = .english,
        textMaps: [VMTextMapEntry] = []
    ) throws -> String {
        let tokens = Array(pattern)
        var output = ""
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if let scalar = token.unicodeScalars.first, token.unicodeScalars.count == 1,
               scalar.value >= 0xE001, scalar.value <= 0xE0FF {
                let mapIndex = Int(scalar.value - 0xE000) - 1
                if mapIndex >= 0, mapIndex < textMaps.count {
                    let entry = textMaps[mapIndex]
                    guard let text = customTextValue(entry, local: local) else {
                        throw VMJavaException("Ljava/time/DateTimeException;", "Unable to obtain text for \(entry.field)")
                    }
                    output += text
                }
                index += 1
                continue
            }
            if token == "'" {
                index += 1
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
                try require(hasDate, pattern)
                let year = length == 2 ? local.year % 100 : local.year
                output += length == 2 ? String(format: "%02d", year) : String(format: "%0\(max(4, length))d", year)
            case "M", "L":
                try require(hasDate, pattern)
                let month = max(1, min(12, local.month))
                if length == 1 {
                    output += String(month)
                } else if length == 2 {
                    output += String(format: "%02d", month)
                } else if length == 3 {
                    output += names.monthsShort[month - 1]
                } else if length == 4 {
                    output += names.monthsFull[month - 1]
                } else {
                    output += String(names.monthsFull[month - 1].prefix(1)).uppercased()
                }
            case "d":
                try require(hasDate, pattern)
                output += padded(local.day, length)
            case "E", "e", "c":
                try require(hasDate, pattern)
                output += weekdayName(names: names, weekdayIndex(local), length: length)
            case "H":
                try require(hasTime, pattern)
                output += padded(local.hour, length)
            case "k":
                try require(hasTime, pattern)
                output += padded(local.hour == 0 ? 24 : local.hour, length)
            case "h":
                try require(hasTime, pattern)
                output += padded(local.hour % 12 == 0 ? 12 : local.hour % 12, length)
            case "K":
                try require(hasTime, pattern)
                output += padded(local.hour % 12, length)
            case "m":
                try require(hasTime, pattern)
                output += padded(local.minute, length)
            case "s":
                try require(hasTime, pattern)
                output += padded(local.second, length)
            case "S":
                try require(hasTime, pattern)
                let digits = max(1, min(9, length))
                output += String(format: "%0\(digits)d", local.nano / Int(pow(10, Double(9 - digits))))
            case "a":
                try require(hasTime, pattern)
                output += local.hour < 12 ? names.am : names.pm
            case "Z":
                guard let zone else { throw unsupported(pattern) }
                if length >= 4 {
                    output += zone.secondsFromGMT == 0 ? "GMT" : "GMT" + offsetId(zone.secondsFromGMT)
                } else {
                    output += compactOffset(zone.secondsFromGMT)
                }
            case "X", "x":
                guard let zone else { throw unsupported(pattern) }
                output += offsetText(zone.secondsFromGMT, length: length, zeroIsZ: token == "X")
            case "z":
                guard let zone else { throw unsupported(pattern) }
                output += zone.id
            case "O":
                guard let zone else { throw unsupported(pattern) }
                output += zone.secondsFromGMT == 0 ? "GMT" : "GMT" + offsetId(zone.secondsFromGMT)
            default:
                output += String(repeating: token, count: length)
            }
            index += length
        }
        return output
    }

    private static func require(_ available: Bool, _ pattern: String) throws {
        if !available { throw unsupported(pattern) }
    }

    /// Numeric field value used to look up an `appendText(..., map)` entry.
    static func customFieldValue(_ field: String, local: VMLocalDateTimePayload) -> Int64? {
        switch field {
        case "MONTH_OF_YEAR": return Int64(local.month)
        case "DAY_OF_MONTH": return Int64(local.day)
        case "YEAR", "YEAR_OF_ERA": return Int64(local.year)
        case "HOUR_OF_DAY": return Int64(local.hour)
        case "MINUTE_OF_HOUR": return Int64(local.minute)
        case "SECOND_OF_MINUTE": return Int64(local.second)
        case "NANO_OF_SECOND": return Int64(local.nano)
        case "DAY_OF_WEEK":
            let days = JavaTextRuntime.daysFromCivil(local.year, local.month, local.day)
            return Int64(((days + 3) % 7 + 7) % 7 + 1)
        case "DAY_OF_YEAR":
            return Int64(JavaTextRuntime.daysFromCivil(local.year, local.month, local.day)
                - JavaTextRuntime.daysFromCivil(local.year, 1, 1) + 1)
        default:
            return nil
        }
    }

    static func customTextValue(_ entry: VMTextMapEntry, local: VMLocalDateTimePayload) -> String? {
        guard let value = customFieldValue(entry.field, local: local) else { return nil }
        return entry.values[value]
    }

    private static func unsupported(_ pattern: String) -> VMJavaException {
        VMJavaException(
            "Ljava/time/temporal/UnsupportedTemporalTypeException;",
            "pattern \(pattern) requires a field the temporal does not have"
        )
    }

    static func padded(_ value: Int, _ length: Int) -> String {
        String(format: "%0\(max(1, length))d", value)
    }

    /// Monday-based weekday index for the date.
    static func weekdayIndex(_ local: VMLocalDateTimePayload) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = local.year
        components.month = local.month
        components.day = local.day
        guard let date = calendar.date(from: components) else { return 0 }
        // Calendar weekdays start at Sunday.
        return (calendar.component(.weekday, from: date) + 5) % 7
    }

    static func weekdayName(names: VMDateNames, _ index: Int, length: Int) -> String {
        // `index` is Monday-based; the name tables start on Sunday.
        let sundayIndex = (max(0, min(6, index)) + 1) % 7
        if length >= 5 { return String(names.weekdaysFull[sundayIndex].prefix(1)) }
        if length == 4 { return names.weekdaysFull[sundayIndex] }
        return names.weekdaysShort[sundayIndex]
    }

    static func compactOffset(_ seconds: Int) -> String {
        if seconds == 0 { return "+0000" }
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        return String(format: "%@%02d%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
    }

    static func offsetText(_ seconds: Int, length: Int, zeroIsZ: Bool) -> String {
        if seconds == 0, zeroIsZ { return "Z" }
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        let hours = magnitude / 3600
        let minutes = (magnitude % 3600) / 60
        let extraSeconds = magnitude % 60
        switch length {
        case 1:
            return minutes == 0 && extraSeconds == 0
                ? String(format: "%@%02d", sign, hours)
                : String(format: "%@%02d%02d", sign, hours, minutes)
        case 2:
            return String(format: "%@%02d%02d", sign, hours, minutes)
        case 3:
            return String(format: "%@%02d:%02d", sign, hours, minutes)
        case 4:
            return String(format: "%@%02d%02d%02d", sign, hours, minutes, extraSeconds)
        default:
            return String(format: "%@%02d:%02d:%02d", sign, hours, minutes, extraSeconds)
        }
    }
}

extension VMRuntime {
    func dateTimeFormatter(_ value: VMValue) -> VMDateTimeFormatterPayload? {
        payload(value, as: VMDateTimeFormatterPayload.self)
    }
}

extension VMRuntime {
    func formatterBuilderPayload(_ value: VMValue) -> VMFormatterBuilderPayload? {
        payload(value, as: VMFormatterBuilderPayload.self)
    }

    func mutableFormatterBuilder(_ value: VMValue) -> VMFormatterBuilderPayload {
        if let existing: VMFormatterBuilderPayload = payload(value, as: VMFormatterBuilderPayload.self) { return existing }
        let created = VMFormatterBuilderPayload()
        setPayload(value, created)
        return created
    }
}

/// Recursive-descent matcher for java.time patterns. Optional sections are
/// matched speculatively and rolled back when their fields are absent, which
/// is how the JDK's `DateTimeFormatter` treats them.
final class VMDateTimePatternParser {
    private struct Snapshot {
        var year = 1970
        var month = 1
        var day = 1
        var hour = 0
        var minute = 0
        var second = 0
        var nano = 0
        var isPM: Bool?
        var parsedField = false
        var index = 0
        var offsetSeconds: Int?
        var zoneText: String?
    }

    private let input: [Character]
    private let names: VMDateNames
    private let caseInsensitive: Bool
    private let strict: Bool
    private let textMaps: [VMTextMapEntry]

    private var index = 0
    private var year = 1970
    private var month = 1
    private var day = 1
    private var hour = 0
    private var minute = 0
    private var second = 0
    private var nano = 0
    private var isPM: Bool?
    private var parsedField = false
    /// Offset and zone text consumed by `Z`/`X`/`x`/`z`/`O` patterns.
    private(set) var parsedOffsetSeconds: Int?
    private(set) var parsedZoneText: String?

    init(
        text: String,
        names: VMDateNames,
        caseInsensitive: Bool,
        strict: Bool,
        textMaps: [VMTextMapEntry] = [],
        defaults: [String: Int64] = [:]
    ) {
        self.input = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        self.names = names
        self.caseInsensitive = caseInsensitive
        self.strict = strict
        self.textMaps = textMaps
        if let value = defaults["YEAR"] { year = Int(value) }
        if let value = defaults["YEAR_OF_ERA"] { year = Int(value) }
        if let value = defaults["MONTH_OF_YEAR"] { month = Int(value) }
        if let value = defaults["DAY_OF_MONTH"] { day = Int(value) }
        if let value = defaults["HOUR_OF_DAY"] { hour = Int(value) }
        if let value = defaults["MINUTE_OF_HOUR"] { minute = Int(value) }
        if let value = defaults["SECOND_OF_MINUTE"] { second = Int(value) }
        if let value = defaults["NANO_OF_SECOND"] { nano = Int(value) }
    }

    var result: VMLocalDateTimePayload? {
        guard parsedField else { return nil }
        var hourValue = hour
        if let isPM {
            if isPM, hourValue < 12 { hourValue += 12 }
            if !isPM, hourValue == 12 { hourValue = 0 }
        }
        return VMLocalDateTimePayload(
            year: year, month: month, day: day,
            hour: hourValue, minute: minute, second: second, nano: nano
        )
    }

    func run(_ tokens: [Character]) -> Bool {
        run(tokens, 0, tokens.count)
    }

    // MARK: - Matching primitives

    private var remaining: String { String(input[index...]) }

    private func readNumber(_ maxDigits: Int, minDigits: Int = 1) -> Int? {
        var count = 0
        var value = 0
        while index < input.count, count < maxDigits, input[index].isNumber {
            value = value * 10 + (Int(String(input[index])) ?? 0)
            index += 1
            count += 1
        }
        return count < minDigits ? nil : value
    }

    private func matchMonthName() -> Int? {
        let rest = remaining.lowercased()
        var best: (value: Int, length: Int)?
        func consider(_ candidates: [String]) {
            for (offset, name) in candidates.enumerated() {
                let needle = name.lowercased()
                guard !needle.isEmpty, rest.hasPrefix(needle) else { continue }
                if best == nil || needle.count > best!.length { best = (offset + 1, needle.count) }
            }
        }
        consider(names.monthsFull)
        consider(names.monthsShort)
        if names.language != "en" {
            consider(VMDateNames.english.monthsFull)
            consider(VMDateNames.english.monthsShort)
        }
        guard let best else { return nil }
        index += best.length
        if index < input.count, input[index] == "." { index += 1 }
        return best.value
    }

    private func matchWeekdayName() -> Bool {
        let rest = remaining.lowercased()
        var bestLength = 0
        for name in names.weekdaysFull + names.weekdaysShort + VMDateNames.english.weekdaysFull + VMDateNames.english.weekdaysShort {
            let needle = name.lowercased()
            guard !needle.isEmpty, rest.hasPrefix(needle) else { continue }
            bestLength = max(bestLength, needle.count)
        }
        if bestLength == 0 {
            var consumed = 0
            while index + consumed < input.count, input[index + consumed].isLetter || input[index + consumed] == "." {
                consumed += 1
            }
            guard consumed > 0 else { return false }
            index += consumed
            return true
        }
        index += bestLength
        if index < input.count, input[index] == "." { index += 1 }
        return true
    }

    /// Matches one of an `appendText(field, map)` entry's names and records the
    /// mapped field value. Longest match wins, as the JDK's text-printer does.
    private func matchCustomText(_ entry: VMTextMapEntry) -> Bool {
        let rest = remaining
        var best: (value: Int64, length: Int)?
        for (value, text) in entry.values {
            guard !text.isEmpty else { continue }
            let matched = caseInsensitive
                ? rest.lowercased().hasPrefix(text.lowercased())
                : rest.hasPrefix(text)
            if matched, best == nil || text.count > best!.length { best = (value, text.count) }
        }
        guard let best else { return false }
        index += best.length
        applyField(entry.field, value: best.value)
        return true
    }

    private func applyField(_ field: String, value: Int64) {
        switch field {
        case "MONTH_OF_YEAR": month = Int(value)
        case "DAY_OF_MONTH": day = Int(value)
        case "YEAR", "YEAR_OF_ERA": year = Int(value)
        case "HOUR_OF_DAY": hour = Int(value)
        case "MINUTE_OF_HOUR": minute = Int(value)
        case "SECOND_OF_MINUTE": second = Int(value)
        case "NANO_OF_SECOND": nano = Int(value)
        default: break
        }
        parsedField = true
    }

    private func matchAmPM() -> Bool? {
        var word = ""
        while index < input.count {
            let character = input[index]
            if character.isLetter || character == "." {
                word.append(character)
                index += 1
            } else if character == " ", index + 1 < input.count, input[index + 1].isLetter {
                word.append(character)
                index += 1
            } else {
                break
            }
            if let marker = markerValue(JavaTextRuntime.normalizeWord(word)) { return marker }
        }
        return nil
    }

    private func markerValue(_ cleaned: String) -> Bool? {
        guard !cleaned.isEmpty else { return nil }
        let pm = JavaTextRuntime.normalizeWord(names.pm)
        let am = JavaTextRuntime.normalizeWord(names.am)
        if cleaned == pm || cleaned == "pm" || cleaned == "p" { return true }
        if cleaned == am || cleaned == "am" || cleaned == "a" { return false }
        return nil
    }

    private func skipOffset() -> Bool {
        let save = index
        guard index < input.count else { return false }
        if input[index] == "Z" || input[index] == "z" {
            index += 1
            parsedOffsetSeconds = 0
            return true
        }
        if input[index] == "+" || input[index] == "-" {
            return readOffsetTail()
        }
        var word = ""
        while index < input.count, input[index].isLetter || input[index] == "/" || input[index] == "_" {
            word.append(input[index])
            index += 1
        }
        if word.isEmpty {
            index = save
            return false
        }
        let upper = word.uppercased()
        if upper == "GMT" || upper == "UTC" || upper == "UT" {
            parsedZoneText = upper
            parsedOffsetSeconds = 0
            if index < input.count, input[index] == "+" || input[index] == "-" {
                return readOffsetTail()
            }
            return true
        }
        parsedZoneText = word
        return true
    }

    /// Reads `+HH`, `+HHMM`, `+HH:MM` or `+HH:MM:SS` starting at the sign.
    private func readOffsetTail() -> Bool {
        let save = index
        let sign = input[index] == "-" ? -1 : 1
        index += 1
        guard let hours = readNumber(2) else {
            index = save
            return false
        }
        var minutes = 0
        var seconds = 0
        if index < input.count, input[index] == ":" {
            index += 1
            minutes = readNumber(2) ?? 0
            if index < input.count, input[index] == ":" {
                index += 1
                seconds = readNumber(2) ?? 0
            }
        } else if index < input.count, input[index].isNumber {
            minutes = readNumber(2) ?? 0
        }
        parsedOffsetSeconds = sign * (hours * 3600 + minutes * 60 + seconds)
        return true
    }

    private func save() -> Snapshot {
        Snapshot(
            year: year, month: month, day: day, hour: hour, minute: minute,
            second: second, nano: nano, isPM: isPM, parsedField: parsedField, index: index,
            offsetSeconds: parsedOffsetSeconds, zoneText: parsedZoneText
        )
    }

    private func restore(_ snapshot: Snapshot) {
        year = snapshot.year
        month = snapshot.month
        day = snapshot.day
        hour = snapshot.hour
        minute = snapshot.minute
        second = snapshot.second
        nano = snapshot.nano
        isPM = snapshot.isPM
        parsedField = snapshot.parsedField
        index = snapshot.index
        parsedOffsetSeconds = snapshot.offsetSeconds
        parsedZoneText = snapshot.zoneText
    }

    // MARK: - Pattern walk

    private func run(_ tokens: [Character], _ start: Int, _ end: Int) -> Bool {
        var tokenIndex = start
        while tokenIndex < end {
            let token = tokens[tokenIndex]
            if let scalar = token.unicodeScalars.first, token.unicodeScalars.count == 1,
               scalar.value >= 0xE001, scalar.value <= 0xE0FF {
                let mapIndex = Int(scalar.value - 0xE000) - 1
                guard mapIndex >= 0, mapIndex < textMaps.count, matchCustomText(textMaps[mapIndex]) else { return false }
                tokenIndex += 1
                continue
            }
            if token == "[" {
                var depth = 1
                var close = tokenIndex + 1
                while close < end {
                    if tokens[close] == "[" {
                        depth += 1
                    } else if tokens[close] == "]" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    close += 1
                }
                guard close < end else { return false }
                let snapshot = save()
                if !run(tokens, tokenIndex + 1, close) { restore(snapshot) }
                tokenIndex = close + 1
                continue
            }
            if token == "]" { return false }
            if token == "'" {
                tokenIndex += 1
                if tokenIndex < end, tokens[tokenIndex] == "'" {
                    guard index < input.count, input[index] == "'" else { return false }
                    index += 1
                    tokenIndex += 1
                    continue
                }
                while tokenIndex < end, tokens[tokenIndex] != "'" {
                    guard index < input.count, matches(input[index], tokens[tokenIndex]) else { return false }
                    index += 1
                    tokenIndex += 1
                }
                tokenIndex += 1
                continue
            }
            if !token.isLetter {
                guard index < input.count, matches(input[index], token) else { return false }
                index += 1
                tokenIndex += 1
                continue
            }
            var length = 1
            while tokenIndex + length < end, tokens[tokenIndex + length] == token { length += 1 }
            switch token {
            case "y", "u":
                let maxDigits = length == 1 ? 4 : length
                let minDigits = strict ? (length == 1 ? 1 : length) : 1
                guard let value = readNumber(maxDigits, minDigits: minDigits) else { return false }
                year = (length == 2 && value < 100) ? 2000 + value : value
                parsedField = true
            case "M", "L":
                if length >= 3 {
                    guard let value = matchMonthName() else { return false }
                    month = value
                } else {
                    guard let value = readNumber(2, minDigits: strict ? length : 1) else { return false }
                    month = value
                }
                parsedField = true
            case "d":
                guard let value = readNumber(2, minDigits: strict ? length : 1) else { return false }
                day = value
                parsedField = true
            case "D":
                guard let value = readNumber(3) else { return false }
                let civil = JavaTextRuntime.civilFromDays(JavaTextRuntime.daysFromCivil(year, 1, 1) + value - 1)
                month = civil.month
                day = civil.day
                parsedField = true
            case "H":
                guard let value = readNumber(2, minDigits: strict ? length : 1) else { return false }
                hour = value
                parsedField = true
            case "h":
                guard let value = readNumber(2, minDigits: strict ? length : 1) else { return false }
                hour = value
                parsedField = true
            case "K":
                guard let value = readNumber(2, minDigits: strict ? length : 1) else { return false }
                hour = value
                parsedField = true
            case "k":
                guard let value = readNumber(2, minDigits: strict ? length : 1) else { return false }
                hour = value == 24 ? 0 : value
                parsedField = true
            case "m":
                guard let value = readNumber(2, minDigits: strict ? length : 1) else { return false }
                minute = value
                parsedField = true
            case "s":
                guard let value = readNumber(2, minDigits: strict ? length : 1) else { return false }
                second = value
                parsedField = true
            case "S":
                let fractionStart = index
                guard let fraction = readNumber(9) else { return false }
                let digits = max(1, min(9, index - fractionStart))
                nano = fraction * Int(pow(10, Double(9 - digits)))
                parsedField = true
            case "a":
                guard let marker = matchAmPM() else { return false }
                isPM = marker
                parsedField = true
            case "E", "e", "c":
                guard matchWeekdayName() else { return false }
            case "G":
                var word = ""
                while index < input.count, input[index].isLetter {
                    word.append(input[index])
                    index += 1
                }
                guard !word.isEmpty else { return false }
            case "Z", "X", "x", "z", "O":
                guard skipOffset() else { return false }
            case "w", "W":
                guard readNumber(2) != nil else { return false }
            default:
                return false
            }
            tokenIndex += length
        }
        return true
    }

    private func matches(_ character: Character, _ expected: Character) -> Bool {
        if character == expected { return true }
        guard caseInsensitive else { return false }
        return String(character).lowercased() == String(expected).lowercased()
    }
}
