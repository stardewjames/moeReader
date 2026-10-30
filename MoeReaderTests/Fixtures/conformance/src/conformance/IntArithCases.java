package conformance;

import static conformance.Fmt.join;
import static conformance.Fmt.v;

public final class IntArithCases {
    private IntArithCases() {}

    public static String addOverflow() {
        return join(v(Integer.MAX_VALUE) + 1, v(Integer.MIN_VALUE) - 1, v(65536) * v(65536), v(Integer.MIN_VALUE) * -1);
    }

    public static String longOverflow() {
        return join(v(Long.MAX_VALUE) + 1, v(Long.MIN_VALUE) - 1, v(4294967296L) * v(4294967296L), v(Long.MIN_VALUE) * -1L);
    }

    public static String divMinByMinusOne() {
        int min = v(Integer.MIN_VALUE);
        int minusOne = v(-1);
        return join(min / minusOne, min % minusOne);
    }

    public static String divMinByMinusOneLiteral() {
        // div-int/lit8 and rem-int/lit8 with a literal -1.
        int min = v(Integer.MIN_VALUE);
        return join(min / -1, min % -1);
    }

    public static String longDivMinByMinusOne() {
        long min = v(Long.MIN_VALUE);
        long minusOne = v(-1L);
        return join(min / minusOne, min % minusOne);
    }

    public static String remSign() {
        return join(v(-7) % 3, v(7) % -3, v(-7) % -3, v(7) % 3, v(-7L) % 3L, v(7L) % -3L);
    }

    public static String divTruncatesTowardZero() {
        return join(v(-7) / 2, v(7) / -2, v(-7L) / 2L, v(-1) / 2, v(-1000) / 7);
    }

    public static String lit16Arithmetic() {
        int x = v(-12345);
        return join(x / 1000, x % 1000, x * 1000, 1000 - x, x & 0x7ff0, x | 0x0f00, x ^ 0x5555);
    }

    public static String lit8Arithmetic() {
        int x = v(-77);
        return join(x / 7, x % 7, x * -3, 100 - x, x & 0x7f, x | 0x10, x ^ -1, x + 127, x - 128);
    }

    public static String intDivByZero() {
        return Integer.toString(v(1) / v(0));
    }

    public static String intRemByZeroCaught() {
        try {
            return Integer.toString(v(1) % v(0));
        } catch (ArithmeticException e) {
            return "caught";
        }
    }

    public static String intDivByLiteralZero() {
        try {
            return Integer.toString(v(9) / 0);
        } catch (ArithmeticException e) {
            return "caught";
        }
    }

    public static String longDivByZero() {
        return Long.toString(v(1L) / v(0L));
    }

    public static String longRemByZeroCaught() {
        try {
            return Long.toString(v(1L) % v(0L));
        } catch (ArithmeticException e) {
            return "caught";
        }
    }

    public static String intShiftCounts() {
        int one = v(1);
        int count32 = v(32);
        int count33 = v(33);
        int minusOne = v(-1);
        return join(one << count32, one << count33, one << minusOne, -1 >>> v(28), v(-16) >> 2, -1 >>> count32, v(-16) >> v(-2));
    }

    public static String intShiftLiteralCounts() {
        // shl-int/lit8 and friends with counts outside 0..31.
        int x = v(3);
        int y = v(-256);
        return join(x << 33, x << 63, y >> 36, y >>> 36, y >>> 32, y >> 31);
    }

    public static String longShiftCounts() {
        long one = v(1L);
        return join(one << v(64), one << v(65), one << v(-1), -1L >>> v(60), v(-16L) >> 2, -1L >>> v(64), v(-1L) >>> v(-4), v(0x8000_0000_0000_0000L) >> 63);
    }

    public static String ushrOfNegative() {
        return join(v(Integer.MIN_VALUE) >>> 31, v(-2) >>> 1, v(Long.MIN_VALUE) >>> 63, v(-2L) >>> 1);
    }

    public static String negation() {
        int min = v(Integer.MIN_VALUE);
        long lmin = v(Long.MIN_VALUE);
        return join(-min, -lmin, Math.abs(min), Math.abs(lmin), -v(0), ~v(0), ~v(-1L));
    }

    public static String widenAndTruncate() {
        long big = v(0x1_2345_6789L);
        int neg = v(-5);
        return join((int) big, (long) neg, (int) v(0xFFFF_FFFF_0000_0001L), (long) v(Integer.MIN_VALUE) - 1);
    }

    public static String longCompare() {
        long a = v(Long.MIN_VALUE);
        long b = v(Long.MAX_VALUE);
        return join(a < b, a > b, a == b, Long.compare(a, b), Long.compare(b, a), Long.compare(a, a), Long.signum(a));
    }

    public static String unsignedHelpers() {
        return join(Integer.divideUnsigned(-1, 2), Integer.remainderUnsigned(-1, 7), Integer.toUnsignedString(-1),
            Integer.compareUnsigned(-1, 1), Long.toUnsignedString(-1L), Long.divideUnsigned(-1L, 10L),
            Integer.toUnsignedLong(-2));
    }

    public static String radixStrings() {
        return join(Integer.toHexString(-1), Integer.toBinaryString(v(10)), Integer.toOctalString(-8),
            Long.toHexString(v(Long.MIN_VALUE)), Integer.toString(-255, 16), Long.toString(v(-35L), 36));
    }

    public static String bitHelpers() {
        return join(Integer.bitCount(v(-1)), Integer.numberOfLeadingZeros(v(1)), Integer.numberOfTrailingZeros(v(0)),
            Integer.highestOneBit(v(-1)), Integer.reverse(v(1)), Integer.rotateLeft(v(0x80000001), 1),
            Long.numberOfLeadingZeros(v(0L)), Integer.reverseBytes(v(0x01020304)));
    }

    public static String charArithmetic() {
        char c = v('a');
        char max = v('\uffff');
        return join((int) (char) (c + 1), c + 1, (int) (char) (max + 1), max + 1, (int) c++, (int) c);
    }

    public static String compoundAssignment() {
        int i = v(10);
        i += 3.7;
        int j = v(10);
        j *= -1.5;
        long l = v(5L);
        l <<= 65;
        int k = v(7);
        k >>>= -31;
        return join(i, j, l, k);
    }

    public static String mathExactThrows() {
        return Integer.toString(Math.addExact(v(Integer.MAX_VALUE), 1));
    }

    public static String floorDivMod() {
        return join(Math.floorDiv(v(-7), 2), Math.floorMod(v(-7), 2), Math.floorDiv(v(7), -2), Math.floorMod(v(7), -2),
            Math.floorMod(v(-7L), 3L));
    }

    public static String parseEdges() {
        return join(Integer.parseInt("-2147483648"), Integer.parseInt("+5"), Integer.parseInt("-0"),
            Long.parseLong("9223372036854775807"), Integer.parseInt("-ff", 16), Integer.parseUnsignedInt("4294967295"));
    }

    public static String parseOverflow() {
        return Integer.toString(Integer.parseInt("2147483648"));
    }

    public static String boxCache() {
        Integer a = 127;
        Integer b = 127;
        Integer c = -128;
        Integer d = -128;
        Character e = 'x';
        Character f = 'x';
        Boolean g = true;
        return join(a == b, c == d, e == f, g == Boolean.TRUE, Integer.valueOf(1000).equals(1000), Long.valueOf(1).equals(1));
    }
}
