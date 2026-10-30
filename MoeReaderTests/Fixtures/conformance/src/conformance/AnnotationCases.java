package conformance;

import java.lang.annotation.Annotation;
import java.lang.annotation.ElementType;
import java.lang.annotation.Inherited;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Arrays;

import static conformance.Fmt.d;
import static conformance.Fmt.f;
import static conformance.Fmt.join;

public final class AnnotationCases {
    private AnnotationCases() {}

    public enum Level { LOW, MEDIUM, HIGH }

    @Retention(RetentionPolicy.RUNTIME)
    public @interface Tag {
        String value();
    }

    @Retention(RetentionPolicy.RUNTIME)
    public @interface Info {
        int num() default 7;
        String name() default "dflt";
        Level level() default Level.LOW;
        Class<?> type() default Object.class;
        int[] nums() default {1, 2};
        Tag tag() default @Tag("t0");
        Tag[] tags() default {};
        long big() default -5L;
        float f() default 1.5f;
        double d() default -2.25;
        char c() default 'q';
        byte b() default -1;
        short s() default -2;
        boolean flag() default true;
        String[] strs() default {"x"};
        Level[] levels() default {Level.HIGH, Level.LOW};
        Class<?>[] types() default {int.class, void.class};
    }

    @Retention(RetentionPolicy.RUNTIME)
    @Target(ElementType.PARAMETER)
    public @interface Param {
        String value();
    }

    @Retention(RetentionPolicy.CLASS)
    public @interface Invisible {}

    @Retention(RetentionPolicy.RUNTIME)
    @Inherited
    public @interface Inheritable {
        String value();
    }

    @Retention(RetentionPolicy.RUNTIME)
    public @interface NotInherited {}

    @Info(num = 42, name = "cls", level = Level.HIGH, type = String[].class, nums = {-1, 3}, tag = @Tag("nested"),
        tags = {@Tag("a"), @Tag("b")}, big = Long.MIN_VALUE, f = -0.0f, d = 1e300, c = '\u00e9', b = -128, s = Short.MIN_VALUE,
        flag = false, strs = {}, levels = {}, types = {long[].class, Target.class})
    @Inheritable("base")
    @NotInherited
    @Invisible
    public static class Annotated {
        @Info(name = "fld")
        public int field;

        @Info
        public static String plain;

        @Info(num = -3)
        public Annotated() {}

        @Info(num = -3, tag = @Tag("onMethod"))
        @Deprecated
        public static String method(@Param("p0") int a, @Tag("p1") @Param("p1b") String b, long c) {
            return "m";
        }
    }

    public static class Derived extends Annotated {}

    private static Info classInfo() {
        return Annotated.class.getAnnotation(Info.class);
    }

    public static String classScalarElements() {
        Info info = classInfo();
        return join(info.num(), info.name(), info.level(), info.level().ordinal(), info.type().getName(), info.big(),
            f(info.f()), d(info.d()), (int) info.c(), info.b(), info.s(), info.flag());
    }

    public static String classArrayElements() {
        Info info = classInfo();
        StringBuilder tags = new StringBuilder();
        for (Tag t : info.tags()) tags.append(t.value());
        StringBuilder types = new StringBuilder();
        for (Class<?> c : info.types()) types.append(c.getName()).append(' ');
        return join(Arrays.toString(info.nums()), tags, info.strs().length, info.levels().length, types.toString().trim(),
            info.tags().getClass().getSimpleName(), info.nums().getClass().getName());
    }

    public static String nestedAnnotationElement() {
        Tag nested = classInfo().tag();
        return join(nested.value(), nested.annotationType().getSimpleName(), nested instanceof Annotation, nested instanceof Tag);
    }

    public static String defaultsOnField() throws Exception {
        Info info = Annotated.class.getField("field").getAnnotation(Info.class);
        StringBuilder levels = new StringBuilder();
        for (Level l : info.levels()) levels.append(l.name()).append(' ');
        StringBuilder types = new StringBuilder();
        for (Class<?> c : info.types()) types.append(c.getName()).append(' ');
        return join(info.name(), info.num(), info.level(), info.type().getSimpleName(), Arrays.toString(info.nums()),
            info.tag().value(), info.tags().length, info.big(), f(info.f()), d(info.d()), info.c(), info.b(), info.s(),
            info.flag(), Arrays.toString(info.strs()), levels.toString().trim(), types.toString().trim());
    }

    public static String allDefaultsEqual() throws Exception {
        Info onStatic = Annotated.class.getField("plain").getAnnotation(Info.class);
        Info onField = Annotated.class.getField("field").getAnnotation(Info.class);
        Info onCtor = Annotated.class.getConstructor().getAnnotation(Info.class);
        return join(onStatic.name(), onStatic.equals(onField), onStatic.equals(onStatic), onCtor.num(), onCtor.equals(onStatic),
            onStatic.hashCode() == Annotated.class.getField("plain").getAnnotation(Info.class).hashCode());
    }

    public static String methodAnnotations() throws Exception {
        Method m = Annotated.class.getMethod("method", int.class, String.class, long.class);
        Info info = m.getAnnotation(Info.class);
        return join(info.num(), info.tag().value(), info.name(), m.isAnnotationPresent(Deprecated.class),
            m.getAnnotation(Tag.class), m.getDeclaredAnnotations().length);
    }

    public static String parameterAnnotations() throws Exception {
        Method m = Annotated.class.getMethod("method", int.class, String.class, long.class);
        Annotation[][] all = m.getParameterAnnotations();
        StringBuilder out = new StringBuilder();
        out.append(all.length).append(':');
        for (Annotation[] perParameter : all) {
            out.append('[');
            // AnnotatedElement does not specify annotation iteration order.
            String[] labels = new String[perParameter.length];
            for (int i = 0; i < perParameter.length; i++) {
                Annotation a = perParameter[i];
                if (a instanceof Param) labels[i] = "Param=" + ((Param) a).value();
                else if (a instanceof Tag) labels[i] = "Tag=" + ((Tag) a).value();
                else labels[i] = a.annotationType().getName();
            }
            Arrays.sort(labels);
            for (String label : labels) out.append(label).append(' ');
            out.append(']');
        }
        return out.toString();
    }

    public static String visibility() {
        return join(Annotated.class.isAnnotationPresent(Info.class), Annotated.class.getAnnotation(Invisible.class),
            Annotated.class.isAnnotationPresent(NotInherited.class), Annotated.class.getAnnotations().length,
            Annotated.class.getDeclaredAnnotations().length);
    }

    public static String inheritance() {
        Inheritable inherited = Derived.class.getAnnotation(Inheritable.class);
        return join(inherited == null ? null : inherited.value(), Derived.class.getAnnotation(NotInherited.class),
            Derived.class.getAnnotation(Info.class), Derived.class.getDeclaredAnnotations().length,
            Derived.class.getAnnotations().length, Derived.class.isAnnotationPresent(Inheritable.class));
    }

    public static String annotationTypeShape() throws Exception {
        Method value = Tag.class.getMethod("value");
        Method num = Info.class.getMethod("num");
        Retention retention = Info.class.getAnnotation(Retention.class);
        Target target = Param.class.getAnnotation(Target.class);
        return join(Tag.class.isAnnotation(), Tag.class.isInterface(), Annotation.class.isAssignableFrom(Tag.class),
            value.getDefaultValue(), num.getDefaultValue(), retention.value(), target.value()[0],
            Info.class.getMethod("levels").getDefaultValue().getClass().getSimpleName());
    }

    public static String arrayElementsAreCopies() {
        Info info = classInfo();
        int[] first = info.nums();
        first[0] = 99;
        return join(info.nums()[0], first != info.nums());
    }

    public static String annotationEquality() {
        Tag a = classInfo().tag();
        Tag b = classInfo().tag();
        Tag other = classInfo().tags()[0];
        return join(a.equals(b), a.equals(other), a.hashCode() == b.hashCode(), a.annotationType() == Tag.class);
    }

    public static String fieldAndConstructorLookups() throws Exception {
        Field field = Annotated.class.getField("field");
        Constructor<Annotated> ctor = Annotated.class.getConstructor();
        return join(field.getAnnotations().length, ctor.getAnnotation(Info.class).num(),
            ctor.getParameterAnnotations().length, field.isAnnotationPresent(Tag.class));
    }
}
