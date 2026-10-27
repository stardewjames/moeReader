public final class ArrayProbe {
    public static int byteLoad() {
        byte[] values = new byte[] { (byte) 0xFE, 0x7F, (byte) 0x80 };
        return values[0] + values[1] + values[2];
    }
    public static int charLoad() {
        char[] values = new char[] { (char) 0xFFFF, (char) 0x8000, (char) 0x7FFF };
        return values[0] + values[1] + values[2];
    }
    public static int shortLoad() {
        short[] values = new short[] { (short) 0xFFFF, (short) 0x8000, (short) 0x7FFF };
        return values[0] + values[1] + values[2];
    }
    public static int booleanLoad() {
        boolean[] values = new boolean[] { true, false, true };
        return (values[0] ? 1 : 0) + (values[1] ? 1 : 0) + (values[2] ? 1 : 0);
    }
    public static long minLong() {
        return -9223372036854775808L;
    }
    public static int filledFive() {
        int[] values = new int[] { 1, 2, 3, 4, 5 };
        return values[0] + values[1] + values[2] + values[3] + values[4];
    }
    public static int byteWidening() {
        int value = 0x1234;
        byte[] bytes = new byte[1];
        bytes[0] = (byte) value;
        return bytes[0];
    }
    public static int charWidening() {
        int value = 0x12345;
        char[] chars = new char[1];
        chars[0] = (char) value;
        return chars[0];
    }
    public static int shortWidening() {
        int value = 0x12345;
        short[] shorts = new short[1];
        shorts[0] = (short) value;
        return shorts[0];
    }
}
