package conformance;

/**
 * Formatting helpers shared by the case classes. The {@code v} overloads hide
 * operands from javac's constant folder so the arithmetic really runs in the
 * interpreter. Floating-point results are printed as canonical bit patterns
 * ({@code floatToIntBits}/{@code doubleToLongBits}), never through
 * {@code Float.toString}, whose shortest-representation algorithm differs
 * between Java releases.
 */
final class Fmt {
    private Fmt() {}

    static int v(int x) { return x; }
    static long v(long x) { return x; }
    static float v(float x) { return x; }
    static double v(double x) { return x; }
    static char v(char x) { return x; }
    static byte v(byte x) { return x; }
    static short v(short x) { return x; }
    static boolean v(boolean x) { return x; }
    static String v(String x) { return x; }
    static Object o(Object x) { return x; }

    static String f(float x) {
        return Integer.toHexString(Float.floatToIntBits(x));
    }

    static String d(double x) {
        return Long.toHexString(Double.doubleToLongBits(x));
    }

    static String join(Object... parts) {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < parts.length; i++) {
            if (i > 0) out.append(',');
            out.append(parts[i]);
        }
        return out.toString();
    }

    /** Simple class name of a throwable, the form every case reports. */
    static String name(Throwable t) {
        return t == null ? "null" : t.getClass().getSimpleName();
    }
}
