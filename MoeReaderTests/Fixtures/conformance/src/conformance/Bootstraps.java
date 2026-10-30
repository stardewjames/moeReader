package conformance;

import java.lang.invoke.CallSite;
import java.lang.invoke.ConstantCallSite;
import java.lang.invoke.LambdaConversionException;
import java.lang.invoke.LambdaMetafactory;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.invoke.StringConcatException;
import java.lang.invoke.StringConcatFactory;

/**
 * User bootstrap methods for the invokedynamic sites in the generated
 * {@code conformance.IndyGen} class (see IndyGenerator). d8 keeps every one of
 * those sites as invoke-custom because none of them names LambdaMetafactory or
 * StringConcatFactory directly.
 */
public final class Bootstraps {
    private Bootstraps() {}

    /** Number of times {@link #linkCounting} ran. */
    public static int links;

    public static int twice(int x) {
        return x * 2;
    }

    public static CallSite linkStatic(MethodHandles.Lookup lookup, String name, MethodType type)
        throws ReflectiveOperationException {
        return new ConstantCallSite(lookup.findStatic(Bootstraps.class, name, type));
    }

    public static CallSite linkCounting(MethodHandles.Lookup lookup, String name, MethodType type) {
        links++;
        return new ConstantCallSite(MethodHandles.constant(String.class, name + ":" + links).asType(type));
    }

    /** Runs the platform lambda metafactory from inside a user bootstrap. */
    public static CallSite lambda(MethodHandles.Lookup lookup, String name, MethodType type, MethodType samType,
        MethodHandle implementation, MethodType instantiatedType) throws LambdaConversionException {
        return LambdaMetafactory.metafactory(lookup, name, type, samType, implementation, instantiatedType);
    }

    /** Runs the platform string concatenation factory from inside a user bootstrap. */
    public static CallSite concat(MethodHandles.Lookup lookup, String name, MethodType type, String recipe, String constant)
        throws StringConcatException {
        return StringConcatFactory.makeConcatWithConstants(lookup, name, type, recipe, constant);
    }

    /** Receives one static argument of every loadable kind and reports them. */
    public static CallSite describe(MethodHandles.Lookup lookup, String name, MethodType type, int i, long l, float f,
        double d, String s, Class<?> c, MethodType mt, MethodHandle mh) throws Throwable {
        StringBuilder text = new StringBuilder();
        text.append(name).append('|').append(i).append('|').append(l).append('|').append(Fmt.f(f)).append('|')
            .append(Fmt.d(d)).append('|').append(s).append('|').append(c.getName()).append('|').append(mt).append('|')
            .append(mh.type()).append('|').append(mh.invokeWithArguments(21)).append('|')
            .append(lookup.lookupClass().getSimpleName()).append('|').append(type);
        return new ConstantCallSite(MethodHandles.constant(String.class, text.toString()));
    }

    public static CallSite broken(MethodHandles.Lookup lookup, String name, MethodType type) {
        throw new IllegalStateException("bootstrap failure");
    }
}
