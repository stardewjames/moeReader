package conformance;

import java.io.Serializable;
import java.util.ArrayList;
import java.util.List;
import java.util.RandomAccess;

import static conformance.Fmt.join;
import static conformance.Fmt.o;

public final class CastCases {
    private CastCases() {}

    interface Shape {}
    interface Round extends Shape {}
    static class Circle implements Round {}
    static class Square implements Shape {}
    static final class Unit extends Circle {}

    public static String instanceOfHierarchy() {
        Object circle = new Circle();
        Object unit = new Unit();
        Object square = new Square();
        return join(circle instanceof Shape, circle instanceof Round, square instanceof Round, unit instanceof Circle,
            unit instanceof Shape, circle instanceof Unit, square instanceof Object);
    }

    public static String instanceOfNull() {
        Object nothing = o(null);
        return join(nothing instanceof Object, nothing instanceof String, nothing instanceof int[]);
    }

    public static String checkcastNullSucceeds() {
        Object nothing = o(null);
        String s = (String) nothing;
        int[] a = (int[]) nothing;
        Runnable r = (Runnable) nothing;
        return join(s, a == null, r == null);
    }

    public static String classCastCaught() {
        StringBuilder out = new StringBuilder();
        Object boxed = o(Integer.valueOf(1));
        try {
            String s = (String) boxed;
            out.append(s);
        } catch (ClassCastException e) {
            out.append("CCE1;");
        }
        try {
            Long l = (Long) boxed;
            out.append(l);
        } catch (ClassCastException e) {
            out.append("CCE2;");
        }
        try {
            Shape shape = (Shape) o(new Object());
            out.append(shape != null);
        } catch (ClassCastException e) {
            out.append("CCE3;");
        }
        try {
            Unit unit = (Unit) o(new Circle());
            out.append(unit != null);
        } catch (ClassCastException e) {
            out.append("CCE4;");
        }
        Number n = (Number) boxed;
        Comparable<?> c = (Comparable<?>) boxed;
        out.append(n.intValue()).append(c != null);
        return out.toString();
    }

    public static String classCastEscapes() {
        Object boxed = o("text");
        return Integer.toString((Integer) boxed);
    }

    public static String classObjectChecks() {
        StringBuilder out = new StringBuilder();
        out.append(Number.class.isInstance(1)).append(',').append(String.class.isInstance(null)).append(',')
            .append(Shape.class.isAssignableFrom(Unit.class)).append(',').append(Unit.class.isAssignableFrom(Circle.class)).append(',')
            .append(int.class.isAssignableFrom(int.class)).append(',').append(Object.class.isAssignableFrom(int.class)).append(',')
            .append(long.class.isAssignableFrom(int.class)).append(',').append(Object[].class.isAssignableFrom(String[][].class))
            .append(',').append(Serializable.class.isAssignableFrom(int[].class)).append(',')
            .append(Number.class.cast(3.5).getClass().getSimpleName()).append(',');
        try {
            String.class.cast(1);
        } catch (ClassCastException e) {
            out.append("CCE");
        }
        out.append(',').append(String.class.cast(null));
        return out.toString();
    }

    @SuppressWarnings({"rawtypes", "unchecked"})
    public static String heapPollution() {
        List raw = new ArrayList();
        raw.add(1);
        List<String> strings = raw;
        Object fine = strings.get(0);
        try {
            String s = strings.get(0);
            return "none" + s;
        } catch (ClassCastException e) {
            return join("CCE", fine);
        }
    }

    public static String boxingCasts() {
        Object o = 1;
        Object c = 'c';
        Object d = 1.0;
        return join(o instanceof Integer, o instanceof Number, c instanceof Character, d instanceof Double,
            ((Number) d).intValue(), (int) (Integer) o, (char) (Character) c);
    }

    public static String unboxNull() {
        Integer boxed = (Integer) o(null);
        int value = boxed;
        return Integer.toString(value);
    }

    public static String patternInstanceOf() {
        StringBuilder out = new StringBuilder();
        for (Object x : new Object[] {"str", 42, 2.5, null, new int[] {7}}) {
            if (x instanceof String s && !s.isEmpty()) out.append("S:").append(s.length());
            else if (x instanceof Integer i) out.append("I:").append(i + 1);
            else if (x instanceof int[] a) out.append("A:").append(a[0]);
            else out.append("?");
            out.append(';');
        }
        return out.toString();
    }

    public static String interfaceCastsOnLibraryTypes() {
        Object list = new ArrayList<String>();
        Object text = new StringBuilder("x");
        return join(list instanceof RandomAccess, list instanceof Cloneable, list instanceof Iterable, text instanceof CharSequence,
            text instanceof Appendable, (CharSequence) text);
    }

    public static String castToArrayOfInterface() {
        Object strings = new String[] {"a"};
        CharSequence[] seq = (CharSequence[]) strings;
        Object[] objects = (Object[]) strings;
        Comparable<?>[] cmp = (Comparable<?>[]) strings;
        try {
            Runnable[] r = (Runnable[]) strings;
            return "none" + r.length;
        } catch (ClassCastException e) {
            return join(seq.length, objects.length, cmp.length, "CCE");
        }
    }

    public static String primitiveCastsInExpressions() {
        Object o = o((short) -3);
        long widened = (Short) o;
        double asDouble = (Short) o;
        return join(widened, Fmt.d(asDouble), (byte) (short) (Short) o);
    }
}
