package conformance;

import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/**
 * Produces conformance.expected on the JVM (the reference implementation).
 * Not part of the dex. For each topic class, in the order below, every
 * {@code public static String name()} method runs in name order and prints
 * {@code Topic.name=<result>}; a thrown exception prints {@code !SimpleName}.
 * Characters outside printable ASCII, and the backslash, are written as
 * {@code \\uXXXX} (lowercase hex). The XCTest mirrors this exactly.
 */
public final class Runner {
    private Runner() {}

    static final String[] TOPICS = {
        "IntArithCases",
        "FloatCases",
        "NarrowingCases",
        "ArrayCases",
        "StringCases",
        "SwitchCases",
        "ExceptionCases",
        "ClassInitCases",
        "StaticValueCases",
        "InterfaceCases",
        "CastCases",
        "ReflectionCases",
        "AnnotationCases",
        "MethodHandleCases",
        "IndyCases",
    };

    public static void main(String[] args) throws Exception {
        try (Writer out = new OutputStreamWriter(new FileOutputStream(args[0]), StandardCharsets.US_ASCII)) {
            for (String topic : TOPICS) {
                Class<?> cls = Class.forName("conformance." + topic);
                List<Method> cases = new ArrayList<>();
                for (Method m : cls.getDeclaredMethods()) {
                    int mods = m.getModifiers();
                    if (Modifier.isPublic(mods) && Modifier.isStatic(mods) && m.getParameterCount() == 0
                        && m.getReturnType() == String.class && !m.isSynthetic()) {
                        cases.add(m);
                    }
                }
                cases.sort(Comparator.comparing(Method::getName));
                for (Method m : cases) {
                    out.write(topic + "." + m.getName() + "=" + escape(run(m)) + "\n");
                }
            }
        }
    }

    private static String run(Method m) {
        try {
            return String.valueOf(m.invoke(null));
        } catch (InvocationTargetException e) {
            return "!" + e.getCause().getClass().getSimpleName();
        } catch (Throwable t) {
            return "!" + t.getClass().getSimpleName();
        }
    }

    static String escape(String s) {
        StringBuilder b = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < 0x20 || c > 0x7e || c == '\\') {
                String hex = Integer.toHexString(c);
                b.append("\\u");
                for (int pad = hex.length(); pad < 4; pad++) b.append('0');
                b.append(hex);
            } else {
                b.append(c);
            }
        }
        return b.toString();
    }
}
