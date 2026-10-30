package conformance;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.invoke.WrongMethodTypeException;
import java.lang.invoke.VarHandle;
import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.List;

import static conformance.Fmt.join;
import static conformance.Fmt.name;
import static java.lang.invoke.MethodType.methodType;

/** java.lang.invoke; javac's signature-polymorphic calls become invoke-polymorphic. */
public final class MethodHandleCases {
    private MethodHandleCases() {}

    public static final class Point {
        public int x;
        public static String label = "init";
        public static long total;

        public Point(int x) { this.x = x; }

        public Point(int x, int y) { this.x = x * 100 + y; }

        public int scaled(int factor) { return x * factor; }

        private String secret() { return "secret" + x; }
    }

    public static int add(int a, int b) { return a + b; }

    public static long addLong(long a, long b) { return a + b; }

    public static String describe(Object o, int i) { return o + "#" + i; }

    public static void sideEffect(StringBuilder sb, String text) { sb.append(text); }

    public static double half(double d) { return d / 2; }

    public static String join3(String a, String b, String c) { return a + b + c; }

    public static int count(String... parts) { return parts.length; }

    public static final class Variables {
        public int number = 3;
        public static long total = 5;
        public float floating = -0.0f;
        public final int readOnly = 11;
    }

    public static String varHandleFields() throws Throwable {
        MethodHandles.Lookup lookup = MethodHandles.lookup();
        VarHandle number = lookup.findVarHandle(Variables.class, "number", int.class);
        VarHandle total = lookup.findStaticVarHandle(Variables.class, "total", long.class);
        Variables v = new Variables();
        int old = (int) number.getAndAdd(v, 4);
        boolean failed = number.compareAndSet(v, 3, 99);
        boolean changed = number.compareAndSet(v, 7, -2);
        int witness = (int) number.compareAndExchange(v, -2, 8);
        long previous = (long) total.getAndAdd(7L);
        return join(old, failed, changed, witness, number.getVolatile(v), previous, total.getAcquire(),
            number.varType(), number.coordinateTypes().size(), total.coordinateTypes().size());
    }

    public static String varHandleArrayRange() throws Throwable {
        VarHandle longs = MethodHandles.arrayElementVarHandle(long[].class);
        long[] values = {Long.MIN_VALUE, -1L};
        long witness = (long) longs.compareAndExchange(values, 0, Long.MIN_VALUE, Long.MAX_VALUE);
        long before = (long) longs.getAndBitwiseXor(values, 1, 0xffL);
        longs.setRelease(values, 0, 9L);
        return join(witness, before, (long) longs.getAcquire(values, 0), values[1]);
    }

    public static String varHandleFloatBits() throws Throwable {
        VarHandle floating = MethodHandles.lookup().findVarHandle(Variables.class, "floating", float.class);
        Variables v = new Variables();
        boolean wrongZero = floating.compareAndSet(v, 0.0f, 1.0f);
        boolean rightZero = floating.compareAndSet(v, -0.0f, Float.intBitsToFloat(0x7fc00001));
        boolean wrongNaN = floating.compareAndSet(v, Float.NaN, 2.0f);
        boolean rightNaN = floating.compareAndSet(v, Float.intBitsToFloat(0x7fc00001), 3.0f);
        return join(wrongZero, rightZero, wrongNaN, rightNaN, (float) floating.get(v));
    }

    public static String varHandleErrors() throws Throwable {
        VarHandle ints = MethodHandles.arrayElementVarHandle(int[].class);
        VarHandle references = MethodHandles.arrayElementVarHandle(Object[].class);
        StringBuilder out = new StringBuilder();
        try { int ignored = (int) ints.get(new int[1], 1); } catch (ArrayIndexOutOfBoundsException e) { out.append("bounds;"); }
        try { int ignored = (int) ints.get((int[]) null, 0); } catch (NullPointerException e) { out.append("null;"); }
        try { ints.set(new int[1], 0, 1L); } catch (WrongMethodTypeException e) { out.append("type;"); }
        try { references.set(new String[1], 0, new Object()); } catch (ArrayStoreException e) { out.append("store;"); }
        return out.toString();
    }

    public static String varHandleReadOnly() throws Throwable {
        VarHandle readOnly = MethodHandles.lookup().findVarHandle(Variables.class, "readOnly", int.class);
        Variables v = new Variables();
        StringBuilder out = new StringBuilder().append((int) readOnly.get(v));
        try { readOnly.set(v, 12); } catch (UnsupportedOperationException e) { out.append(";set"); }
        try { int ignored = (int) readOnly.getAndAdd(v, 1); } catch (UnsupportedOperationException e) { out.append(";add"); }
        return out.append(';').append((int) readOnly.get(v)).toString();
    }
    private static MethodHandle addHandle() throws Exception {
        return MethodHandles.lookup().findStatic(MethodHandleCases.class, "add", methodType(int.class, int.class, int.class));
    }

    public static String findStaticInvokeExact() throws Throwable {
        MethodHandle add = addHandle();
        int sum = (int) add.invokeExact(2, 3);
        MethodHandle addLong = MethodHandles.lookup().findStatic(MethodHandleCases.class, "addLong",
            methodType(long.class, long.class, long.class));
        long big = (long) addLong.invokeExact(Long.MAX_VALUE, -1L);
        return join(sum, big, add.type());
    }

    public static String findVirtualInvokeExact() throws Throwable {
        MethodHandles.Lookup lookup = MethodHandles.lookup();
        MethodHandle concat = lookup.findVirtual(String.class, "concat", methodType(String.class, String.class));
        MethodHandle length = lookup.findVirtual(String.class, "length", methodType(int.class));
        MethodHandle scaled = lookup.findVirtual(Point.class, "scaled", methodType(int.class, int.class));
        MethodHandle listSize = lookup.findVirtual(List.class, "size", methodType(int.class));
        String joined = (String) concat.invokeExact("a", "b");
        int len = (int) length.invokeExact("abcd");
        int s = (int) scaled.invokeExact(new Point(3), 7);
        int size = (int) listSize.invokeExact(List.of(1, 2, 3));
        return join(joined, len, s, size, concat.type(), listSize.type());
    }

    public static String findConstructor() throws Throwable {
        MethodHandles.Lookup lookup = MethodHandles.lookup();
        MethodHandle one = lookup.findConstructor(Point.class, methodType(void.class, int.class));
        MethodHandle two = lookup.findConstructor(Point.class, methodType(void.class, int.class, int.class));
        MethodHandle builder = lookup.findConstructor(StringBuilder.class, methodType(void.class, String.class));
        Point p = (Point) one.invokeExact(4);
        Point q = (Point) two.invokeExact(1, 2);
        StringBuilder sb = (StringBuilder) builder.invokeExact("sb");
        return join(p.x, q.x, sb, one.type(), builder.type());
    }

    public static String fieldHandles() throws Throwable {
        MethodHandles.Lookup lookup = MethodHandles.lookup();
        MethodHandle getter = lookup.findGetter(Point.class, "x", int.class);
        MethodHandle setter = lookup.findSetter(Point.class, "x", int.class);
        MethodHandle staticSetter = lookup.findStaticSetter(Point.class, "label", String.class);
        MethodHandle staticGetter = lookup.findStaticGetter(Point.class, "label", String.class);
        MethodHandle totalSetter = lookup.findStaticSetter(Point.class, "total", long.class);
        Point p = new Point(5);
        int before = (int) getter.invokeExact(p);
        setter.invokeExact(p, -9);
        staticSetter.invokeExact("set");
        String label = (String) staticGetter.invokeExact();
        totalSetter.invokeExact(-5L);
        return join(before, p.x, label, Point.label, Point.total, getter.type(), setter.type(), staticSetter.type(),
            staticGetter.type());
    }

    public static String invokeWithBoxingAndWidening() throws Throwable {
        MethodHandle add = addHandle();
        Object boxed = add.invoke(Integer.valueOf(2), 3);
        long widened = (long) add.invoke(4, 5);
        int fromSmall = (int) add.invoke((byte) 1, (short) 2);
        double asDouble = (double) add.invoke('a', 1);
        Integer boxedResult = (Integer) add.invoke(10, 20);
        MethodHandle half = MethodHandles.lookup().findStatic(MethodHandleCases.class, "half", methodType(double.class, double.class));
        double fromInt = (double) half.invoke(3);
        Object fromLong = half.invoke(8L);
        return join(boxed, boxed.getClass().getSimpleName(), widened, fromSmall, Fmt.d(asDouble), boxedResult,
            Fmt.d(fromInt), fromLong);
    }

    public static String invokeUnboxingFailures() throws Throwable {
        MethodHandle add = addHandle();
        StringBuilder out = new StringBuilder();
        try {
            Object nothing = null;
            out.append((int) add.invoke(nothing, 1));
        } catch (NullPointerException e) {
            out.append("NPE;");
        }
        try {
            Object text = "x";
            out.append((int) add.invoke(text, 1));
        } catch (ClassCastException e) {
            out.append("CCE;");
        }
        try {
            out.append((int) add.invoke(1L, 1));
        } catch (WrongMethodTypeException e) {
            out.append("WMTE;");
        }
        MethodHandle concat = MethodHandles.lookup().findVirtual(String.class, "concat", methodType(String.class, String.class));
        try {
            Object arg = 1;
            out.append((String) concat.invoke("a", arg));
        } catch (ClassCastException e) {
            out.append("CCE2;");
        }
        return out.toString();
    }

    public static String bindTo() throws Throwable {
        MethodHandle concat = MethodHandles.lookup().findVirtual(String.class, "concat", methodType(String.class, String.class));
        MethodHandle bound = concat.bindTo("x");
        MethodHandle describe = MethodHandles.lookup().findStatic(MethodHandleCases.class, "describe",
            methodType(String.class, Object.class, int.class));
        MethodHandle boundDescribe = describe.bindTo("obj");
        return join((String) bound.invokeExact("y"), bound.type(), (String) boundDescribe.invokeExact(4), boundDescribe.type());
    }

    public static String bindToPrimitiveFails() throws Throwable {
        return addHandle().bindTo(1).type().toString();
    }

    public static String insertArguments() throws Throwable {
        MethodHandle add = addHandle();
        MethodHandle plusTen = MethodHandles.insertArguments(add, 1, 10);
        MethodHandle constant = MethodHandles.insertArguments(add, 0, 1, 2);
        MethodHandle join3 = MethodHandles.lookup().findStatic(MethodHandleCases.class, "join3",
            methodType(String.class, String.class, String.class, String.class));
        MethodHandle middle = MethodHandles.insertArguments(join3, 1, "-");
        return join((int) plusTen.invokeExact(5), plusTen.type(), (int) constant.invokeExact(), (String) middle.invokeExact("a", "b"));
    }

    public static String asType() throws Throwable {
        MethodHandle add = addHandle();
        MethodHandle generic = add.asType(methodType(Object.class, Object.class, Object.class));
        Object r = generic.invokeExact((Object) 1, (Object) 2);
        MethodHandle widenedReturn = add.asType(methodType(long.class, int.class, int.class));
        long l = (long) widenedReturn.invokeExact(3, 4);
        MethodHandle narrowArgs = add.asType(methodType(int.class, byte.class, char.class));
        int n = (int) narrowArgs.invokeExact((byte) -1, 'a');
        MethodHandle dropped = add.asType(methodType(void.class, int.class, int.class));
        dropped.invokeExact(1, 1);
        StringBuilder out = new StringBuilder(join(r, l, n, generic.type(), dropped.type()));
        try {
            add.asType(methodType(int.class, long.class, int.class));
        } catch (WrongMethodTypeException e) {
            out.append(";WMTE");
        }
        return out.toString();
    }

    public static String wrongInvokeExact() throws Throwable {
        MethodHandle add = addHandle();
        StringBuilder out = new StringBuilder();
        try {
            long wrong = (long) add.invokeExact(1, 2);
            out.append(wrong);
        } catch (WrongMethodTypeException e) {
            out.append("return;");
        }
        try {
            add.invokeExact(1, 2);
        } catch (WrongMethodTypeException e) {
            out.append("void;");
        }
        try {
            Object boxed = add.invokeExact(1, 2);
            out.append(boxed);
        } catch (WrongMethodTypeException e) {
            out.append("object;");
        }
        try {
            int narrow = (int) add.invokeExact((short) 1, 2);
            out.append(narrow);
        } catch (WrongMethodTypeException e) {
            out.append("arg;");
        }
        try {
            int arity = (int) add.invokeExact(1);
            out.append(arity);
        } catch (WrongMethodTypeException e) {
            out.append("arity;");
        }
        return out.toString();
    }

    public static String wrongInvokeExactEscapes() throws Throwable {
        MethodHandle add = addHandle();
        Integer boxed = (Integer) add.invokeExact(1, 2);
        return String.valueOf(boxed);
    }

    public static String methodTypeStrings() {
        MethodType a = methodType(void.class, int.class, String.class);
        MethodType b = methodType(int[].class);
        MethodType c = methodType(Object.class, long.class, double.class, boolean.class, char.class, byte.class, short.class, float.class);
        MethodType d = methodType(List.class, String[][].class, Point.class);
        return join(a, a.toMethodDescriptorString(), b, b.toMethodDescriptorString(), c, c.toMethodDescriptorString(), d,
            d.toMethodDescriptorString(), MethodType.genericMethodType(2));
    }

    public static String methodTypeOperations() {
        MethodType t = methodType(int.class, int.class, long.class);
        return join(t.parameterCount(), t.returnType(), t.parameterType(1), t.wrap(), t.wrap().unwrap(), t.changeReturnType(void.class),
            t.appendParameterTypes(String.class), t.dropParameterTypes(0, 1), t.insertParameterTypes(0, Object.class),
            t.erase(), t.generic(), t.hasPrimitives(), t.equals(methodType(int.class, int.class, long.class)),
            MethodType.fromMethodDescriptorString("(I[Ljava/lang/String;)J", null));
    }

    public static String combinators() throws Throwable {
        MethodHandle add = addHandle();
        MethodHandle seven = MethodHandles.constant(int.class, 7);
        MethodHandle identity = MethodHandles.identity(String.class);
        MethodHandle dropped = MethodHandles.dropArguments(add, 0, String.class);
        MethodHandle toText = MethodHandles.lookup().findStatic(String.class, "valueOf", methodType(String.class, int.class));
        MethodHandle filtered = MethodHandles.filterReturnValue(add, toText);
        MethodHandle doubled = MethodHandles.filterArguments(add, 0, MethodHandles.insertArguments(add, 0, 100));
        return join((int) seven.invokeExact(), (String) identity.invokeExact("id"), (int) dropped.invokeExact("ignored", 1, 2),
            dropped.type(), (String) filtered.invokeExact(20, 22), filtered.type(), (int) doubled.invokeExact(1, 2));
    }

    public static String invokeWithArguments() throws Throwable {
        MethodHandle add = addHandle();
        MethodHandle count = MethodHandles.lookup().findStatic(MethodHandleCases.class, "count",
            methodType(int.class, String[].class));
        return join(add.invokeWithArguments(3, 4), add.invokeWithArguments(Arrays.asList(5, 6)), count.isVarargsCollector(),
            count.invoke("a", "b", "c"), count.invokeWithArguments("x", "y"), count.invoke());
    }

    public static String voidHandles() throws Throwable {
        MethodHandle effect = MethodHandles.lookup().findStatic(MethodHandleCases.class, "sideEffect",
            methodType(void.class, StringBuilder.class, String.class));
        StringBuilder sb = new StringBuilder();
        effect.invokeExact(sb, "a");
        effect.invoke(sb, "b");
        Object result = effect.invoke(sb, "c");
        return join(sb, result, effect.type());
    }

    public static String unreflect() throws Throwable {
        Method m = MethodHandleCases.class.getMethod("add", int.class, int.class);
        MethodHandle h = MethodHandles.lookup().unreflect(m);
        MethodHandle ctor = MethodHandles.lookup().unreflectConstructor(Point.class.getConstructor(int.class));
        MethodHandle getter = MethodHandles.lookup().unreflectGetter(Point.class.getField("x"));
        Point p = (Point) ctor.invoke(12);
        return join((int) h.invokeExact(8, 9), h.type(), p.x, (int) getter.invokeExact(p));
    }

    public static String lookupFailures() throws Throwable {
        StringBuilder out = new StringBuilder();
        try {
            MethodHandles.lookup().findStatic(MethodHandleCases.class, "missing", methodType(void.class));
        } catch (NoSuchMethodException e) {
            out.append("NSME;");
        }
        try {
            MethodHandles.lookup().findStatic(MethodHandleCases.class, "add", methodType(long.class, int.class, int.class));
        } catch (NoSuchMethodException e) {
            out.append("NSME-type;");
        }
        try {
            MethodHandles.lookup().findVirtual(MethodHandleCases.class, "add", methodType(int.class, int.class, int.class));
        } catch (IllegalAccessException e) {
            out.append("IAE-static;");
        }
        try {
            MethodHandles.publicLookup().findVirtual(Point.class, "secret", methodType(String.class));
        } catch (IllegalAccessException e) {
            out.append("IAE-private;");
        }
        try {
            MethodHandles.lookup().findGetter(Point.class, "x", long.class);
        } catch (NoSuchFieldException e) {
            out.append("NSFE;");
        }
        try {
            MethodHandles.lookup().findStaticGetter(Point.class, "x", int.class);
        } catch (IllegalAccessException e) {
            out.append("IAE-instance-field;");
        }
        return out.toString();
    }

    public static String nullReceiverThroughHandle() throws Throwable {
        MethodHandle length = MethodHandles.lookup().findVirtual(String.class, "length", methodType(int.class));
        try {
            int n = (int) length.invokeExact((String) null);
            return Integer.toString(n);
        } catch (NullPointerException e) {
            return name(e);
        }
    }

    public static String exceptionsPropagateThroughHandles() throws Throwable {
        MethodHandle parse = MethodHandles.lookup().findStatic(Integer.class, "parseInt", methodType(int.class, String.class));
        try {
            int n = (int) parse.invokeExact("zz");
            return Integer.toString(n);
        } catch (NumberFormatException e) {
            return name(e);
        }
    }
}
