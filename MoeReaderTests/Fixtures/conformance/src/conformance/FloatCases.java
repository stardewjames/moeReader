package conformance;

import static conformance.Fmt.d;
import static conformance.Fmt.f;
import static conformance.Fmt.join;
import static conformance.Fmt.v;

public final class FloatCases {
    private FloatCases() {}

    public static String floatNaNComparisons() {
        float nan = v(Float.NaN);
        float one = v(1f);
        // Each relational operator picks cmpl-float or cmpg-float so that NaN
        // makes the comparison false.
        return join(nan < one, nan > one, nan <= one, nan >= one, nan == nan, nan != nan, one < nan, one > nan,
            !(nan < one), !(nan > one));
    }

    public static String doubleNaNComparisons() {
        double nan = v(Double.NaN);
        double one = v(1.0);
        return join(nan < one, nan > one, nan <= one, nan >= one, nan == nan, nan != nan, one < nan, one > nan,
            !(nan >= one), !(nan <= one));
    }

    public static String nanBranches() {
        float nan = v(Float.NaN);
        StringBuilder out = new StringBuilder();
        if (nan < 0f) out.append('a'); else out.append('A');
        if (nan > 0f) out.append('b'); else out.append('B');
        if (nan >= 0f) out.append('c'); else out.append('C');
        if (nan <= 0f) out.append('d'); else out.append('D');
        double dn = v(Double.NaN);
        if (dn < 0.0) out.append('e'); else out.append('E');
        if (dn > 0.0) out.append('f'); else out.append('F');
        return out.toString();
    }

    public static String compareMethods() {
        return join(Float.compare(v(Float.NaN), Float.POSITIVE_INFINITY), Float.compare(v(0f), -0f),
            Double.compare(v(-0.0), 0.0), Double.compare(v(Double.NaN), Double.NaN),
            Float.valueOf(v(Float.NaN)).equals(Float.NaN), Double.valueOf(v(0.0)).equals(-0.0));
    }

    public static String negativeZero() {
        float pz = v(0f);
        float nz = -pz;
        double dz = v(0.0);
        double dnz = -dz;
        return join(pz == nz, f(nz), d(dnz), f(1f / nz), d(1.0 / dnz), f(Math.min(pz, nz)), d(Math.max(dnz, dz)),
            d(Math.abs(dnz)), f(pz * -1f));
    }

    public static String infinities() {
        float inf = v(Float.POSITIVE_INFINITY);
        double dinf = v(Double.NEGATIVE_INFINITY);
        return join(inf > Float.MAX_VALUE, dinf < -Double.MAX_VALUE, f(inf - inf), d(dinf * 0.0), f(inf * -1f),
            f(1f / v(0f)), d(-1.0 / v(0.0)), f(v(0f) / v(0f)), Float.isInfinite(inf), Double.isNaN(dinf + -dinf));
    }

    public static String floatToIntSaturation() {
        return join((int) v(1e20f), (int) v(-1e20f), (int) v(Float.NaN), (int) v(Float.POSITIVE_INFINITY),
            (int) v(Float.NEGATIVE_INFINITY), (int) v(-2.5f), (int) v(2.9f), (int) v(2147483520f), (int) v(-2147483648f));
    }

    public static String floatToLongSaturation() {
        return join((long) v(1e30f), (long) v(-1e30f), (long) v(Float.NaN), (long) v(Float.POSITIVE_INFINITY),
            (long) v(-0.9f), (long) v(9.2233715E18f));
    }

    public static String doubleToIntSaturation() {
        return join((int) v(1e10), (int) v(-1e10), (int) v(Double.NaN), (int) v(Double.NEGATIVE_INFINITY),
            (int) v(-2147483648.9), (int) v(2147483647.9), (int) v(-0.5));
    }

    public static String doubleToLongSaturation() {
        return join((long) v(1e300), (long) v(-1e300), (long) v(Double.NaN), (long) v(9.223372036854776E18),
            (long) v(-9.223372036854776E18), (long) v(4.5e15));
    }

    public static String intToFloatRounding() {
        return join(f((float) v(16777217)), f((float) v(16777219)), f((float) v(Integer.MAX_VALUE)),
            f((float) v(-16777217)), (int) (float) v(16777219), (long) (float) v(Long.MAX_VALUE));
    }

    public static String longToFloatAndDouble() {
        return join(f((float) v(Long.MAX_VALUE)), d((double) v(Long.MAX_VALUE)), d((double) v(9007199254740993L)),
            f((float) v(Long.MIN_VALUE)), d((double) v(-9007199254740993L)), f((float) v(0x20000010000001L)));
    }

    public static String floatDoubleConversion() {
        return join(d((double) v(0.1f)), f((float) v(0.1)), f((float) v(1e300)), f((float) v(-1e-50)),
            f((float) v(Double.NaN)), f((float) v(3.4028235677973366E38)), f((float) v(1.401298464324817E-45)));
    }

    public static String floatRemainder() {
        return join(f(v(5.5f) % 2f), f(v(-5.5f) % 2f), f(v(5.5f) % -2f), f(v(5f) % 0f), f(v(Float.POSITIVE_INFINITY) % 2f),
            f(v(5f) % Float.POSITIVE_INFINITY), f(v(-0f) % 1f), f(v(1e10f) % 3f), f(v(0.3f) % 0.1f));
    }

    public static String doubleRemainder() {
        return join(d(v(5.5) % 2.0), d(v(-5.5) % 2.0), d(v(5.5) % -2.0), d(v(5.0) % 0.0), d(v(Double.NEGATIVE_INFINITY) % 2.0),
            d(v(5.0) % Double.POSITIVE_INFINITY), d(v(-0.0) % 1.0), d(v(1e300) % 7.0), d(v(0.3) % 0.1));
    }

    public static String floatArithmetic() {
        return join(f(v(0.1f) + 0.2f), d(v(0.1) + 0.2), f(v(1f) / 3f), d(v(1.0) / 3.0), f(v(Float.MIN_VALUE) / 2f),
            d(v(Double.MIN_VALUE) * 0.5), f(v(Float.MAX_VALUE) * 2f), d(v(1e308) * 10.0), f(v(16777216f) + 1f));
    }

    public static String mathRounding() {
        return join(Math.round(v(-2.5)), Math.round(v(2.5)), Math.round(v(Double.NaN)), Math.round(v(-0.5f)),
            Math.round(v(1e20f)), d(Math.floor(v(-0.5))), d(Math.ceil(v(-0.5))), d(Math.rint(v(2.5))), d(Math.rint(v(-1.5))));
    }

    public static String bitConversions() {
        return join(Float.isNaN(Float.intBitsToFloat(v(0x7f800001))), Float.floatToIntBits(Float.intBitsToFloat(v(0x7fc00123))),
            Double.doubleToLongBits(Double.longBitsToDouble(v(0x7ff0000000000001L))), Float.floatToRawIntBits(v(-0f)),
            Long.toHexString(Double.doubleToRawLongBits(v(-1.0))));
    }

    public static String floatNegateNaNIsNaN() {
        float nan = v(Float.NaN);
        double dnan = v(Double.NaN);
        return join(Float.isNaN(-nan), Double.isNaN(-dnan), f(-nan), d(-dnan));
    }

    public static String floatCompoundNarrowing() {
        float acc = v(0f);
        for (int i = 0; i < 10; i++) acc += 0.1f;
        double dacc = v(0.0);
        for (int i = 0; i < 10; i++) dacc += 0.1;
        return join(f(acc), d(dacc), acc == 1f, dacc == 1.0);
    }
}
