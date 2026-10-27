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
    static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let monthShort = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    static let weekdayShort = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(zoneIdClass())
        result.append(zoneOffsetClass())
        result.append(formatterClass())
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
            let formatterZone = source.flatMap { $0.zone }
            let temporal = args[1]
            if let local: VMLocalDateTimePayload = runtime.payload(temporal, as: VMLocalDateTimePayload.self) {
                return runtime.newString(try formatLocal(local, pattern: pattern, zone: formatterZone.map { resolvedZone(local, zone: $0) }))
            }
            if let date: VMLocalDatePayload = runtime.payload(temporal, as: VMLocalDatePayload.self) {
                let local = VMLocalDateTimePayload(year: date.year, month: date.month, day: date.day)
                return runtime.newString(try formatLocal(local, pattern: pattern, zone: formatterZone.map { resolvedZone(local, zone: $0) }, hasTime: false))
            }
            if let zoned: VMZonedDateTimePayload = runtime.payload(temporal, as: VMZonedDateTimePayload.self) {
                let local = zoned.local
                let zone = formatterZone.map { resolvedZone(local, zone: $0) } ?? resolvedZone(local, zone: zoned.zone)
                return runtime.newString(try formatLocal(local, pattern: pattern, zone: zone))
            }
            if let offsetDateTime: VMOffsetDateTimePayload = runtime.payload(temporal, as: VMOffsetDateTimePayload.self) {
                let local = offsetDateTime.local
                let zone = formatterZone.map { resolvedZone(local, zone: $0) } ?? offsetDateTime.offset
                return runtime.newString(try formatLocal(local, pattern: pattern, zone: zone))
            }
            if let time: VMLocalTimePayload = runtime.payload(temporal, as: VMLocalTimePayload.self) {
                let local = VMLocalDateTimePayload(hour: time.hour, minute: time.minute, second: time.second, nano: time.nano)
                // LocalTime has no offset field in java.time.
                return runtime.newString(try formatLocal(local, pattern: pattern, hasDate: false))
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
            guard let parsed = parse(text, pattern: formatter?.pattern ?? "yyyy-MM-dd'T'HH:mm:ss", zone: formatter?.zone) else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", text)
            }
            return runtime.makeNative("Ljava/time/LocalDateTime;", payload: parsed)
        }
        cls.staticMethod("now", "()Ljava/time/LocalDateTime;") { runtime, _, _ in
            runtime.makeNative("Ljava/time/LocalDateTime;", payload: localFromDate(Date(), zone: systemDefaultZone()))
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
            guard let parsed = parse(text, pattern: formatter?.pattern ?? "yyyy-MM-dd") else {
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

    static func parse(_ text: String, pattern: String, zone: VMZonePayload? = nil) -> VMLocalDateTimePayload? {
        let input = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let tokens = Array(pattern)
        var result = VMLocalDateTimePayload()
        var inputIndex = 0
        var tokenIndex = 0
        var amPM: String?
        var missingField = false
        var parsedField = false

        func readNumber(_ maxDigits: Int) -> Int? {
            var digits = ""
            while inputIndex < input.count, input[inputIndex].isNumber, digits.count < maxDigits {
                digits.append(input[inputIndex])
                inputIndex += 1
            }
            return Int(digits)
        }

        func readRequired(_ maxDigits: Int) -> Int? {
            guard let value = readNumber(maxDigits) else {
                missingField = true
                return nil
            }
            return value
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
                if let value = readRequired(length == 2 ? 2 : 4) {
                    result.year = value
                    parsedField = true
                }
            case "M":
                if length >= 3 {
                    var word = ""
                    while inputIndex < input.count, input[inputIndex].isLetter || input[inputIndex] == "." {
                        word.append(input[inputIndex])
                        inputIndex += 1
                    }
                    let cleaned = word.lowercased().replacingOccurrences(of: ".", with: "")
                    if cleaned.isEmpty {
                        missingField = true
                    } else if let index = monthNames.firstIndex(where: { $0.hasPrefix(cleaned) || cleaned.hasPrefix($0.prefix(3)) }) {
                        result.month = index + 1
                        parsedField = true
                    } else {
                        missingField = true
                    }
                } else if let value = readRequired(2) {
                    result.month = value
                    parsedField = true
                }
            case "d":
                if let value = readRequired(2) {
                    result.day = value
                    parsedField = true
                }
            case "H":
                if let value = readRequired(2) {
                    result.hour = value
                    parsedField = true
                }
            case "h":
                if let value = readRequired(2) {
                    result.hour = value
                    parsedField = true
                }
            case "m":
                if let value = readRequired(2) {
                    result.minute = value
                    parsedField = true
                }
            case "s":
                if let value = readRequired(2) {
                    result.second = value
                    parsedField = true
                }
            case "S":
                let fraction = readNumber(9) ?? 0
                result.nano = fraction * Int(pow(10, Double(9 - length)))
                parsedField = true
            case "a":
                var word = ""
                while inputIndex < input.count, input[inputIndex].isLetter {
                    word.append(input[inputIndex])
                    inputIndex += 1
                }
                if word.isEmpty {
                    missingField = true
                } else {
                    amPM = word.uppercased()
                    parsedField = true
                }
            case "E":
                while inputIndex < input.count, input[inputIndex].isLetter || input[inputIndex] == "." { inputIndex += 1 }
            case "Z", "X", "z":
                while inputIndex < input.count, !input[inputIndex].isNumber { inputIndex += 1 }
                _ = readNumber(2); _ = readNumber(2)
                parsedField = true
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
        // Epoch values such as 1970-01-01 are valid; only inputs missing a
        // required field are rejected.
        guard parsedField, !missingField else { return nil }
        _ = zone
        return result
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
        hasTime: Bool = true
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
                    output += monthShort[month - 1].capitalized
                } else if length == 4 {
                    output += monthNames[month - 1].capitalized
                } else {
                    output += String(monthNames[month - 1].prefix(1)).uppercased()
                }
            case "d":
                try require(hasDate, pattern)
                output += padded(local.day, length)
            case "E":
                try require(hasDate, pattern)
                output += weekdayName(weekdayIndex(local), length: length)
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
                output += local.hour < 12 ? "AM" : "PM"
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

    static func weekdayName(_ index: Int, length: Int) -> String {
        let clamped = max(0, min(6, index))
        if length >= 5 { return String(weekdayNames[clamped].prefix(1)) }
        if length == 4 { return weekdayNames[clamped] }
        return weekdayShort[clamped]
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
