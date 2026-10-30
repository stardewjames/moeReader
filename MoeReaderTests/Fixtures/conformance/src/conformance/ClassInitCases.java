package conformance;

import static conformance.Fmt.join;
import static conformance.Fmt.name;

/**
 * Class initialization order (JLS 12.4, JVMS 5.5). Every case uses its own
 * helper classes so the cases stay independent of execution order; each
 * helper records its static initializer in {@link Trace}.
 */
public final class ClassInitCases {
    private ClassInitCases() {}

    static final class Trace {
        static final StringBuilder LOG = new StringBuilder();

        static int mark(String label) {
            LOG.append(label).append(';');
            return label.length();
        }

        static boolean yes() {
            return LOG != null;
        }

        static String take() {
            String result = LOG.toString();
            LOG.setLength(0);
            return result;
        }
    }

    // superBeforeSub
    static class A1 { static { Trace.mark("A1"); } }
    static class B1 extends A1 { static { Trace.mark("B1"); } }

    public static String superBeforeSub() {
        Trace.take();
        new B1();
        new B1();
        return Trace.take();
    }

    // subStaticFieldOfSuper
    static class A2 {
        static int F;
        static { Trace.mark("A2"); F = 5; }
    }
    static class B2 extends A2 { static { Trace.mark("B2"); } }

    public static String subStaticFieldOfSuper() {
        Trace.take();
        int value = B2.F;
        String first = Trace.take();
        new B2();
        return value + ":" + first + "|" + Trace.take();
    }

    // staticMethodOfSuperViaSub
    static class A3 {
        static { Trace.mark("A3"); }
        static String sm() { return "sm"; }
    }
    static class B3 extends A3 { static { Trace.mark("B3"); } }

    public static String staticMethodOfSuperViaSub() {
        Trace.take();
        String r = B3.sm();
        return r + ":" + Trace.take();
    }

    // Interfaces declaring default methods are initialized with an
    // implementing class; interfaces without them are not.
    interface I4 {
        int X = Trace.mark("I4");
        default String d() { return "d"; }
    }
    static class C4 implements I4 { static { Trace.mark("C4"); } }

    public static String interfaceWithDefaultInitialized() {
        Trace.take();
        new C4();
        return Trace.take();
    }

    interface I5 {
        int X = Trace.mark("I5");
        String m();
    }
    static class C5 implements I5 {
        static { Trace.mark("C5"); }
        public String m() { return "m"; }
    }

    public static String interfaceWithoutDefaultNotInitialized() {
        Trace.take();
        String r = new C5().m();
        String before = Trace.take();
        int x = I5.X;
        return r + ":" + before + "|" + x + ":" + Trace.take();
    }

    interface I6Super {
        int Y = Trace.mark("I6Super");
        default String e() { return "e"; }
    }
    interface I6 extends I6Super {
        int X = Trace.mark("I6");
        static String sm() { return "s"; }
    }

    public static String interfaceStaticMethodInitializesOnlyThatInterface() {
        Trace.take();
        String r = I6.sm();
        return r + ":" + Trace.take();
    }

    interface I13 {
        int X = Trace.mark("I13");
    }
    static class C13 implements I13 { static { Trace.mark("C13"); } }

    public static String interfaceFieldViaClassInitializesInterfaceOnly() {
        Trace.take();
        int x = C13.X;
        return x + ":" + Trace.take();
    }

    // <clinit> failures
    static class Bad7 {
        static int X;
        static {
            Trace.mark("Bad7");
            if (Trace.yes()) throw new IllegalStateException("bad");
        }
    }

    public static String initializerThrowsRuntimeException() {
        Trace.take();
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < 2; i++) {
            try {
                out.append(Bad7.X);
            } catch (Throwable t) {
                out.append(name(t));
                if (t instanceof ExceptionInInitializerError) {
                    out.append('/').append(name(t.getCause())).append('/').append(name(((ExceptionInInitializerError) t).getException()));
                }
                out.append(';');
            }
        }
        return out.append(Trace.take()).toString();
    }

    static class Bad8 {
        static { if (Trace.yes()) throw new AssertionError("err"); }
        static String sm() { return "sm"; }
    }

    public static String initializerThrowsError() {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < 2; i++) {
            try {
                out.append(Bad8.sm());
            } catch (Throwable t) {
                out.append(name(t)).append(';');
            }
        }
        return out.toString();
    }

    static class BadSuper9 { static { if (Trace.yes()) throw new ArithmeticException(); } }
    static class Sub9 extends BadSuper9 { static { Trace.mark("Sub9"); } }

    public static String superInitializerFailurePoisonsSubclass() {
        Trace.take();
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < 2; i++) {
            try {
                new Sub9();
                out.append("ok;");
            } catch (Throwable t) {
                out.append(name(t)).append(';');
            }
        }
        try {
            new BadSuper9();
        } catch (Throwable t) {
            out.append(name(t)).append(';');
        }
        return out.append(Trace.take()).toString();
    }

    public static String uncaughtInitializerFailure() {
        return Integer.toString(Bad10.X);
    }

    static class Bad10 {
        static int X = Integer.parseInt("not a number");
    }

    // An inherited <clinit> is never run for the subclass.
    static class A11 {
        static int sf = Trace.mark("A11");
    }
    static class B11 extends A11 {}

    public static String inheritedInitializerNotRerun() {
        Trace.take();
        new A11();
        new B11();
        int read = B11.sf;
        new B11();
        return read + ":" + Trace.take();
    }

    // Constant variables do not trigger initialization.
    static class C12 {
        static final int K = 7;
        static final String S = "s";
        static final long L = -1L;
        static { Trace.mark("C12"); }
        static int nonConstant = 1;
    }

    public static String constantsDoNotInitialize() {
        Trace.take();
        String constants = C12.K + C12.S + C12.L;
        String before = Trace.take();
        int nonConstant = C12.nonConstant;
        return constants + ":" + before + "|" + nonConstant + ":" + Trace.take();
    }

    static class C14 { static { Trace.mark("C14"); } }

    public static String arrayCreationAndClassLiteralDoNotInitialize() {
        Trace.take();
        C14[] array = new C14[3];
        Class<?> literal = C14.class;
        Class<?> arrayClass = C14[][].class;
        String before = Trace.take();
        Object instance = new C14();
        return array.length + literal.getSimpleName() + arrayClass.getSimpleName() + ":" + before + "|" + (instance != null)
            + ":" + Trace.take();
    }

    static class C15 { static { Trace.mark("C15"); } }
    static class C16 { static { Trace.mark("C16"); } }

    public static String classForNameInitializeFlag() throws Exception {
        Trace.take();
        Class<?> lazy = Class.forName("conformance.ClassInitCases$C15", false, ClassInitCases.class.getClassLoader());
        String afterLazy = Trace.take();
        Class.forName("conformance.ClassInitCases$C16");
        String afterEager = Trace.take();
        lazy.getDeclaredConstructor().newInstance();
        return afterLazy + "|" + afterEager + "|" + Trace.take();
    }

    // A class used while its own initializer runs sees default values.
    static class Recursive17 {
        static final Recursive17 INSTANCE = new Recursive17();
        static int counter = Trace.mark("counter17");
        final int seen;
        Recursive17() { seen = counter; }
    }

    public static String selfReferenceDuringInitialization() {
        Trace.take();
        return Recursive17.INSTANCE.seen + ":" + Recursive17.counter + ":" + Trace.take();
    }

    // Static initializers run in textual order.
    static class Order18 {
        static int a = Trace.mark("a");
        static { Trace.mark("block"); }
        static int b = Trace.mark("bb");
        static int c;
        static { c = a + b; }
    }

    public static String textualInitializerOrder() {
        Trace.take();
        return Order18.c + ":" + Trace.take();
    }

    interface I19Parent {
        int P = Trace.mark("I19Parent");
        default String p() { return "p"; }
    }
    interface I19 extends I19Parent {
        int X = Trace.mark("I19");
        default String q() { return "q"; }
    }
    static class A19 { static { Trace.mark("A19"); } }
    static class C19 extends A19 implements I19 { static { Trace.mark("C19"); } }

    public static String superclassThenDefaultInterfacesThenClass() {
        Trace.take();
        new C19();
        return Trace.take();
    }

    static class C20 {
        static { Trace.mark("C20"); }
        static String sm() { return "x"; }
    }

    public static String reflectiveInvokeInitializes() throws Exception {
        Trace.take();
        java.lang.reflect.Method m = C20.class.getDeclaredMethod("sm");
        String before = Trace.take();
        Object r = m.invoke(null);
        return before + "|" + r + ":" + Trace.take();
    }

    enum E21 {
        ONE, TWO;
        static { Trace.mark("E21"); }
        E21() { Trace.mark("ctor"); }
    }

    public static String enumInitialization() {
        Trace.take();
        return join(E21.TWO.ordinal(), Trace.take());
    }
}
