import XCTest
@testable import MoeReader

/// Semantics tests for the java.time surface extensions use for chapter dates.
final class MihonTimeSemanticsTests: XCTestCase {
    private func makeFormatter(_ runtime: VMRuntime, _ pattern: String) throws -> VMValue {
        let cls = try runtime.linkClass("Ljava/time/format/DateTimeFormatter;")
        let ofPattern = try XCTUnwrap(cls.lookupStatic("ofPattern", "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatter;"))
        return try runtime.invoke(ofPattern, [runtime.newString(pattern)])
    }

    private func withZone(_ runtime: VMRuntime, _ formatter: VMValue, _ zone: VMZonePayload) throws -> VMValue {
        let cls = try runtime.linkClass("Ljava/time/format/DateTimeFormatter;")
        let method = try XCTUnwrap(cls.lookupVirtual(key: "withZone(Ljava/time/ZoneId;)Ljava/time/format/DateTimeFormatter;"))
        return try runtime.invoke(method, [formatter, runtime.makeNative("Ljava/time/ZoneId;", payload: zone)])
    }

    /// Raised by the helpers below instead of calling XCTest assertion helpers.
    /// `XCTUnwrap` records a failure before rethrowing on Linux, so wrapping a
    /// call that is expected to throw would fail the test even when the throw
    /// is the one under test.
    private enum HelperError: Error, CustomStringConvertible {
        case missingMethod(String)
        case missingString

        var description: String {
            switch self {
            case .missingMethod(let name): return "helper could not resolve \(name)"
            case .missingString: return "engine value is not a java.lang.String"
            }
        }
    }

    private func format(_ runtime: VMRuntime, _ formatter: VMValue, _ temporal: VMValue) throws -> String {
        let cls = try runtime.linkClass("Ljava/time/format/DateTimeFormatter;")
        guard let method = cls.lookupVirtual(key: "format(Ljava/time/temporal/TemporalAccessor;)Ljava/lang/String;") else {
            throw HelperError.missingMethod("DateTimeFormatter.format(TemporalAccessor)")
        }
        let value = try runtime.invoke(method, [formatter, temporal])
        guard let text = runtime.stringValue(value) else { throw HelperError.missingString }
        return text
    }

    private func invoke(_ runtime: VMRuntime, _ receiver: VMValue, _ key: String, _ arguments: [VMValue] = []) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(key: key))
        return try runtime.invoke(method, [receiver] + arguments)
    }

    private func string(_ runtime: VMRuntime, _ value: VMValue) throws -> String {
        guard let text = runtime.stringValue(value) else { throw HelperError.missingString }
        return text
    }

    func testFormatterSupportsZonedOffsetAndLocalTimeTemporals() throws {
        let runtime = VMRuntime()
        let local = VMLocalDateTimePayload(year: 2024, month: 3, day: 5, hour: 7, minute: 9, second: 2)
        let plusTwo = VMZonePayload(id: "+02:00", secondsFromGMT: 7200)
        let zoned = runtime.makeNative(
            "Ljava/time/ZonedDateTime;",
            payload: VMZonedDateTimePayload(local: local.copy(), zone: JavaTimeRuntime.utc)
        )
        let offsetZoned = runtime.makeNative(
            "Ljava/time/ZonedDateTime;",
            payload: VMZonedDateTimePayload(local: local.copy(), zone: plusTwo)
        )
        let offsetDateTime = runtime.makeNative(
            "Ljava/time/OffsetDateTime;",
            payload: VMOffsetDateTimePayload(local: local.copy(), offset: plusTwo)
        )
        let time = runtime.makeNative(
            "Ljava/time/LocalTime;",
            payload: VMLocalTimePayload(hour: 7, minute: 9, second: 2)
        )

        XCTAssertEqual(try format(runtime, try makeFormatter(runtime, "yyyy-MM-dd HH:mm:ss"), zoned), "2024-03-05 07:09:02")

        let offsetPattern = try makeFormatter(runtime, "yyyy-MM-dd'T'HH:mmXXX")
        XCTAssertEqual(try format(runtime, offsetPattern, offsetZoned), "2024-03-05T07:09+02:00")
        XCTAssertEqual(try format(runtime, offsetPattern, offsetDateTime), "2024-03-05T07:09+02:00")

        XCTAssertEqual(try format(runtime, try makeFormatter(runtime, "HH:mm:ss"), time), "07:09:02")
        // A date field on LocalTime is unsupported in java.time.
        XCTAssertThrowsError(try format(runtime, try makeFormatter(runtime, "yyyy-MM-dd"), time))
    }

    func testInstantFormatsThroughOverrideAndSystemDefaultZone() throws {
        let runtime = VMRuntime()
        let epoch = runtime.makeNative("Ljava/time/Instant;", payload: VMInstantPayload(epochMilli: 0))
        let utcFormatter = try withZone(runtime, try makeFormatter(runtime, "yyyy-MM-dd HH:mm:ss"), JavaTimeRuntime.utc)
        XCTAssertEqual(try format(runtime, utcFormatter, epoch), "1970-01-01 00:00:00")

        let sample = Date(timeIntervalSince1970: 1_700_000_000)
        let sampleInstant = runtime.makeNative("Ljava/time/Instant;", payload: VMInstantPayload(epochMilli: 1_700_000_000_000))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: sample)
        let expected = String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
        XCTAssertEqual(try format(runtime, try makeFormatter(runtime, "yyyy-MM-dd HH:mm:ss"), sampleInstant), expected)
    }

    func testPatternWidthControlsPaddingAndWeekdayNames() throws {
        let local = VMLocalDateTimePayload(year: 2024, month: 3, day: 5, hour: 7, minute: 9, second: 2)
        XCTAssertEqual(try JavaTimeRuntime.formatLocal(local, pattern: "d/M/H/h/m/s"), "5/3/7/7/9/2")
        XCTAssertEqual(try JavaTimeRuntime.formatLocal(local, pattern: "dd/MM/HH/hh/mm/ss"), "05/03/07/07/09/02")
        XCTAssertEqual(try JavaTimeRuntime.formatLocal(local, pattern: "E"), "Tue")
        XCTAssertEqual(try JavaTimeRuntime.formatLocal(local, pattern: "EEE"), "Tue")
        XCTAssertEqual(try JavaTimeRuntime.formatLocal(local, pattern: "EEEE"), "Tuesday")
        XCTAssertEqual(try JavaTimeRuntime.formatLocal(local, pattern: "EEE, MMM d, yyyy"), "Tue, Mar 5, 2024")

        let runtime = VMRuntime()
        let zoned = runtime.makeNative(
            "Ljava/time/ZonedDateTime;",
            payload: VMZonedDateTimePayload(local: local, zone: JavaTimeRuntime.utc)
        )
        XCTAssertEqual(try format(runtime, try makeFormatter(runtime, "EEEE, MMMM d"), zoned), "Tuesday, March 5")
    }

    func testEpochDatesParse() throws {
        let runtime = VMRuntime()
        let dateTimeClass = try runtime.linkClass("Ljava/time/LocalDateTime;")
        let parseDateTime = try XCTUnwrap(
            dateTimeClass.lookupStatic("parse", "(Ljava/lang/CharSequence;)Ljava/time/LocalDateTime;")
        )
        let dateTimeValue = try runtime.invoke(parseDateTime, [runtime.newString("1970-01-01T00:00:00")])
        let local: VMLocalDateTimePayload = try XCTUnwrap(
            runtime.payload(dateTimeValue, as: VMLocalDateTimePayload.self)
        )
        XCTAssertEqual(local.year, 1970)
        XCTAssertEqual(local.month, 1)
        XCTAssertEqual(local.day, 1)
        XCTAssertEqual(local.hour, 0)

        let dateClass = try runtime.linkClass("Ljava/time/LocalDate;")
        let parseDate = try XCTUnwrap(dateClass.lookupStatic("parse", "(Ljava/lang/CharSequence;)Ljava/time/LocalDate;"))
        let dateValue = try runtime.invoke(parseDate, [runtime.newString("1970-01-01")])
        let date: VMLocalDatePayload = try XCTUnwrap(runtime.payload(dateValue, as: VMLocalDatePayload.self))
        XCTAssertEqual(date.year, 1970)
        XCTAssertEqual(date.month, 1)
        XCTAssertEqual(date.day, 1)

        // Incomplete input is still rejected rather than defaulting to epoch.
        XCTAssertThrowsError(try runtime.invoke(parseDateTime, [runtime.newString("2020-05")]))
        XCTAssertThrowsError(try runtime.invoke(parseDateTime, [runtime.newString("")]))
    }

    func testChapterDatePatternsStillParse() throws {
        let runtime = VMRuntime()
        let dateTimeClass = try runtime.linkClass("Ljava/time/LocalDateTime;")
        let parse = try XCTUnwrap(
            dateTimeClass.lookupStatic("parse", "(Ljava/lang/CharSequence;Ljava/time/format/DateTimeFormatter;)Ljava/time/LocalDateTime;")
        )

        let namedFormatter = try makeFormatter(runtime, "MMM d, yyyy")
        let namedValue = try runtime.invoke(parse, [runtime.newString("Mar 5, 2024"), namedFormatter])
        let named: VMLocalDateTimePayload = try XCTUnwrap(runtime.payload(namedValue, as: VMLocalDateTimePayload.self))
        XCTAssertEqual(named.year, 2024)
        XCTAssertEqual(named.month, 3)
        XCTAssertEqual(named.day, 5)

        // An ISO offset suffix on a LocalDateTime input is ignored, as before.
        let isoFormatter = try makeFormatter(runtime, "yyyy-MM-dd'T'HH:mm:ss")
        let isoValue = try runtime.invoke(parse, [runtime.newString("2024-03-05T10:30:00+02:00"), isoFormatter])
        let iso: VMLocalDateTimePayload = try XCTUnwrap(runtime.payload(isoValue, as: VMLocalDateTimePayload.self))
        XCTAssertEqual(iso.year, 2024)
        XCTAssertEqual(iso.month, 3)
        XCTAssertEqual(iso.day, 5)
        XCTAssertEqual(iso.hour, 10)
        XCTAssertEqual(iso.minute, 30)
    }

    func testNowUsesSystemDefaultZone() throws {
        let runtime = VMRuntime()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current

        let dateTimeClass = try runtime.linkClass("Ljava/time/LocalDateTime;")
        let now = try XCTUnwrap(dateTimeClass.lookupStatic("now", "()Ljava/time/LocalDateTime;"))
        let before = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
        let value = try runtime.invoke(now, [])
        let after = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
        let local: VMLocalDateTimePayload = try XCTUnwrap(runtime.payload(value, as: VMLocalDateTimePayload.self))
        let matchesLocal: (DateComponents) -> Bool = { components in
            components.year == local.year
                && components.month == local.month
                && components.day == local.day
                && components.hour == local.hour
                && components.minute == local.minute
        }
        XCTAssertTrue(matchesLocal(before) || matchesLocal(after), "LocalDateTime.now() must use TimeZone.current")

        let dateClass = try runtime.linkClass("Ljava/time/LocalDate;")
        let nowDate = try XCTUnwrap(dateClass.lookupStatic("now", "()Ljava/time/LocalDate;"))
        let beforeDate = calendar.dateComponents([.year, .month, .day], from: Date())
        let dateValue = try runtime.invoke(nowDate, [])
        let afterDate = calendar.dateComponents([.year, .month, .day], from: Date())
        let date: VMLocalDatePayload = try XCTUnwrap(runtime.payload(dateValue, as: VMLocalDatePayload.self))
        let matchesDate: (DateComponents) -> Bool = { components in
            components.year == date.year && components.month == date.month && components.day == date.day
        }
        XCTAssertTrue(matchesDate(beforeDate) || matchesDate(afterDate), "LocalDate.now() must use TimeZone.current")
    }

    func testZonedDateTimeToLocalDateTimeCopiesPayload() throws {
        let runtime = VMRuntime()
        let original = VMLocalDateTimePayload(year: 2024, month: 3, day: 5, hour: 7, minute: 9, second: 2)
        let zoned = runtime.makeNative(
            "Ljava/time/ZonedDateTime;",
            payload: VMZonedDateTimePayload(local: original, zone: JavaTimeRuntime.utc)
        )
        let copyValue = try invoke(runtime, zoned, "toLocalDateTime()Ljava/time/LocalDateTime;")
        let copied: VMLocalDateTimePayload = try XCTUnwrap(runtime.payload(copyValue, as: VMLocalDateTimePayload.self))
        XCTAssertFalse(copied === original)

        original.year = 1980
        original.hour = 1
        XCTAssertEqual(copied.year, 2024)
        XCTAssertEqual(copied.hour, 7)
        XCTAssertEqual(copied.minute, 9)
        XCTAssertEqual(copied.second, 2)
    }

    func testZonedDateTimeToStringSeparatesOffsetAndZone() throws {
        let runtime = VMRuntime()
        let local = VMLocalDateTimePayload(year: 2024, month: 1, day: 15, hour: 10, minute: 30, second: 0)
        let paris = VMZonePayload(id: "Europe/Paris", secondsFromGMT: 7200)
        let zoned = runtime.makeNative(
            "Ljava/time/ZonedDateTime;",
            payload: VMZonedDateTimePayload(local: local, zone: paris)
        )
        XCTAssertEqual(
            try string(runtime, try invoke(runtime, zoned, "toString()Ljava/lang/String;")),
            "2024-01-15T10:30:00+01:00[Europe/Paris]"
        )

        let fixed = VMZonePayload(id: "-03:00", secondsFromGMT: -10800)
        let fixedZoned = runtime.makeNative(
            "Ljava/time/ZonedDateTime;",
            payload: VMZonedDateTimePayload(local: local, zone: fixed)
        )
        XCTAssertEqual(
            try string(runtime, try invoke(runtime, fixedZoned, "toString()Ljava/lang/String;")),
            "2024-01-15T10:30:00-03:00"
        )

        let offsetDateTime = runtime.makeNative(
            "Ljava/time/OffsetDateTime;",
            payload: VMOffsetDateTimePayload(local: local, offset: fixed)
        )
        XCTAssertEqual(
            try string(runtime, try invoke(runtime, offsetDateTime, "toString()Ljava/lang/String;")),
            "2024-01-15T10:30:00-03:00"
        )
    }
}
