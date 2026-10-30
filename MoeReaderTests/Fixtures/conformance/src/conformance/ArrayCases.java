package conformance;

import java.io.Serializable;
import java.lang.reflect.Array;
import java.util.Arrays;

import static conformance.Fmt.join;
import static conformance.Fmt.name;
import static conformance.Fmt.o;
import static conformance.Fmt.v;

public final class ArrayCases {
    private ArrayCases() {}

    // Array literals of constants compile to fill-array-data; the expected
    // arrays are built element by element from non-constant values.

    public static String fillByte() {
        byte[] lit = {-128, -1, 0, 1, 127, -2, 64, -100};
        byte[] built = new byte[8];
        built[0] = v((byte) -128);
        built[1] = v((byte) -1);
        built[2] = v((byte) 0);
        built[3] = v((byte) 1);
        built[4] = v((byte) 127);
        built[5] = v((byte) -2);
        built[6] = v((byte) 64);
        built[7] = v((byte) -100);
        return join(Arrays.equals(lit, built), Arrays.toString(lit), Arrays.hashCode(lit));
    }

    public static String fillShort() {
        short[] lit = {-32768, -1, 0, 300, 32767, -300};
        short[] built = new short[6];
        built[0] = v((short) -32768);
        built[1] = v((short) -1);
        built[2] = v((short) 0);
        built[3] = v((short) 300);
        built[4] = v((short) 32767);
        built[5] = v((short) -300);
        return join(Arrays.equals(lit, built), Arrays.toString(lit), Arrays.hashCode(lit));
    }

    public static String fillChar() {
        char[] lit = {'a', '\uffff', 0, '\u8000', 'z', '\u00e9'};
        char[] built = new char[6];
        built[0] = v('a');
        built[1] = v('\uffff');
        built[2] = v((char) 0);
        built[3] = v('\u8000');
        built[4] = v('z');
        built[5] = v('\u00e9');
        int[] codes = new int[lit.length];
        for (int i = 0; i < lit.length; i++) codes[i] = lit[i];
        return join(Arrays.equals(lit, built), Arrays.toString(codes), Arrays.hashCode(lit));
    }

    public static String fillInt() {
        int[] lit = {-1, 2, -3, Integer.MIN_VALUE, Integer.MAX_VALUE, 0, -65536};
        int[] built = new int[7];
        built[0] = v(-1);
        built[1] = v(2);
        built[2] = v(-3);
        built[3] = v(Integer.MIN_VALUE);
        built[4] = v(Integer.MAX_VALUE);
        built[5] = v(0);
        built[6] = v(-65536);
        return join(Arrays.equals(lit, built), Arrays.toString(lit), Arrays.hashCode(lit));
    }

    public static String fillLong() {
        long[] lit = {-1L, Long.MIN_VALUE, 0x123456789L, Long.MAX_VALUE, -4294967296L, 0L};
        long[] built = new long[6];
        built[0] = v(-1L);
        built[1] = v(Long.MIN_VALUE);
        built[2] = v(0x123456789L);
        built[3] = v(Long.MAX_VALUE);
        built[4] = v(-4294967296L);
        built[5] = v(0L);
        return join(Arrays.equals(lit, built), Arrays.toString(lit), Arrays.hashCode(lit));
    }

    public static String fillFloat() {
        float[] lit = {-1.5f, 0f, -0f, Float.NaN, Float.NEGATIVE_INFINITY, 3.25f, -1e-45f};
        float[] built = new float[7];
        built[0] = v(-1.5f);
        built[1] = v(0f);
        built[2] = v(-0f);
        built[3] = v(Float.NaN);
        built[4] = v(Float.NEGATIVE_INFINITY);
        built[5] = v(3.25f);
        built[6] = v(-1e-45f);
        StringBuilder bits = new StringBuilder();
        for (float x : lit) bits.append(Fmt.f(x)).append(' ');
        return join(Arrays.equals(lit, built), bits.toString().trim(), Arrays.hashCode(lit));
    }

    public static String fillDouble() {
        double[] lit = {-1.5, 0.0, -0.0, Double.NaN, Double.POSITIVE_INFINITY, -1e300, 4.9e-324};
        double[] built = new double[7];
        built[0] = v(-1.5);
        built[1] = v(0.0);
        built[2] = v(-0.0);
        built[3] = v(Double.NaN);
        built[4] = v(Double.POSITIVE_INFINITY);
        built[5] = v(-1e300);
        built[6] = v(4.9e-324);
        StringBuilder bits = new StringBuilder();
        for (double x : lit) bits.append(Fmt.d(x)).append(' ');
        return join(Arrays.equals(lit, built), bits.toString().trim(), Arrays.hashCode(lit));
    }

    public static String fillBoolean() {
        boolean[] lit = {true, false, true, true, false, false, true};
        boolean[] built = new boolean[7];
        built[0] = v(true);
        built[1] = v(false);
        built[2] = v(true);
        built[3] = v(true);
        built[4] = v(false);
        built[5] = v(false);
        built[6] = v(true);
        return join(Arrays.equals(lit, built), Arrays.toString(lit), Arrays.hashCode(lit));
    }

    public static String filledNewArray() {
        int a = v(-7);
        int b = v(8);
        int[] small = {a, b, a + b};
        String[] refs = {v("x"), null, v("z")};
        return join(Arrays.toString(small), Arrays.toString(refs), small.getClass().getName(), refs.getClass().getName());
    }

    public static String covariantStore() {
        Object[] objects = new String[2];
        objects[0] = "ok";
        objects[1] = null;
        try {
            objects[1] = Integer.valueOf(1);
            return "stored";
        } catch (ArrayStoreException e) {
            return join("ASE", objects[0], objects[1]);
        }
    }

    public static String covariantStoreEscapes() {
        Object[] numbers = new Integer[1];
        numbers[0] = Long.valueOf(1);
        return "stored";
    }

    public static String covariantStoreInterfaceArray() {
        Object[] seq = new CharSequence[2];
        seq[0] = "s";
        seq[1] = new StringBuilder("b");
        try {
            seq[0] = new Object();
            return "stored";
        } catch (ArrayStoreException e) {
            return join("ASE", seq.length);
        }
    }

    public static String negativeArraySize() {
        int[] array = new int[v(-1)];
        return Integer.toString(array.length);
    }

    public static String negativeArraySizeCaught() {
        StringBuilder out = new StringBuilder();
        try {
            Object x = new String[v(-5)];
            out.append(x != null);
        } catch (NegativeArraySizeException e) {
            out.append("NASE1;");
        }
        try {
            Object x = new int[v(2)][v(-1)];
            out.append(x != null);
        } catch (NegativeArraySizeException e) {
            out.append("NASE2;");
        }
        try {
            Object x = Array.newInstance(int.class, v(-3));
            out.append(x != null);
        } catch (NegativeArraySizeException e) {
            out.append("NASE3;");
        }
        Object empty = new long[v(0)];
        out.append(Array.getLength(empty));
        return out.toString();
    }

    public static String indexOutOfBounds() {
        int[] array = new int[3];
        StringBuilder out = new StringBuilder();
        for (int index : new int[] {-1, 3, Integer.MIN_VALUE, 2}) {
            try {
                array[index] = 1;
                out.append("ok").append(index).append(';');
            } catch (ArrayIndexOutOfBoundsException e) {
                out.append(name(e)).append(';');
            }
        }
        return out.toString();
    }

    public static String indexOutOfBoundsEscapes() {
        long[] array = new long[2];
        return Long.toString(array[v(2)]);
    }

    public static String nullArrayAccess() {
        StringBuilder out = new StringBuilder();
        int[] array = (int[]) o(null);
        try {
            out.append(array.length);
        } catch (NullPointerException e) {
            out.append("len;");
        }
        try {
            out.append(array[0]);
        } catch (NullPointerException e) {
            out.append("get;");
        }
        try {
            array[0] = 1;
        } catch (NullPointerException e) {
            out.append("put;");
        }
        return out.toString();
    }

    public static String multiDimensional() {
        int[][] grid = new int[v(2)][v(3)];
        grid[1][2] = 5;
        return join(grid.length, grid[0].length, grid[1].length, grid[0] != grid[1], grid[1][2], grid[0][2],
            grid.getClass().getName(), grid[0].getClass().getName());
    }

    public static String multiDimensionalPartial() {
        int[][] rows = new int[v(2)][];
        String[][][] cube = new String[v(2)][v(3)][v(4)];
        long[][][] partial = new long[v(1)][v(2)][];
        return join(rows[0] == null, rows[1] == null, cube[1][2].length, cube[1][2][3] == null, cube.getClass().getName(),
            partial[0][1] == null, partial[0].getClass().getName());
    }

    public static String cloneArrays() {
        int[] a = {1, 2, 3, 4, 5};
        int[] c = a.clone();
        c[0] = 99;
        String[] s = {"a", "b"};
        Object[] sc = s.clone();
        int[][] nested = {{1}, {2}};
        int[][] shallow = nested.clone();
        return join(c != a, a[0], c[0], Arrays.equals(Arrays.copyOfRange(a, 1, 5), Arrays.copyOfRange(c, 1, 5)),
            sc.getClass().getName(), shallow[0] == nested[0], shallow != nested);
    }

    public static String arrayInstanceOf() {
        Object ints = new int[1];
        Object grid = new int[1][1];
        Object strings = new String[1];
        Object integers = new Integer[1];
        Object numbers = new Number[1];
        return join(ints instanceof Object[], ints instanceof Cloneable, ints instanceof Serializable, grid instanceof Object[],
            grid instanceof Cloneable[], strings instanceof Object[], strings instanceof CharSequence[],
            strings instanceof Comparable[], integers instanceof Number[], numbers instanceof Integer[], grid instanceof int[][],
            ints instanceof long[]);
    }

    public static String arrayCasts() {
        StringBuilder out = new StringBuilder();
        Object grid = new int[1][];
        Object[] asObjects = (Object[]) grid;
        out.append(asObjects.length).append(';');
        try {
            String[] s = (String[]) o(new Object[1]);
            out.append(s.length);
        } catch (ClassCastException e) {
            out.append("CCE1;");
        }
        try {
            Integer[] s = (Integer[]) o(new Number[1]);
            out.append(s.length);
        } catch (ClassCastException e) {
            out.append("CCE2;");
        }
        Comparable<?>[] cmp = (Comparable<?>[]) o(new String[3]);
        out.append(cmp.length);
        return out.toString();
    }

    public static String arrayClassShape() {
        Class<?> c = int[].class;
        Class<?>[] interfaces = c.getInterfaces();
        StringBuilder names = new StringBuilder();
        for (Class<?> i : interfaces) names.append(i.getName()).append(' ');
        return join(c.getSuperclass().getName(), names.toString().trim(), c.getComponentType().getName(), c.isArray(),
            String[][].class.getComponentType().getName(), modifiers(c));
    }

    private static String modifiers(Class<?> c) {
        int mods = c.getModifiers();
        return join(java.lang.reflect.Modifier.isPublic(mods), java.lang.reflect.Modifier.isFinal(mods),
            java.lang.reflect.Modifier.isAbstract(mods));
    }

    public static String defaultValues() {
        char[] c = new char[1];
        boolean[] z = new boolean[1];
        float[] f = new float[1];
        double[] d = new double[1];
        Object[] objects = new Object[1];
        long[] l = new long[1];
        return join((int) c[0], z[0], Fmt.f(f[0]), Fmt.d(d[0]), objects[0], l[0]);
    }

    public static String arraycopyOverlap() {
        int[] a = {1, 2, 3, 4, 5, 6};
        System.arraycopy(a, 0, a, 1, 5);
        int[] b = {1, 2, 3, 4, 5, 6};
        System.arraycopy(b, 1, b, 0, 5);
        return join(Arrays.toString(a), Arrays.toString(b));
    }

    public static String arraycopyStoreCheck() {
        Object[] source = {"a", "b", Integer.valueOf(3), "d"};
        String[] target = new String[4];
        try {
            System.arraycopy(source, 0, target, 0, 4);
            return "copied";
        } catch (ArrayStoreException e) {
            return join("ASE", Arrays.toString(target));
        }
    }

    public static String arraycopyTypeMismatch() {
        StringBuilder out = new StringBuilder();
        try {
            System.arraycopy(new int[2], 0, new long[2], 0, 2);
        } catch (ArrayStoreException e) {
            out.append("ASE1;");
        }
        try {
            System.arraycopy(new int[2], 0, new Object[2], 0, 2);
        } catch (ArrayStoreException e) {
            out.append("ASE2;");
        }
        try {
            System.arraycopy(new int[2], 1, new int[2], 0, 2);
        } catch (IndexOutOfBoundsException e) {
            out.append("IOOBE;");
        }
        try {
            System.arraycopy(null, 0, new int[2], 0, 0);
        } catch (NullPointerException e) {
            out.append("NPE;");
        }
        return out.toString();
    }

    public static String reflectiveArrays() {
        Object ints = Array.newInstance(int.class, 3);
        Array.setInt(ints, 1, -9);
        Object grid = Array.newInstance(String.class, 2, 2);
        StringBuilder out = new StringBuilder();
        out.append(ints.getClass().getName()).append(';').append(Array.get(ints, 1)).append(';')
            .append(Array.get(ints, 1).getClass().getSimpleName()).append(';').append(grid.getClass().getName()).append(';');
        try {
            Array.set(ints, 0, "x");
        } catch (IllegalArgumentException e) {
            out.append("IAE;");
        }
        Array.set(ints, 2, Byte.valueOf((byte) 7));
        out.append(Array.getInt(ints, 2)).append(';').append(Array.getLong(ints, 1));
        return out.toString();
    }

    public static String arraysUtilities() {
        int[] a = {5, -1, 3, -1, 0};
        Arrays.sort(a);
        Integer[] boxed = {3, 1, 2};
        Arrays.sort(boxed, (x, y) -> y - x);
        long[] filled = new long[3];
        Arrays.fill(filled, -2L);
        return join(Arrays.toString(a), Arrays.binarySearch(a, 3), Arrays.toString(boxed), Arrays.toString(filled),
            Arrays.asList(boxed).indexOf(1), Arrays.deepToString(new int[][] {{1}, {2, 3}}),
            Arrays.equals(new Object[] {"a", null}, new Object[] {"a", null}), Arrays.hashCode((int[]) null));
    }
}
