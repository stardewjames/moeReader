//
//  JavaTimeRuntime.swift
//  MihonCompat
//
//  The slice of java.time extensions use for chapter dates. Parsing follows the
//  pattern the extension supplies; zones are fixed offsets (the device zone for
//  systemDefault) so no tz database is required.
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
    init(pattern: String, zone: VMZonePayload? = nil) {
        self.pattern = pattern
        self.zone = zone
    }
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

final class VMInstantPayload {
    let epochMilli: Int64
    init(epochMilli: Int64) { self.epochMilli = epochMilli }
}

enum JavaTimeRuntime {
    static let utc = VMZonePayload(id: "UTC", secondsFromGMT: 0)
    static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let monthShort = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(zoneIdClass())
        result.append(zoneOffsetClass())
        result.append(formatterClass())
        result.append(localDateTimeClass())
        result.append(localDateClass())
        result.append(zonedDateTimeClass())
        result.append(instantClass())
        result.append(marker("Ljava/time/temporal/TemporalAccessor;"))
        result.append(marker("Ljava/time/temporal/Temporal;"))
        result.append(marker("Ljava/time/chrono/ChronoZonedDateTime;", interfaces: ["Ljava/time/temporal/Temporal;"]))
        result.append(marker("Ljava/time/chrono/ChronoLocalDateTime;"))
        result.append(marker("Ljava/time/format/DateFormat;"))
        result.append(parseException())
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
            let seconds = TimeZone.current.secondsFromGMT()
            return runtime.makeNative("Ljava/time/ZoneId;", payload: VMZonePayload(id: TimeZone.current.identifier, secondsFromGMT: seconds))
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
            runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(pattern: runtime.stringValue(args[0]) ?? ""))
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
            let pattern = source?.pattern ?? "yyyy-MM-dd"
            if let local: VMLocalDateTimePayload = runtime.payload(args[1], as: VMLocalDateTimePayload.self) {
                return runtime.newString(formatLocal(local, pattern: pattern))
            }
            if let date: VMLocalDatePayload = runtime.payload(args[1], as: VMLocalDatePayload.self) {
                return runtime.newString(formatLocal(VMLocalDateTimePayload(year: date.year, month: date.month, day: date.day), pattern: pattern))
            }
            return runtime.newString("")
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
            guard let parsed = parse(text, pattern: formatter?.pattern ?? "yyyy-MM-dd'T'HH:mm:ss", zone: formatter?.zone) else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", text)
            }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: parsed)
        }
        cls.staticMethod("now", "()Ljava/time/LocalDateTime;") { runtime, _, _ in
            runtime.makeNative("Ljava/time/LocalDateTime;", payload: localFromDate(Date(), zone: utc))
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
            return runtime.makeNative("Ljava/time/ZonedDateTime;", payload: VMZonedDateTimePayload(local: local, zone: zone ?? utc))
        }
        cls.method("toLocalDate", "()Ljava/time/LocalDate;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: local.year, month: local.month, day: local.day))
        }
        cls.method("toLocalTime", "()Ljava/time/LocalTime;") { _, _, _ in .null }
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
            return runtime.newString(formatLocal(local, pattern: formatter?.pattern ?? "yyyy-MM-dd'T'HH:mm:ss"))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let local: VMLocalDateTimePayload = runtime.payload(args[0], as: VMLocalDateTimePayload.self) else { return .null }
            return runtime.newString(formatLocal(local, pattern: "yyyy-MM-dd'T'HH:mm:ss"))
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
            guard let parsed = parse(text, pattern: formatter?.pattern ?? "yyyy-MM-dd") else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", text)
            }
            return runtime.makeNative("Ljava/time/LocalDate;", payload: VMLocalDatePayload(year: parsed.year, month: parsed.month, day: parsed.day))
        }
        cls.staticMethod("now", "()Ljava/time/LocalDate;") { runtime, _, _ in
            let local = localFromDate(Date(), zone: utc)
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
            return runtime.newString(formatLocal(VMLocalDateTimePayload(year: date.year, month: date.month, day: date.day), pattern: formatter?.pattern ?? "yyyy-MM-dd"))
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
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: zoned.local)
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
            return runtime.newString(formatLocal(zoned.local, pattern: formatter?.pattern ?? "yyyy-MM-dd'T'HH:mm:ss"))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let zoned: VMZonedDateTimePayload = runtime.payload(args[0], as: VMZonedDateTimePayload.self) else { return .null }
            return runtime.newString(formatLocal(zoned.local, pattern: "yyyy-MM-dd'T'HH:mm:ss") + zoned.zone.id)
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

    private static func parseException() -> NativeClass {
        let cls = NativeClass("Ljava/time/format/DateTimeParseException;", superclass: "Ljava/lang/RuntimeException;")
        cls.method("<init>", "(Ljava/lang/String;)V") { _, _, _ in .zero }
        cls.method("<init>", "(Ljava/lang/String;Ljava/lang/CharSequence;)V") { _, _, _ in .zero }
        return cls
    }

    // MARK: - Zone helpers

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

    // MARK: - Calendar conversions

    static func epochMilli(_ local: VMLocalDateTimePayload, zone: VMZonePayload) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: zone.secondsFromGMT) ?? TimeZone(secondsFromGMT: 0)!
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
        calendar.timeZone = TimeZone(secondsFromGMT: zone.secondsFromGMT) ?? TimeZone(secondsFromGMT: 0)!
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

    static func parse(_ text: String, pattern: String, zone: VMZonePayload? = nil) -> VMLocalDateTimePayload? {
        let input = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let tokens = Array(pattern)
        var result = VMLocalDateTimePayload()
        var inputIndex = 0
        var tokenIndex = 0
        var amPM: String?

        func readNumber(_ maxDigits: Int) -> Int? {
            var digits = ""
            while inputIndex < input.count, input[inputIndex].isNumber, digits.count < maxDigits {
                digits.append(input[inputIndex])
                inputIndex += 1
            }
            return Int(digits)
        }

        while tokenIndex < tokens.count {
            let token = tokens[tokenIndex]
            if token == "'" {
                tokenIndex += 1
                while tokenIndex < tokens.count, tokens[tokenIndex] != "'" {
                    if inputIndex < input.count { inputIndex += 1 }
                    tokenIndex += 1
                }
                tokenIndex += 1
                continue
            }
            if !token.isLetter {
                if inputIndex < input.count, input[inputIndex] == token { inputIndex += 1 }
                tokenIndex += 1
                continue
            }
            var length = 1
            while tokenIndex + length < tokens.count, tokens[tokenIndex + length] == token { length += 1 }
            let field = String(repeating: token, count: length)
            switch token {
            case "y":
                result.year = readNumber(length == 2 ? 2 : 4) ?? result.year
            case "M":
                if length >= 3 {
                    var word = ""
                    while inputIndex < input.count, input[inputIndex].isLetter || input[inputIndex] == "." {
                        word.append(input[inputIndex])
                        inputIndex += 1
                    }
                    let cleaned = word.lowercased().replacingOccurrences(of: ".", with: "")
                    if let index = monthNames.firstIndex(where: { $0.hasPrefix(cleaned) || cleaned.hasPrefix($0.prefix(3)) }) {
                        result.month = index + 1
                    }
                } else {
                    result.month = readNumber(2) ?? result.month
                }
            case "d":
                result.day = readNumber(2) ?? result.day
            case "H":
                result.hour = readNumber(2) ?? result.hour
            case "h":
                result.hour = readNumber(2) ?? result.hour
            case "m":
                result.minute = readNumber(2) ?? result.minute
            case "s":
                result.second = readNumber(2) ?? result.second
            case "S":
                let fraction = readNumber(9) ?? 0
                result.nano = fraction * Int(pow(10, Double(9 - length)))
            case "a":
                var word = ""
                while inputIndex < input.count, input[inputIndex].isLetter {
                    word.append(input[inputIndex])
                    inputIndex += 1
                }
                amPM = word.uppercased()
            case "E":
                while inputIndex < input.count, input[inputIndex].isLetter || input[inputIndex] == "." { inputIndex += 1 }
            case "Z", "X", "z":
                while inputIndex < input.count, !input[inputIndex].isNumber { inputIndex += 1 }
                _ = readNumber(2); _ = readNumber(2)
            default:
                if inputIndex < input.count, input[inputIndex] == token { inputIndex += 1 }
            }
            tokenIndex += length
            _ = field
        }
        if let amPM {
            if amPM == "PM", result.hour < 12 { result.hour += 12 }
            if amPM == "AM", result.hour == 12 { result.hour = 0 }
        }
        guard result.year != 1970 || result.month != 1 || result.day != 1 || text.contains("1970") else {
            return nil
        }
        _ = zone
        return result
    }

    // MARK: - Pattern format

    static func formatLocal(_ local: VMLocalDateTimePayload, pattern: String) -> String {
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
            case "y":
                output += length == 2 ? String(format: "%02d", local.year % 100) : String(format: "%04d", local.year)
            case "M":
                if length >= 4 { output += monthNames[max(0, min(11, local.month - 1))].capitalized }
                else if length == 3 { output += monthShort[max(0, min(11, local.month - 1))].capitalized }
                else { output += String(format: "%02d", local.month) }
            case "d":
                output += String(format: "%02d", local.day)
            case "H":
                output += String(format: "%02d", local.hour)
            case "h":
                output += String(format: "%02d", local.hour % 12 == 0 ? 12 : local.hour % 12)
            case "m":
                output += String(format: "%02d", local.minute)
            case "s":
                output += String(format: "%02d", local.second)
            case "S":
                output += String(format: "%0\(length)d", local.nano / Int(pow(10, Double(9 - length))))
            case "a":
                output += local.hour < 12 ? "AM" : "PM"
            case "E":
                output += String(format: "EEE")
            default:
                output += String(token)
            }
            index += length
        }
        return output
    }
}

extension VMRuntime {
    func dateTimeFormatter(_ value: VMValue) -> VMDateTimeFormatterPayload? {
        payload(value, as: VMDateTimeFormatterPayload.self)
    }
}
