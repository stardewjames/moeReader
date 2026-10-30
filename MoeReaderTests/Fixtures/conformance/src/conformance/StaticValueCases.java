package conformance;

import java.lang.reflect.Field;

import static conformance.Fmt.d;
import static conformance.Fmt.f;
import static conformance.Fmt.join;

/**
 * Static fields with constant initializers. d8 folds these assignments into
 * the class's encoded static values (encoded_array_item), so this exercises
 * the encoded_value decoder for every type, including sign extension of
 * negative values and the right-zero-extended float/double encodings.
 */
public final class StaticValueCases {
    private StaticValueCases() {}

    static final class Values {
        static float F = 0.1f;
        static double D = 1.5;
        static long L = -2;
        static char C = 'x';
        static byte B = -3;
        static short S = -300;
        static boolean Z = true;
        static String STR = "s";
        static int I = -123456;
        static int IMIN = Integer.MIN_VALUE;
        static long LMIN = Long.MIN_VALUE;
        static long LMAX = Long.MAX_VALUE;
        static long LSMALL = 127;
        static long LNEG8 = -129;
        static float FNEG_ZERO = -0.0f;
        static float FMAX = Float.MAX_VALUE;
        static float FMIN = Float.MIN_VALUE;
        static float FINF = Float.NEGATIVE_INFINITY;
        static float FNAN = Float.NaN;
        static float FWHOLE = 2.0f;
        static double DSMALL = 4.9e-324;
        static double DNEG = -1e300;
        static double DNEG_ZERO = -0.0;
        static double DTENTH = 0.1;
        static double DWHOLE = 1024.0;
        static double DNAN = Double.NaN;
        static char CMAX = '\uffff';
        static char CHIGH = '\u8000';
        static byte BMIN = Byte.MIN_VALUE;
        static short SMIN = Short.MIN_VALUE;
        static short SPOS = 0x7f00;
        static String UNICODE = "\u00e9\u4e2d\uD83D\uDE00";
        static String EMPTY = "";
        static Object NULL_OBJECT = null;
        static boolean FALSE = false;
        static int ZERO = 0;
    }

    static final class Finals {
        static final float F = -2.5f;
        static final double D = -0.125;
        static final long L = -1L << 40;
        static final char C = '\u00ff';
        static final byte B = -128;
        static final short S = -1;
        static final int I = -1;
        static final boolean Z = true;
        static final String STR = "final";
    }

    static final class Mixed {
        static int beforeCall = 41;
        static int computed = Fmt.v(beforeCall + 1);
        static long afterCall = -7L;
    }

    public static String floatValues() {
        return join(f(Values.F), f(Values.FNEG_ZERO), f(Values.FMAX), f(Values.FMIN), f(Values.FINF), f(Values.FNAN), f(Values.FWHOLE));
    }

    public static String doubleValues() {
        return join(d(Values.D), d(Values.DSMALL), d(Values.DNEG), d(Values.DNEG_ZERO), d(Values.DTENTH), d(Values.DWHOLE), d(Values.DNAN));
    }

    public static String longValues() {
        return join(Values.L, Values.LMIN, Values.LMAX, Values.LSMALL, Values.LNEG8);
    }

    public static String intValues() {
        return join(Values.I, Values.IMIN, Values.ZERO);
    }

    public static String charValues() {
        return join((int) Values.C, (int) Values.CMAX, (int) Values.CHIGH);
    }

    public static String byteAndShortValues() {
        return join(Values.B, Values.BMIN, Values.S, Values.SMIN, Values.SPOS);
    }

    public static String booleanValues() {
        return join(Values.Z, Values.FALSE);
    }

    public static String referenceValues() {
        return join(Values.STR, Values.UNICODE, Values.UNICODE.length(), "[" + Values.EMPTY + "]", Values.NULL_OBJECT,
            Values.STR == "s");
    }

    public static String finalValues() {
        return join(f(Finals.F), d(Finals.D), Finals.L, (int) Finals.C, Finals.B, Finals.S, Finals.I, Finals.Z, Finals.STR);
    }

    public static String finalValuesThroughReflection() throws Exception {
        StringBuilder out = new StringBuilder();
        for (String name : new String[] {"F", "D", "L", "C", "B", "S", "I", "Z", "STR"}) {
            Field field = Finals.class.getDeclaredField(name);
            Object value = field.get(null);
            out.append(name).append('=').append(value.getClass().getSimpleName()).append(':');
            if (value instanceof Float) out.append(f((Float) value));
            else if (value instanceof Double) out.append(d((Double) value));
            else if (value instanceof Character) out.append((int) (Character) value);
            else out.append(value);
            out.append(';');
        }
        return out.toString();
    }

    public static String valuesThroughReflectionTypedGetters() throws Exception {
        Class<?> c = Values.class;
        return join(f(c.getDeclaredField("F").getFloat(null)), d(c.getDeclaredField("F").getDouble(null)),
            c.getDeclaredField("B").getInt(null), c.getDeclaredField("C").getLong(null), c.getDeclaredField("S").getShort(null),
            c.getDeclaredField("Z").getBoolean(null), c.getDeclaredField("L").getLong(null));
    }

    public static String reflectionTypedGetterMismatch() throws Exception {
        return Integer.toString(Values.class.getDeclaredField("L").getInt(null));
    }

    static final class Mutable {
        static byte B = -3;
        static char C = 'x';
        static float F = 0.1f;
    }

    public static String mutatedThenRead() {
        Mutable.B -= 1;
        Mutable.C += 1;
        Mutable.F *= 2f;
        return join(Mutable.B, (int) Mutable.C, f(Mutable.F));
    }

    public static String initializerOrderAroundCall() {
        return join(Mixed.beforeCall, Mixed.computed, Mixed.afterCall);
    }

    static class Instance {
        int i;
        long l;
        float f;
        double d;
        char c;
        byte b;
        short s;
        boolean z;
        Object o;
    }

    public static String instanceDefaults() {
        Instance x = new Instance();
        return join(x.i, x.l, f(x.f), d(x.d), (int) x.c, x.b, x.s, x.z, x.o);
    }
}
