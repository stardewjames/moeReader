package conformance;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.function.Function;
import java.util.function.IntBinaryOperator;
import java.util.function.Supplier;

import static conformance.Fmt.join;
import static conformance.Fmt.o;

public final class InterfaceCases {
    private InterfaceCases() {}

    interface Named {
        default String m() { return "Named"; }
    }

    static class Base {
        public String m() { return "Base"; }
    }

    static class ClassWins extends Base implements Named {}

    public static String classMethodBeatsDefault() {
        Named n = new ClassWins();
        return join(n.m(), new ClassWins().m());
    }

    static class SuperCall implements Named {
        public String m() { return "SuperCall+" + Named.super.m(); }
    }

    public static String interfaceSuperCall() {
        return ((Named) new SuperCall()).m();
    }

    interface Top { default String who() { return "Top"; } }
    interface Left extends Top { default String who() { return "Left"; } }
    interface Right extends Top {}
    static class Diamond implements Left, Right {}
    static class DiamondReversed implements Right, Left {}

    public static String diamondMostSpecificDefault() {
        Top a = new Diamond();
        Right b = new DiamondReversed();
        return join(a.who(), b.who(), ((Top) new DiamondReversed()).who());
    }

    interface P { default String v() { return "P"; } }
    interface Q { default String v() { return "Q"; } }
    static class Resolved implements P, Q {
        public String v() { return P.super.v() + Q.super.v() + "!"; }
    }

    public static String conflictResolvedExplicitly() {
        P p = new Resolved();
        Q q = new Resolved();
        return join(p.v(), q.v());
    }

    abstract static class Reabstract implements Named {
        public abstract String m();
    }
    static class Concrete extends Reabstract {
        public String m() { return "Concrete"; }
    }

    public static String abstractClassReabstractsDefault() {
        Named n = new Concrete();
        return n.m();
    }

    interface WithPrivate {
        default String greet() { return helper() + "/" + staticHelper(); }
        private String helper() { return "private"; }
        private static String staticHelper() { return "privateStatic"; }
        static String util() { return "static"; }
    }
    static class UsesPrivate implements WithPrivate {}

    public static String privateAndStaticInterfaceMethods() {
        return join(new UsesPrivate().greet(), WithPrivate.util());
    }

    interface Template {
        String name();
        default String describe() { return "<" + name() + ">"; }
    }

    public static String defaultCallsAbstract() {
        Template t = () -> "lambda";
        Template anon = new Template() {
            public String name() { return "anon"; }
        };
        return join(t.describe(), anon.describe());
    }

    public static String objectMethodsThroughInterface() {
        Named n = new SuperCall();
        Named same = n;
        return join(n.equals(same), n.equals(new SuperCall()), n.toString() != null, n.hashCode() == same.hashCode());
    }

    static final class Box implements Supplier<String>, Comparable<Box> {
        final int value;
        Box(int value) { this.value = value; }
        public String get() { return "box" + value; }
        public int compareTo(Box other) { return Integer.compare(value, other.value); }
    }

    @SuppressWarnings({"rawtypes", "unchecked"})
    public static String bridgeMethods() {
        Supplier<?> s = new Box(3);
        Comparable raw = new Box(1);
        int cmp = raw.compareTo(new Box(2));
        String castFailure;
        try {
            raw.compareTo("not a box");
            castFailure = "none";
        } catch (ClassCastException e) {
            castFailure = "CCE";
        }
        return join(s.get(), cmp, castFailure);
    }

    static class Animal {
        Animal self() { return this; }
        String kind() { return "animal"; }
    }
    static class Dog extends Animal {
        @Override Dog self() { return this; }
        @Override String kind() { return "dog"; }
    }

    public static String covariantReturn() {
        Animal a = new Dog();
        return join(a.self().kind(), a.self().getClass().getSimpleName(), new Dog().self().kind());
    }

    static class GA { String m() { return "GA"; } }
    static class GB extends GA {}
    static class GC extends GB { String m() { return "GC>" + super.m(); } }

    public static String superSkipsIntermediateWithoutOverride() {
        return new GC().m();
    }

    static class FieldParent { String f = "parent"; static String s() { return "ps"; } }
    static class FieldChild extends FieldParent { String f = "child"; static String s() { return "cs"; } }

    public static String fieldAndStaticHiding() {
        FieldChild c = new FieldChild();
        FieldParent p = c;
        return join(c.f, p.f, ((FieldParent) c).f, FieldParent.s(), FieldChild.s());
    }

    static class PrivA {
        private String p() { return "A"; }
        String call() { return p(); }
    }
    static class PrivB extends PrivA {
        @SuppressWarnings("unused")
        private String p() { return "B"; }
    }

    public static String privateMethodsAreNotOverridden() {
        return new PrivB().call();
    }

    public static String lambdasAndDefaultComposition() {
        Function<Integer, Integer> inc = x -> x + 1;
        Function<Integer, Integer> twice = x -> x * 2;
        IntBinaryOperator max = Math::max;
        Supplier<List<String>> factory = ArrayList::new;
        List<String> list = factory.get();
        list.add("z");
        list.add("a");
        list.sort(Comparator.naturalOrder());
        Function<String, Integer> length = String::length;
        return join(inc.andThen(twice).apply(3), inc.compose(twice).apply(3), Function.<Integer>identity().apply(9),
            max.applyAsInt(-1, -5), list, length.apply("four"));
    }

    public static String capturingLambda() {
        int base = Fmt.v(10);
        String suffix = Fmt.v("!");
        Function<Integer, String> f = x -> (base + x) + suffix;
        Runnable[] holder = new Runnable[1];
        StringBuilder log = new StringBuilder();
        holder[0] = () -> log.append("ran");
        holder[0].run();
        return join(f.apply(5), log);
    }

    public static String comparatorDefaults() {
        List<String> words = new ArrayList<>(List.of("bb", "a", "ccc", "dd"));
        words.sort(Comparator.comparing(String::length).reversed().thenComparing(Comparator.naturalOrder()));
        return words.toString();
    }

    interface Counter {
        int next();
        static Counter from(int start) {
            int[] state = {start};
            return () -> state[0]++;
        }
    }

    public static String statefulLambda() {
        Counter c = Counter.from(5);
        c.next();
        c.next();
        return Integer.toString(c.next());
    }

    public static String invokeInterfaceOnNull() {
        Named n = (Named) o(null);
        return n.m();
    }

    static class Overloads {
        static String f(Object o) { return "Object"; }
        static String f(String s) { return "String"; }
        static String f(Integer i) { return "Integer"; }
        static String f(long l) { return "long"; }
        static String f(int... xs) { return "varargs" + xs.length; }
    }

    public static String overloadResolutionIsStatic() {
        Object s = "x";
        short sh = 1;
        return join(Overloads.f(s), Overloads.f("x"), Overloads.f(1), Overloads.f(sh), Overloads.f(Integer.valueOf(1)),
            Overloads.f(), Overloads.f(1, 2));
    }
}
