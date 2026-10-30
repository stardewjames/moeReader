package conformance;

import static conformance.Fmt.join;
import static conformance.Fmt.v;

public final class NarrowingCases {
    private NarrowingCases() {}

    static byte byteField;
    static short shortField;
    static char charField;
    byte instanceByte;
    char instanceChar;

    public static String intToByte() {
        return join((byte) v(200), (byte) v(128), (byte) v(-129), (byte) v(255), (byte) v(0x12345680), (byte) v(-1));
    }

    public static String intToShort() {
        return join((short) v(70000), (short) v(0x8000), (short) v(-32769), (short) v(65535), (short) v(0x7fff_ffff));
    }

    public static String intToChar() {
        return join((int) (char) v(-1), (int) (char) v(65536 + 65), (int) (char) v(0x8000), (int) (char) v(Integer.MIN_VALUE));
    }

    public static String chainedNarrowing() {
        return join((int) (char) (byte) v(-1), (byte) (char) v(-129), (short) (char) v(-1), (int) (char) (short) v(-2));
    }

    public static String floatingToSmallIntegral() {
        // double -> int -> byte, per JLS 5.1.3.
        return join((byte) v(1e10), (int) (char) v(-1.0), (short) v(1e10f), (byte) v(Double.NaN), (int) (char) v(70000.7f),
            (byte) v(-129.9));
    }

    public static String longToSmallIntegral() {
        return join((byte) v(0x1_0000_00FFL), (short) v(-65537L), (int) (char) v(-1L), (int) v(0x8000_0000L));
    }

    public static String incrementWraps() {
        byte b = v((byte) 127);
        b++;
        short s = v((short) -32768);
        s--;
        char c = v((char) 0);
        c--;
        byte m = v((byte) 100);
        m += 100;
        short t = v((short) 300);
        t *= 300;
        char u = v('a');
        u += 65536;
        return join(b, s, (int) c, m, t, (int) u);
    }

    public static String arrayElementExtension() {
        byte[] bytes = new byte[1];
        bytes[0] = (byte) v(255);
        short[] shorts = new short[1];
        shorts[0] = (short) v(0xffff);
        char[] chars = new char[1];
        chars[0] = (char) v(-1);
        boolean[] flags = new boolean[1];
        flags[0] = v(true);
        int bi = bytes[0];
        int si = shorts[0];
        int ci = chars[0];
        return join(bi, si, ci, flags[0], bytes[0] & 0xff);
    }

    public static String staticFieldExtension() {
        byteField = (byte) v(0x80);
        shortField = (short) v(0x8001);
        charField = (char) v(0x8001);
        int b = byteField;
        int s = shortField;
        int c = charField;
        return join(b, s, c);
    }

    public static String instanceFieldExtension() {
        NarrowingCases n = new NarrowingCases();
        n.instanceByte = (byte) v(-2);
        n.instanceChar = (char) v(-2);
        int b = n.instanceByte;
        int c = n.instanceChar;
        return join(b, c);
    }

    public static String byteArithmeticPromotes() {
        byte a = v((byte) 100);
        byte b = v((byte) 100);
        int sum = a + b;
        byte wrapped = (byte) (a + b);
        char x = v('\u8000');
        short y = (short) x;
        return join(sum, wrapped, a * b, y, (int) (char) y);
    }

    public static String charStringConversion() {
        char c = (char) v(0x41);
        return join(String.valueOf(c), "" + (char) v(66) + (char) v(67), Character.getNumericValue('7'), (int) Character.forDigit(11, 16));
    }

    public static String boxedNarrowValues() {
        Byte b = (byte) v(-1);
        Short s = (short) v(-1);
        Character c = (char) v(-1);
        return join(b.intValue(), s.intValue(), (int) c.charValue(), b.equals((byte) -1), Byte.toUnsignedInt(b),
            Short.toUnsignedInt(s));
    }

    public static String switchOnByte() {
        StringBuilder out = new StringBuilder();
        for (int i = 125; i < 131; i++) {
            byte b = (byte) i;
            switch (b) {
                case 127: out.append("max;"); break;
                case -128: out.append("min;"); break;
                case -127: out.append("min1;"); break;
                default: out.append(b).append(';');
            }
        }
        return out.toString();
    }
}
