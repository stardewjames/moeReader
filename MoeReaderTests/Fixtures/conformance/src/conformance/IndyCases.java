package conformance;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.function.Function;
import java.util.function.IntUnaryOperator;
import java.util.function.Supplier;

import static conformance.Fmt.join;
import static conformance.Fmt.name;

/**
 * invoke-custom, const-method-handle and const-method-type, driven through the
 * generated {@code IndyGen} class.
 */
public final class IndyCases {
    private IndyCases() {}

    public static String userBootstrapConstantCallSite() {
        return join(IndyGen.twice(21), IndyGen.twice(-4));
    }

    public static String callSiteLinksOncePerSite() {
        int before = Bootstraps.links;
        String first = IndyGen.counted();
        String again = IndyGen.counted();
        String third = IndyGen.counted();
        String other = IndyGen.countedOther();
        return join(first, again, third, other, Bootstraps.links - before, first == again);
    }

    public static String lambdaMetafactoryPrimitiveSam() {
        IntUnaryOperator adder = IndyGen.adder(4);
        IntUnaryOperator another = IndyGen.adder(-1);
        return join(adder.applyAsInt(3), another.applyAsInt(3), adder.andThen(x -> x * 2).applyAsInt(1));
    }

    @SuppressWarnings("unchecked")
    public static String lambdaMetafactoryInstantiatedType() {
        Function<Object, Object> length = (Function<Object, Object>) IndyGen.lengthFunction("pre");
        Object result = length.apply("fix");
        String failure;
        try {
            length.apply(Integer.valueOf(1));
            failure = "none";
        } catch (ClassCastException e) {
            failure = name(e);
        }
        return join(result, result.getClass().getSimpleName(), failure);
    }

    @SuppressWarnings("unchecked")
    public static String lambdaMetafactoryCapturedLong() {
        Supplier<String> supplier = (Supplier<String>) IndyGen.supplier("v", -1L << 33);
        return join(supplier.get(), supplier.get().length());
    }

    public static String stringConcatFactoryRecipe() {
        return IndyGen.concat("s", 5, -9L, 'c', true, null, 1.5);
    }

    public static String stringConcatFactoryRecipeAgain() {
        return IndyGen.concat("", Integer.MIN_VALUE, Long.MAX_VALUE, '\u00e9', false, "obj", -0.0);
    }

    public static String everyStaticArgumentKind() {
        return IndyGen.described();
    }

    public static String bootstrapFailure() {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < 2; i++) {
            try {
                out.append(IndyGen.broken());
            } catch (BootstrapMethodError e) {
                out.append(name(e));
                // JVMS 5.4.3 only requires the same error class on later
                // attempts; HotSpot rethrows it without the original cause.
                if (i == 0) out.append('/').append(name(e.getCause()));
                out.append(';');
            }
        }
        return out.toString();
    }

    public static String bootstrapFailureEscapes() {
        return IndyGen.broken();
    }

    public static String constMethodHandleStatic() throws Throwable {
        MethodHandle h = IndyGen.handleStatic();
        int r = (int) h.invokeExact(21);
        return join(r, h.type(), IndyGen.handleStatic().type().equals(h.type()));
    }

    public static String constMethodHandleVirtualAndInterface() throws Throwable {
        MethodHandle virtual = IndyGen.handleVirtual();
        MethodHandle iface = IndyGen.handleInterface();
        int a = (int) virtual.invokeExact("four");
        int b = (int) iface.invokeExact((CharSequence) new StringBuilder("xyz"));
        return join(a, b, virtual.type(), iface.type());
    }

    public static String constMethodHandleConstructor() throws Throwable {
        MethodHandle ctor = IndyGen.handleConstructor();
        StringBuilder sb = (StringBuilder) ctor.invokeExact("made");
        return join(sb.append('!'), ctor.type());
    }

    public static String constMethodHandleStaticGetter() throws Throwable {
        MethodHandle getter = IndyGen.handleStaticGetter();
        int links = (int) getter.invokeExact();
        return join(links == Bootstraps.links, getter.type());
    }

    public static String constMethodType() {
        MethodType t = IndyGen.typeConstant();
        MethodType v = IndyGen.voidTypeConstant();
        return join(t, t.toMethodDescriptorString(), v, t.equals(MethodType.methodType(long[].class, int.class, String.class)),
            t.parameterType(1) == String.class);
    }
}
