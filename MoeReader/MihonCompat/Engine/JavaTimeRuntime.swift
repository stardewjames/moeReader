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

final class VMDateTimeFormatterPayload {
    var pattern: String
    var zone: VMZonePayload?
    var language: String
    var caseInsensitive: Bool
    init(pattern: String, zone: VMZonePayload? = nil, language: String = "en", caseInsensitive: Bool = false) {
        self.pattern = pattern
        self.zone = zone
        self.language = language
        self.caseInsensitive = caseInsensitive
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
    let epochMilli: Int64
    init(epochMilli: Int64) { self.epochMilli = epochMilli }
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
        result.append(marker("Ljava/time/temporal/TemporalAccessor;"))
        result.append(marker("Ljava/time/temporal/Temporal;"))
        result.append(marker("Ljava/time/chrono/ChronoZonedDateTime;", interfaces: ["Ljava/time/temporal/Temporal;"]))
        result.append(marker("Ljava/time/chrono/ChronoLocalDateTime;"))
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
            runtime.makeNative("Ljava/time/ZoneOffset;", payload: VMZonePayload(id: offsetId(Int(args[0].asInt32)), secondsFromGMT: Int(args[0].asInt32)))
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
        cls.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(pattern: "yyyy-MM-dd"))
            cls.staticValues[1] = runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(pattern: "yyyy-MM-dd'T'HH:mm:ss"))
            cls.staticValues[2] = runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(pattern: "yyyy-MM-dd'T'HH:mm:ss"))
        }
        cls.staticMethod("ofPattern", "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatter;") { runtime, args, _ in
            runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(pattern: runtime.stringValue(args[0]) ?? ""))
        }
        cls.staticMethod("ofPattern", "(Ljava/lang/String;Ljava/util/Locale;)Ljava/time/format/DateTimeFormatter;") { runtime, args, _ in
            runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(
                pattern: runtime.stringValue(args[0]) ?? "",
                language: JavaTextRuntime.localeLanguage(runtime, args[1])
            ))
        }
        cls.method("withLocale", "(Ljava/util/Locale;)Ljava/time/format/DateTimeFormatter;") { runtime, args, _ in
            let source: VMDateTimeFormatterPayload? = runtime.payload(args[0], as: VMDateTimeFormatterPayload.self)
            return runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(
                pattern: source?.pattern ?? "",
                zone: source?.zone,
                language: JavaTextRuntime.localeLanguage(runtime, args[1]),
                caseInsensitive: source?.caseInsensitive ?? false
            ))
        }
        cls.method("getLocale", "()Ljava/util/Locale;") { runtime, args, _ in
            let source: VMDateTimeFormatterPayload? = runtime.payload(args[0], as: VMDateTimeFormatterPayload.self)
            return runtime.localeValue(code: source?.language ?? "en")
        }
        cls.method("withZone", "(Ljava/time/ZoneId;)Ljava/time/format/DateTimeFormatter;") { runtime, args, _ in
            let source: VMDateTimeFormatterPayload? = runtime.payload(args[0], as: VMDateTimeFormatterPayload.self)
            let zone: VMZonePayload? = runtime.payload(args[1], as: VMZonePayload.self)
            return runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(pattern: source?.pattern ?? "", zone: zone ?? utc))
        }
        cls.method("getZone", "()Ljava/time/ZoneId;") { runtime, args, _ in
            let source: VMDateTimeFormatterPayload? = runtime.payload(args[0], as: VMDateTimeFormatterPayload.self)
            guard let zone = source?.zone else { return .null }
            return runtime.makeNative("Ljava/time/ZoneId;", payload: zone)
        }
        cls.method("format", "(Ljava/time/temporal/TemporalAccessor;)Ljava/lang/String;") { runtime, args, _ in
            let source: VMDateTimeFormatterPayload? = runtime.payload(args[0], as: VMDateTimeFormatterPayload.self)
            let names = VMDateNames.forLanguage(source?.language ?? "en")
            let pattern = source?.pattern ?? "yyyy-MM-dd"
            let formatterZone = source.flatMap { $0.zone }
            let temporal = args[1]
            if let local: VMLocalDateTimePayload = runtime.payload(temporal, as: VMLocalDateTimePayload.self) {
                return runtime.newString(try formatLocal(local, pattern: pattern, zone: formatterZone.map { resolvedZone(local, zone: $0) }, names: names))
            }
            if let date: VMLocalDatePayload = runtime.payload(temporal, as: VMLocalDatePayload.self) {
                let local = VMLocalDateTimePayload(year: date.year, month: date.month, day: date.day)
                return runtime.newString(try formatLocal(local, pattern: pattern, zone: formatterZone.map { resolvedZone(local, zone: $0) }, hasTime: false, names: names))
            }
            if let zoned: VMZonedDateTimePayload = runtime.payload(temporal, as: VMZonedDateTimePayload.self) {
                let local = zoned.local
                let zone = formatterZone.map { resolvedZone(local, zone: $0) } ?? resolvedZone(local, zone: zoned.zone)
                return runtime.newString(try formatLocal(local, pattern: pattern, zone: zone, names: names))
            }
            if let offsetDateTime: VMOffsetDateTimePayload = runtime.payload(temporal, as: VMOffsetDateTimePayload.self) {
                let local = offsetDateTime.local
                let zone = formatterZone.map { resolvedZone(local, zone: $0) } ?? offsetDateTime.offset
                return runtime.newString(try formatLocal(local, pattern: pattern, zone: zone, names: names))
            }
            if let time: VMLocalTimePayload = runtime.payload(temporal, as: VMLocalTimePayload.self) {
                let local = VMLocalDateTimePayload(hour: time.hour, minute: time.minute, second: time.second, nano: time.nano)
                // LocalTime has no offset field in java.time.
                return runtime.newString(try formatLocal(local, pattern: pattern, hasDate: false, names: names))
            }
            if let instant: VMInstantPayload = runtime.payload(temporal, as: VMInstantPayload.self) {
                let date = Date(timeIntervalSince1970: Double(instant.epochMilli) / 1000)
                // java.time formats instants by projecting through the override
                // zone, falling back to the system default zone.
                let zone = formatterZone.map { adjustZone($0, at: date) } ?? systemDefaultZone(for: date)
                return runtime.newString(try formatLocal(localFromDate(date, zone: zone), pattern: pattern, zone: zone))
            }
            throw VMJavaException("Ljava/time/temporal/UnsupportedTemporalTypeException;", "unsupported temporal")
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let source: VMDateTimeFormatterPayload? = runtime.payload(args[0], as: VMDateTimeFormatterPayload.self)
            return runtime.newString(source?.pattern ?? "")
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
            guard let parsed = parse(text, pattern: formatter?.pattern ?? "yyyy-MM-dd'T'HH:mm:ss", zone: formatter?.zone, language: formatter?.language ?? "en", caseInsensitive: formatter?.caseInsensitive ?? false) else {
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
            let shifted = JavaTextRuntime.civilFromDays(
                JavaTextRuntime.daysFromCivil(local.year, local.month, local.day) - Int(args[1].asInt64)
            )
            let copy = local.copy()
            copy.year = shifted.year
            copy.month = shifted.month
            copy.day = shifted.day
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: copy)
        }
        cls.method("plusDays", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            let shifted = JavaTextRuntime.civilFromDays(
                JavaTextRuntime.daysFromCivil(local.year, local.month, local.day) + Int(args[1].asInt64)
            )
            let copy = local.copy()
            copy.year = shifted.year
            copy.month = shifted.month
            copy.day = shifted.day
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: copy)
        }
        cls.method("minusHours", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            try shiftLocalDateTime(runtime, args: args, seconds: -Int(args[1].asInt64) * 3600)
        }
        cls.method("plusHours", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            try shiftLocalDateTime(runtime, args: args, seconds: Int(args[1].asInt64) * 3600)
        }
        cls.method("minusMinutes", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            try shiftLocalDateTime(runtime, args: args, seconds: -Int(args[1].asInt64) * 60)
        }
        cls.method("plusMinutes", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            try shiftLocalDateTime(runtime, args: args, seconds: Int(args[1].asInt64) * 60)
        }
        cls.method("minusSeconds", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            try shiftLocalDateTime(runtime, args: args, seconds: -Int(args[1].asInt64))
        }
        cls.method("plusSeconds", "(J)Ljava/time/LocalDateTime;") { runtime, args, _ in
            try shiftLocalDateTime(runtime, args: args, seconds: Int(args[1].asInt64))
        }
        cls.method("truncatedTo", "(Ljava/time/temporal/TemporalUnit;)Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            let unit = runtime.payload(args[1], as: VMChronoUnitPayload.self)?.name ?? "NANOS"
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
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: copy)
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
            runtime.makeNative("Ljava/time/LocalDateTime;", payload: VMLocalDateTimePayload(
                year: Int(args[0].asInt32), month: Int(args[1].asInt32), day: Int(args[2].asInt32),
                hour: Int(args[3].asInt32), minute: Int(args[4].asInt32), second: Int(args[5].asInt32)
            ))
        }
        cls.method("atZone", "(Ljava/time/ZoneId;)Ljava/time/ZonedDateTime;") { runtime, args, _ in
            let local: VMLocalDateTimePayload? = runtime.payload(args[0], as: VMLocalDateTimePayload.self)
            let zone: VMZonePayload? = runtime.payload(args[1], as: VMZonePayload.self)
            guard let local else { return .null }
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: VMZonedDateTimePayload(local: local.copy(), zone: zone ?? utc))
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
            return runtime.newString(try formatLocal(local, pattern: formatter?.pattern ?? "yyyy-MM-dd'T'HH:mm:ss", zone: overrideZone.map { resolvedZone(local, zone: $0) }))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.newString(try formatLocal(local, pattern: "yyyy-MM-dd'T'HH:mm:ss"))
        }
        return cls
    }

    private static func localDateClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/LocalDate;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/time/temporal/TemporalAccessor;"])
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
            guard let parsed = parse(text, pattern: formatter?.pattern ?? "yyyy-MM-dd", language: formatter?.language ?? "en", caseInsensitive: formatter?.caseInsensitive ?? false) else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", text)
            }
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: parsed.year, month: parsed.month, day: parsed.day))
        }
        cls.staticMethod("now", "()Ljava/time/LocalDate;") { runtime, _, _ in
            let local = localFromDate(Date(), zone: systemDefaultZone())
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: local.year, month: local.month, day: local.day))
        }
        cls.method("atStartOfDay", "()Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: VMLocalDateTimePayload(year: date.year, month: date.month, day: date.day))
        }
        cls.method("atStartOfDay", "(Ljava/time/ZoneId;)Ljava/time/ZonedDateTime;") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
            let zone: VMZonePayload? = runtime.payload(args[1], as: VMZonePayload.self)
            let local = VMLocalDateTimePayload(year: date.year, month: date.month, day: date.day)
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: VMZonedDateTimePayload(local: local, zone: zone ?? utc))
        }
        cls.method("getYear", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalDatePayload.self) ?? VMLocalDatePayload()).year)) }
        cls.method("getMonthValue", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalDatePayload.self) ?? VMLocalDatePayload()).month)) }
        cls.method("getDayOfMonth", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMLocalDatePayload.self) ?? VMLocalDatePayload()).day)) }
        cls.method("minusDays", "(J)Ljava/time/LocalDate;") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var components = DateComponents()
            components.year = date.year; components.month = date.month; components.day = date.day
            let shifted = calendar.date(byAdding: .day, value: -Int(args[1].asInt64), to: calendar.date(from: components) ?? Date()) ?? Date()
            let result = calendar.dateComponents([.year, .month, .day], from: shifted)
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: result.year ?? 1970, month: result.month ?? 1, day: result.day ?? 1))
        }
        cls.method("plusDays", "(J)Ljava/time/LocalDate;") { runtime, args, _ in
            guard let date: VMLocalDatePayload = runtime.payload(args[0], as: VMLocalDatePayload.self) else { return .null }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var components = DateComponents()
            components.year = date.year; components.month = date.month; components.day = date.day
            let shifted = calendar.date(byAdding: .day, value: Int(args[1].asInt64), to: calendar.date(from: components) ?? Date()) ?? Date()
            let result = calendar.dateComponents([.year, .month, .day], from: shifted)
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: result.year ?? 1970, month: result.month ?? 1, day: result.day ?? 1))
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
            return runtime.newString(try formatLocal(local, pattern: formatter?.pattern ?? "yyyy-MM-dd", zone: overrideZone.map { resolvedZone(local, zone: $0) }, hasTime: false))
        }
        return cls
    }

    private static func localTimeClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/LocalTime;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/time/temporal/TemporalAccessor;"])
        cls.staticMethod("now", "()Ljava/time/LocalTime;") { runtime, _, _ in
            let local = localFromDate(Date(), zone: systemDefaultZone())
            return runtime.makeNative("Ljava/time/LocalTime;", payload: VMLocalTimePayload(hour: local.hour, minute: local.minute, second: local.second, nano: local.nano))
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
            return runtime.newString(try formatLocal(local, pattern: formatter?.pattern ?? "HH:mm:ss", hasDate: false))
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
        cls.method("getZone", "()Ljava/time/ZoneId;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/ZoneId;", payload: zoned.zone)
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
                guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .int32(0) }
                return .int32(Int32(get(zoned.local)))
            }
        }
        cls.method("format", "(Ljava/time/format/DateTimeFormatter;)Ljava/lang/String;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            let formatter: VMDateTimeFormatterPayload? = runtime.payload(args[1], as: VMDateTimeFormatterPayload.self)
            let overrideZone = formatter.flatMap { $0.zone }
            let zone = overrideZone.map { resolvedZone(zoned.local, zone: $0) } ?? resolvedZone(zoned.local, zone: zoned.zone)
            return runtime.newString(try formatLocal(zoned.local, pattern: formatter?.pattern ?? "yyyy-MM-dd'T'HH:mm:ss", zone: zone))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            let zone = resolvedZone(zoned.local, zone: zoned.zone)
            let body = try formatLocal(zoned.local, pattern: "yyyy-MM-dd'T'HH:mm:ss", zone: zone)
            return runtime.newString(body + zoneSuffix(zone))
        }
        return cls
    }

    private static func offsetDateTimeClass() -> NativeClass {
        let cls = NativeClass("Ljava/time/OffsetDateTime;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/time/temporal/TemporalAccessor;", "Ljava/time/temporal/Temporal;"])
        cls.staticMethod("now", "()Ljava/time/OffsetDateTime;") { runtime, _, _ in
            let zone = systemDefaultZone()
            return runtime.makeNative("Ljava/time/OffsetDateTime;", payload: VMOffsetDateTimePayload(local: localFromDate(Date(), zone: zone), offset: zone))
        }
        cls.staticMethod("of", "(Ljava/time/LocalDateTime;Ljava/time/ZoneOffset;)Ljava/time/OffsetDateTime;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self),
                  let offset: VMZonePayload = runtime.payload(args[1], as: VMZonePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/OffsetDateTime;", payload: VMOffsetDateTimePayload(local: local.copy(), offset: offset))
        }
        cls.method("toLocalDateTime", "()Ljava/time/LocalDateTime;") { runtime, args, _ in
            guard let value: VMOffsetDateTimePayload = runtime.payload(args[0], as: VMOffsetDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: value.local.copy())
        }
        cls.method("toInstant", "()Ljava/time/Instant;") { runtime, args, _ in
            guard let value: VMOffsetDateTimePayload = runtime.payload(args[0], as: VMOffsetDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/Instant;", payload: VMInstantPayload(epochMilli: epochMilli(value.local, zone: value.offset)))
        }
        cls.method("getOffset", "()Ljava/time/ZoneOffset;") { runtime, args, _ in
            guard let value: VMOffsetDateTimePayload = runtime.payload(args[0], as: VMOffsetDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/ZoneOffset;", payload: value.offset)
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
            return runtime.newString(try formatLocal(value.local, pattern: formatter?.pattern ?? "yyyy-MM-dd'T'HH:mm:ss", zone: overrideZone.map { resolvedZone(value.local, zone: $0) } ?? value.offset))
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
            runtime.makeNative("Ljava/time/Instant;", payload: VMInstantPayload(epochMilli: args[0].asInt64 * 1000))
        }
        cls.method("toEpochMilli", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: VMInstantPayload.self)?.epochMilli ?? 0)
        }
        cls.method("getEpochSecond", "()J") { runtime, args, _ in
            .int64((runtime.payload(args[0], as: VMInstantPayload.self)?.epochMilli ?? 0) / 1000)
        }
        cls.method("atZone", "(Ljava/time/ZoneId;)Ljava/time/ZonedDateTime;") { runtime, args, _ in
            let millis = runtime.payload(args[0], as: VMInstantPayload.self)?.epochMilli ?? 0
            let zone: VMZonePayload? = runtime.payload(args[1], as: VMZonePayload.self)
            let local = localFromDate(Date(timeIntervalSince1970: Double(millis) / 1000), zone: zone ?? utc)
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: VMZonedDateTimePayload(local: local, zone: zone ?? utc))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let millis = runtime.payload(args[0], as: VMInstantPayload.self)?.epochMilli ?? 0
            return runtime.newString(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(millis) / 1000)))
        }
        return cls
    }

    // MARK: - java.time enums and builders

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
        cls.method("toFormatter", "()Ljava/time/format/DateTimeFormatter;") { runtime, args, _ in
            let builder = runtime.formatterBuilderPayload(args[0]) ?? VMFormatterBuilderPayload()
            return runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(
                pattern: builder.pattern, language: "en", caseInsensitive: builder.caseInsensitive
            ))
        }
        cls.method("toFormatter", "(Ljava/util/Locale;)Ljava/time/format/DateTimeFormatter;") { runtime, args, _ in
            let builder = runtime.formatterBuilderPayload(args[0]) ?? VMFormatterBuilderPayload()
            return runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(
                pattern: builder.pattern,
                language: JavaTextRuntime.localeLanguage(runtime, args[1]),
                caseInsensitive: builder.caseInsensitive
            ))
        }
        return cls
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
        adjustZone(zone, at: Date(timeIntervalSince1970: Double(epochMilli(local, zone: zone)) / 1000))
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
        if value == "UTC" || value == "Z" || value == "GMT" { return utc }
        if value.hasPrefix("+") || value.hasPrefix("-") {
            let sign = value.hasPrefix("-") ? -1 : 1
            let body = value.dropFirst()
            let parts = body.split(separator: ":")
            let hours = Int(parts.first ?? "0") ?? 0
            let minutes = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return VMZonePayload(id: value, secondsFromGMT: sign * (hours * 3600 + minutes * 60))
        }
        if let zone = TimeZone(identifier: value) {
            return VMZonePayload(id: value, secondsFromGMT: zone.secondsFromGMT())
        }
        return utc
    }

    static func offsetId(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        return String(format: "%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
    }

    /// Wall-clock shift used by the `plus`/`minus` LocalDateTime helpers.
    static func shiftLocalDateTime(_ runtime: VMRuntime, args: UnsafePointer<VMValue>, seconds: Int) throws -> VMValue {
        guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
        let instant = JavaTextRuntime.epochMillis(
            year: local.year, month: local.month, day: local.day,
            hour: local.hour, minute: local.minute, second: local.second,
            millis: local.nano / 1_000_000
        ) + Int64(seconds) * 1000
        let days = Int(JavaTextRuntime.floorDivide(instant, 86_400_000))
        var rest = instant - Int64(days) * 86_400_000
        let civil = JavaTextRuntime.civilFromDays(days)
        let hour = Int(rest / 3_600_000)
        rest -= Int64(hour) * 3_600_000
        let minute = Int(rest / 60_000)
        rest -= Int64(minute) * 60_000
        let second = Int(rest / 1000)
        let millis = Int(rest - Int64(second) * 1000)
        let copy = VMLocalDateTimePayload(
            year: civil.year, month: civil.month, day: civil.day,
            hour: hour, minute: minute, second: second,
            nano: millis * 1_000_000 + local.nano % 1_000_000
        )
        return runtime.makeNative("Ljava/time/LocalDateTime;", payload: copy)
    }

    // MARK: - Calendar conversions

    static func epochMilli(_ local: VMLocalDateTimePayload, zone: VMZonePayload) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = foundationTimeZone(zone)
        var components = DateComponents()
        components.year = local.year
        components.month = local.month
        components.day = local.day
        components.hour = local.hour
        components.minute = local.minute
        components.second = local.second
        components.nanosecond = local.nano
        return Int64((calendar.date(from: components)?.timeIntervalSince1970 ?? 0) * 1000)
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

    // MARK: - Pattern parse

    /// Parses `text` with a java.time pattern. Optional sections (`[yyyy]`)
    /// are attempted and rolled back, so alternatives such as
    /// `"[MMMM][MMM] d, yyyy"` match the form the site actually rendered.
    static func parse(
        _ text: String,
        pattern: String,
        zone: VMZonePayload? = nil,
        language: String = "en",
        caseInsensitive: Bool = false
    ) -> VMLocalDateTimePayload? {
        _ = zone
        // java.time requires exact field widths; a second, lenient pass keeps
        // inputs without leading zeros working for sites that omit them.
        let tokens = Array(pattern)
        for strict in [true, false] {
            let parser = VMDateTimePatternParser(
                text: text,
                names: VMDateNames.forLanguage(language),
                caseInsensitive: caseInsensitive,
                strict: strict
            )
            if parser.run(tokens), let result = parser.result { return result }
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
        names: VMDateNames = .english
    ) throws -> String {
        let tokens = Array(pattern)
        var output = ""
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
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
            case "E":
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
    }

    private let input: [Character]
    private let names: VMDateNames
    private let caseInsensitive: Bool
    private let strict: Bool

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

    init(text: String, names: VMDateNames, caseInsensitive: Bool, strict: Bool) {
        self.input = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        self.names = names
        self.caseInsensitive = caseInsensitive
        self.strict = strict
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
            return true
        }
        var hasSign = false
        if input[index] == "+" || input[index] == "-" {
            hasSign = true
            index += 1
        }
        if !hasSign {
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
            if upper == "GMT" || upper == "UTC" {
                guard index < input.count, input[index] == "+" || input[index] == "-" else { return true }
                index += 1
            } else {
                return true
            }
        }
        guard readNumber(2) != nil else {
            index = save
            return false
        }
        if index < input.count, input[index] == ":" { index += 1 }
        _ = readNumber(2)
        return true
    }

    private func save() -> Snapshot {
        Snapshot(
            year: year, month: month, day: day, hour: hour, minute: minute,
            second: second, nano: nano, isPM: isPM, parsedField: parsedField, index: index
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
    }

    // MARK: - Pattern walk

    private func run(_ tokens: [Character], _ start: Int, _ end: Int) -> Bool {
        var tokenIndex = start
        while tokenIndex < end {
            let token = tokens[tokenIndex]
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
                guard let fraction = readNumber(9) else { return false }
                nano = fraction * Int(pow(10, Double(9 - max(1, min(9, length)))))
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
