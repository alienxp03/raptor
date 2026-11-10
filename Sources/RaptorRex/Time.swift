import Foundation

extension Rex {
    /// Parses Go's time.Time JSON form: RFC3339 with optional fractional seconds.
    /// Returns nil for malformed input (Go leaves the zero time; callers treat
    /// zero as missing).
    static func parseRFC3339(_ raw: String) -> Date? {
        // ^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$
        let chars = Array(raw.unicodeScalars)
        func digits(_ i: Int, _ n: Int) -> Int? {
            guard i + n <= chars.count else { return nil }
            var value = 0
            for j in i..<(i + n) {
                let c = chars[j]
                guard c.value >= 48, c.value <= 57 else { return nil }
                value = value * 10 + Int(c.value - 48)
            }
            return value
        }
        guard chars.count >= 20 else { return nil }
        guard let year = digits(0, 4), chars[4] == "-", let month = digits(5, 2), chars[7] == "-",
              let day = digits(8, 2), chars[10] == "T" || chars[10] == "t",
              let hour = digits(11, 2), chars[13] == ":",
              let minute = digits(14, 2), chars[16] == ":",
              let second = digits(17, 2) else { return nil }
        guard month >= 1, month <= 12, day >= 1, day <= 31, hour <= 23, minute <= 59, second <= 60 else { return nil }
        var i = 19
        var fraction = 0.0
        if i < chars.count, chars[i] == "." {
            i += 1
            var start = i
            while i < chars.count, chars[i].value >= 48, chars[i].value <= 57 {
                i += 1
            }
            guard i > start else { return nil }
            var scale = 0.1
            for j in start..<i {
                fraction += Double(chars[j].value - 48) * scale
                scale /= 10
            }
            start = i
        }
        guard i < chars.count else { return nil }
        var offsetSeconds = 0
        switch chars[i] {
        case "Z", "z":
            i += 1
        case "+", "-":
            let sign = chars[i] == "-" ? -1 : 1
            guard let oh = digits(i + 1, 2), chars[i + 3] == ":", let om = digits(i + 4, 2) else { return nil }
            offsetSeconds = sign * (oh * 3600 + om * 60)
            i += 6
        default:
            return nil
        }
        guard i == chars.count else { return nil }
        // Proleptic Gregorian days-from-civil; Calendar uses Julian rules for
        // dates before 1582, which would shift the zero time.
        func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
            let y = year - (month <= 2 ? 1 : 0)
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let mp = (month + 9) % 12
            let doy = (153 * mp + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            return era * 146097 + doe - 719468
        }
        let clampedSecond = second == 60 ? 59 : second
        let daySeconds = daysFromCivil(year, month, day) * 86400
            + hour * 3600 + minute * 60 + clampedSecond - offsetSeconds
        let leapAdjustment: Double = second == 60 ? 1 : 0
        return Date(timeIntervalSince1970: Double(daySeconds) + fraction + leapAdjustment)
    }

    /// Formats like Go's time.Time MarshalJSON for UTC times: RFC3339 with a
    /// fractional part trimmed of trailing zeros (RFC3339Nano).
    static func formatRFC3339(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var out = formatter.string(from: date)
        let seconds = floor(date.timeIntervalSince1970)
        let fraction = date.timeIntervalSince1970 - seconds
        if fraction > 0 {
            var digits = String(format: "%.9f", fraction)
            digits.removeFirst(2) // "0."
            while digits.hasSuffix("0") {
                digits.removeLast()
            }
            if !digits.isEmpty {
                out += "." + digits
            }
        }
        return out + "Z"
    }
}
