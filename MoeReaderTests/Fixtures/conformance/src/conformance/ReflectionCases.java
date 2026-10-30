package conformance;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.List;
import java.util.Map;

import static conformance.Fmt.join;
import static conformance.Fmt.name;

public final class ReflectionCases {
    private ReflectionCases() {}

    public static final class Member {
        public int x = 3;
        private String secret = "hidden";
        public static long counter;

        public Member() {}

        public Member(int x) { this.x = x; }

        public static int add(int a, long b) { return (int) (a + b); }

        public static double twice(double d) { return d * 2; }

        public static boolean not(boolean z) { return !z; }

        public static char next(char c) { return (char) (c + 1); }

        public String echo(String s, int times) { return s.repeat(times); }

        public static void fail() { throw new IllegalStateException("inner"); }

        public static int[] array(int n) { return new int[n]; }

        private String hiddenMethod() { return "private:" + secret; }

        public List<String> generic(Map<String, Integer> map) { return null; }
    }

    interface Marker {}

    static class Inner {}

    public static class Parent {
        public static int shared = 41;
        public int inherited = 9;
    }

    public static final class Child extends Parent {
        public static int own = 7;
    }

    public static String inheritedFields() throws Exception {
        Field shared = Child.class.getField("shared");
        Object boxed = shared.get(null);
        shared.setInt(null, 12);
        Child child = new Child();
        Field inherited = Child.class.getField("inherited");
        inherited.setInt(child, 14);
        String absent;
        try {
            Child.class.getDeclaredField("shared");
            absent = "unexpected";
        } catch (NoSuchFieldException expected) {
            absent = "declared-only";
        }
        return join(boxed, boxed.getClass().getSimpleName(), shared.getDeclaringClass() == Parent.class,
            Parent.shared, Child.own, inherited.getInt(child), inherited.getDeclaringClass() == Parent.class, absent);
    }
    public static String simpleNames() {
        class Local {}
        Object anonymous = new Object() {};
        Runnable anonymousInterface = new Runnable() { public void run() {} };
        return join("[" + Member.class.getSimpleName() + "]", "[" + Local.class.getSimpleName() + "]",
            "[" + anonymous.getClass().getSimpleName() + "]", "[" + anonymousInterface.getClass().getSimpleName() + "]",
            String[].class.getSimpleName(), int[][].class.getSimpleName(), Local[].class.getSimpleName(), int.class.getSimpleName());
    }

    public static String classKinds() {
        class Local {}
        Object anonymous = new Object() {};
        return join(Member.class.isMemberClass(), Local.class.isLocalClass(), anonymous.getClass().isAnonymousClass(),
            Local.class.isMemberClass(), anonymous.getClass().isLocalClass(), ReflectionCases.class.isMemberClass(),
            Marker.class.isInterface(), Marker.class.isMemberClass());
    }

    public static String enclosingAndDeclaringClasses() {
        class Local {}
        Object anonymous = new Object() {};
        return join(Member.class.getDeclaringClass().getSimpleName(), Member.class.getEnclosingClass().getSimpleName(),
            Local.class.getDeclaringClass(), Local.class.getEnclosingClass().getSimpleName(),
            anonymous.getClass().getDeclaringClass(), anonymous.getClass().getEnclosingClass().getSimpleName(),
            ReflectionCases.class.getDeclaringClass(), Local.class.getEnclosingMethod().getName());
    }

    public static String classNames() {
        return join(int[].class.getName(), String[][].class.getName(), Member[].class.getName(), int.class.getName(),
            void.class.getName(), Member.class.getName(), boolean[].class.getName(), double[][][].class.getName(),
            char[].class.getName(), Map.Entry.class.getName());
    }

    public static String primitiveClassIdentity() {
        return join(int.class == Integer.TYPE, void.class == Void.TYPE, long.class == Long.TYPE, int.class.isPrimitive(),
            Integer.class.isPrimitive(), int[].class.isPrimitive(), void.class.isPrimitive(), int.class == Integer.class,
            int[].class.getComponentType() == int.class);
    }

    public static String forName() throws Exception {
        StringBuilder out = new StringBuilder();
        out.append(Class.forName("conformance.ReflectionCases$Member").getSimpleName()).append(';')
            .append(Class.forName("[I").getName()).append(';').append(Class.forName("[Ljava.lang.String;").getSimpleName()).append(';');
        try {
            Class.forName("conformance.DoesNotExist");
        } catch (ClassNotFoundException e) {
            out.append("CNFE;");
        }
        try {
            Class.forName("int");
        } catch (ClassNotFoundException e) {
            out.append("CNFE-primitive;");
        }
        return out.toString();
    }

    public static String superclassesAndInterfaces() {
        StringBuilder interfaces = new StringBuilder();
        for (Class<?> c : Integer.class.getInterfaces()) interfaces.append(c.getSimpleName()).append(' ');
        return join(Integer.class.getSuperclass().getName(), Object.class.getSuperclass(), Runnable.class.getSuperclass(),
            int.class.getSuperclass(), Member.class.getSuperclass().getSimpleName(), interfaces.toString().contains("Comparable"),
            Marker.class.getInterfaces().length);
    }

    public static String methodInvokePrimitives() throws Exception {
        Method add = Member.class.getMethod("add", int.class, long.class);
        Method twice = Member.class.getMethod("twice", double.class);
        Method not = Member.class.getMethod("not", boolean.class);
        Method next = Member.class.getMethod("next", char.class);
        Object sum = add.invoke(null, 2, 3L);
        Object widened = add.invoke(null, (byte) 4, 5);
        Object doubled = twice.invoke(null, 1.25f);
        Object negated = not.invoke(null, true);
        Object nextChar = next.invoke(null, 'a');
        return join(sum, sum.getClass().getSimpleName(), widened, Fmt.d((Double) doubled), negated, nextChar,
            nextChar.getClass().getSimpleName());
    }

    public static String methodInvokeArgumentMismatch() throws Exception {
        Method add = Member.class.getMethod("add", int.class, long.class);
        StringBuilder out = new StringBuilder();
        try {
            add.invoke(null, 1L, 2L);
        } catch (IllegalArgumentException e) {
            out.append("narrowing;");
        }
        try {
            add.invoke(null, 1);
        } catch (IllegalArgumentException e) {
            out.append("count;");
        }
        try {
            add.invoke(null, null, 2L);
        } catch (IllegalArgumentException e) {
            out.append("null-primitive;");
        }
        try {
            add.invoke(null, "1", 2L);
        } catch (IllegalArgumentException e) {
            out.append("type;");
        }
        return out.toString();
    }

    public static String methodInvokeInstance() throws Exception {
        Method echo = Member.class.getMethod("echo", String.class, int.class);
        Member target = new Member();
        StringBuilder out = new StringBuilder();
        out.append(echo.invoke(target, "ab", 2)).append(';');
        try {
            echo.invoke(null, "ab", 2);
        } catch (NullPointerException e) {
            out.append("NPE;");
        }
        try {
            echo.invoke("wrong receiver", "ab", 2);
        } catch (IllegalArgumentException e) {
            out.append("IAE;");
        }
        Method toString = Object.class.getMethod("toString");
        out.append(toString.invoke("virtual"));
        return out.toString();
    }

    public static String invocationTargetCause() throws Exception {
        Method fail = Member.class.getMethod("fail");
        try {
            fail.invoke(null);
            return "none";
        } catch (InvocationTargetException e) {
            return join(name(e), name(e.getCause()), name(e.getTargetException()), e.getCause().getMessage());
        }
    }

    public static String constructorReflection() throws Exception {
        Constructor<Member> withInt = Member.class.getConstructor(int.class);
        Member m = withInt.newInstance(9);
        Member d = Member.class.getDeclaredConstructor().newInstance();
        return join(m.x, d.x, withInt.getParameterCount(), withInt.getDeclaringClass().getSimpleName(),
            Member.class.getConstructors().length);
    }

    public static String fieldReflection() throws Exception {
        Field x = Member.class.getField("x");
        Field counter = Member.class.getField("counter");
        Field secret = Member.class.getDeclaredField("secret");
        Member m = new Member(4);
        x.setInt(m, 11);
        counter.setLong(null, -3L);
        secret.setAccessible(true);
        String before = (String) secret.get(m);
        secret.set(m, "changed");
        StringBuilder out = new StringBuilder();
        out.append(join(m.x, Member.counter, before, secret.get(m), x.getType().getName(), counter.getType() == long.class,
            Modifier.toString(counter.getModifiers()), Modifier.toString(secret.getModifiers())));
        try {
            Member.class.getField("secret");
        } catch (NoSuchFieldException e) {
            out.append(";NSFE");
        }
        try {
            x.set(m, "string");
        } catch (IllegalArgumentException e) {
            out.append(";IAE");
        }
        return out.toString();
    }

    public static String privateMethodAccess() throws Exception {
        Method hidden = Member.class.getDeclaredMethod("hiddenMethod");
        hidden.setAccessible(true);
        StringBuilder out = new StringBuilder();
        out.append(hidden.invoke(new Member())).append(';').append(Modifier.isPrivate(hidden.getModifiers()));
        try {
            Member.class.getMethod("hiddenMethod");
        } catch (NoSuchMethodException e) {
            out.append(";NSME");
        }
        return out.toString();
    }

    public static String methodMetadata() throws Exception {
        Method add = Member.class.getMethod("add", int.class, long.class);
        Method array = Member.class.getMethod("array", int.class);
        StringBuilder params = new StringBuilder();
        for (Class<?> p : add.getParameterTypes()) params.append(p.getName()).append(' ');
        return join(add.getName(), add.getReturnType() == int.class, params.toString().trim(), add.getParameterCount(),
            Modifier.toString(add.getModifiers()), array.getReturnType().getName(), add.getDeclaringClass().getSimpleName(),
            Member.class.getMethod("hashCode").getDeclaringClass().getName());
    }

    public static String genericSignatures() throws Exception {
        Method generic = Member.class.getMethod("generic", Map.class);
        return join(generic.getGenericReturnType().getTypeName(), generic.getGenericParameterTypes()[0].getTypeName(),
            generic.getReturnType().getName());
    }

    public static String modifiersOfClasses() {
        return join(Modifier.toString(Member.class.getModifiers()), Modifier.isStatic(Inner.class.getModifiers()),
            Modifier.isInterface(Marker.class.getModifiers()), Modifier.isAbstract(Marker.class.getModifiers()),
            Modifier.isFinal(ReflectionCases.class.getModifiers()), Modifier.isFinal(int.class.getModifiers()));
    }

    enum Suit { CLUBS, HEARTS }

    public static String enumReflection() {
        Suit[] constants = Suit.class.getEnumConstants();
        return join(Suit.class.isEnum(), constants.length, constants[1], Suit.HEARTS.getDeclaringClass() == Suit.class,
            Suit.class.getSuperclass().getName(), Member.class.getEnumConstants());
    }

    public static String getClassOnValues() {
        Object[] values = {1, 1L, 'c', 1.5f, true, "s", new int[0], new Object[0][0]};
        StringBuilder out = new StringBuilder();
        for (Object v : values) out.append(v.getClass().getName()).append(' ');
        return out.toString().trim();
    }

    public static String arrayAndNestedLibraryClasses() {
        return join(int[].class.getDeclaredFields().length, int[].class.getDeclaredMethods().length,
            Map.Entry.class.getEnclosingClass().getSimpleName(), Map.Entry.class.getSimpleName());
    }
}
