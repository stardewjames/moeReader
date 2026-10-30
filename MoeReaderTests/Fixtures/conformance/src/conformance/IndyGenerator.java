package conformance;

import java.lang.constant.ClassDesc;
import java.lang.constant.ConstantDesc;
import java.lang.constant.ConstantDescs;
import java.lang.constant.DirectMethodHandleDesc;
import java.lang.constant.DynamicCallSiteDesc;
import java.lang.constant.MethodHandleDesc;
import java.lang.constant.MethodTypeDesc;
import java.lang.reflect.AccessFlag;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.function.Consumer;

import jdk.internal.classfile.Classfile;
import jdk.internal.classfile.CodeBuilder;

/**
 * Writes {@code conformance/IndyGen.class}: invokedynamic sites with user
 * bootstrap methods plus ldc MethodHandle / ldc MethodType, none of which
 * javac can emit from source. JVM-only build tool (needs
 * {@code --add-exports java.base/jdk.internal.classfile=ALL-UNNAMED}); it is
 * not part of the dex.
 *
 * Usage: {@code java conformance.IndyGenerator <classes-dir>}
 */
public final class IndyGenerator {
    private IndyGenerator() {}

    private static final int CLASS_VERSION = 61; // Java 17

    private static final ClassDesc SELF = ClassDesc.of("conformance.IndyGen");
    private static final ClassDesc BOOTSTRAPS = ClassDesc.of("conformance.Bootstraps");
    private static final ClassDesc CD_CALL_SITE = ClassDesc.of("java.lang.invoke.CallSite");
    private static final ClassDesc CD_LOOKUP = ClassDesc.of("java.lang.invoke.MethodHandles$Lookup");
    private static final ClassDesc CD_INT_UNARY = ClassDesc.of("java.util.function.IntUnaryOperator");
    private static final ClassDesc CD_FUNCTION = ClassDesc.of("java.util.function.Function");
    private static final ClassDesc CD_SUPPLIER = ClassDesc.of("java.util.function.Supplier");
    private static final ClassDesc CD_STRING_BUILDER = ClassDesc.of("java.lang.StringBuilder");
    private static final ClassDesc CD_CHAR_SEQUENCE = ClassDesc.of("java.lang.CharSequence");
    private static final ClassDesc CD = ConstantDescs.CD_String;

    private static DirectMethodHandleDesc bootstrap(String name, ClassDesc... extra) {
        ClassDesc[] parameters = new ClassDesc[3 + extra.length];
        parameters[0] = CD_LOOKUP;
        parameters[1] = ConstantDescs.CD_String;
        parameters[2] = ConstantDescs.CD_MethodType;
        System.arraycopy(extra, 0, parameters, 3, extra.length);
        return MethodHandleDesc.ofMethod(DirectMethodHandleDesc.Kind.STATIC, BOOTSTRAPS, name,
            MethodTypeDesc.of(CD_CALL_SITE, parameters));
    }

    private static DynamicCallSiteDesc site(DirectMethodHandleDesc bootstrap, String name, MethodTypeDesc type,
        ConstantDesc... arguments) {
        return DynamicCallSiteDesc.of(bootstrap, name, type, arguments);
    }

    public static void main(String[] args) throws Exception {
        Path out = Path.of(args[0]).resolve("conformance").resolve("IndyGen.class");
        Files.createDirectories(out.getParent());

        MethodTypeDesc intToInt = MethodTypeDesc.of(ConstantDescs.CD_int, ConstantDescs.CD_int);
        MethodTypeDesc toString = MethodTypeDesc.of(CD);
        DirectMethodHandleDesc twice = MethodHandleDesc.ofMethod(DirectMethodHandleDesc.Kind.STATIC, BOOTSTRAPS, "twice", intToInt);
        DirectMethodHandleDesc lambdaBootstrap = bootstrap("lambda", ConstantDescs.CD_MethodType, ConstantDescs.CD_MethodHandle,
            ConstantDescs.CD_MethodType);

        MethodTypeDesc addBody = MethodTypeDesc.of(ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_int);
        MethodTypeDesc lengthBody = MethodTypeDesc.of(ConstantDescs.CD_Integer, CD, CD);
        MethodTypeDesc supplyBody = MethodTypeDesc.of(CD, CD, ConstantDescs.CD_long);
        MethodTypeDesc concatType = MethodTypeDesc.of(CD, CD, ConstantDescs.CD_int, ConstantDescs.CD_long, ConstantDescs.CD_char,
            ConstantDescs.CD_boolean, ConstantDescs.CD_Object, ConstantDescs.CD_double);

        int publicStatic = Classfile.ACC_PUBLIC | Classfile.ACC_STATIC;
        int privateStatic = Classfile.ACC_PRIVATE | Classfile.ACC_STATIC;

        byte[] bytes = Classfile.build(SELF, classBuilder -> {
            classBuilder.withVersion(CLASS_VERSION, 0);
            classBuilder.withFlags(AccessFlag.PUBLIC, AccessFlag.FINAL, AccessFlag.SUPER);
            classBuilder.withSuperclass(ConstantDescs.CD_Object);

            // indy -> user bootstrap -> ConstantCallSite(findStatic)
            method(classBuilder, "twice", intToInt, publicStatic, code -> code
                .iload(0)
                .invokedynamic(site(bootstrap("linkStatic"), "twice", intToInt))
                .ireturn());

            // Each site links once, however often it runs; two sites link twice.
            method(classBuilder, "counted", toString, publicStatic, code -> code
                .invokedynamic(site(bootstrap("linkCounting"), "first", toString))
                .areturn());
            method(classBuilder, "countedOther", toString, publicStatic, code -> code
                .invokedynamic(site(bootstrap("linkCounting"), "second", toString))
                .areturn());

            // User bootstrap delegating to LambdaMetafactory.metafactory: a
            // primitive SAM with a captured int ...
            method(classBuilder, "adder", MethodTypeDesc.of(CD_INT_UNARY, ConstantDescs.CD_int), publicStatic, code -> code
                .iload(0)
                .invokedynamic(site(lambdaBootstrap, "applyAsInt", MethodTypeDesc.of(CD_INT_UNARY, ConstantDescs.CD_int),
                    intToInt,
                    MethodHandleDesc.ofMethod(DirectMethodHandleDesc.Kind.STATIC, SELF, "lambdaAdd", addBody),
                    intToInt))
                .areturn());
            method(classBuilder, "lambdaAdd", addBody, privateStatic, code -> code
                .iload(0).bipush(10).imul().iload(1).iadd().ireturn());

            // ... an erased generic SAM with a narrower instantiated type ...
            MethodTypeDesc erased = MethodTypeDesc.of(ConstantDescs.CD_Object, ConstantDescs.CD_Object);
            method(classBuilder, "lengthFunction", MethodTypeDesc.of(CD_FUNCTION, CD), publicStatic, code -> code
                .aload(0)
                .invokedynamic(site(lambdaBootstrap, "apply", MethodTypeDesc.of(CD_FUNCTION, CD), erased,
                    MethodHandleDesc.ofMethod(DirectMethodHandleDesc.Kind.STATIC, SELF, "lambdaLength", lengthBody),
                    MethodTypeDesc.of(ConstantDescs.CD_Integer, CD)))
                .areturn());
            method(classBuilder, "lambdaLength", lengthBody, privateStatic, code -> code
                .aload(0).aload(1)
                .invokevirtual(CD, "concat", MethodTypeDesc.of(CD, CD))
                .invokevirtual(CD, "length", MethodTypeDesc.of(ConstantDescs.CD_int))
                .invokestatic(ConstantDescs.CD_Integer, "valueOf", MethodTypeDesc.of(ConstantDescs.CD_Integer, ConstantDescs.CD_int))
                .areturn());

            // ... and a captured wide (long) value.
            MethodTypeDesc supplierFactory = MethodTypeDesc.of(CD_SUPPLIER, CD, ConstantDescs.CD_long);
            method(classBuilder, "supplier", supplierFactory, publicStatic, code -> code
                .aload(0).lload(1)
                .invokedynamic(site(lambdaBootstrap, "get", supplierFactory, MethodTypeDesc.of(ConstantDescs.CD_Object),
                    MethodHandleDesc.ofMethod(DirectMethodHandleDesc.Kind.STATIC, SELF, "lambdaSupply", supplyBody),
                    MethodTypeDesc.of(CD)))
                .areturn());
            method(classBuilder, "lambdaSupply", supplyBody, privateStatic, code -> code
                .aload(0).lload(1)
                .invokestatic(CD, "valueOf", MethodTypeDesc.of(CD, ConstantDescs.CD_long))
                .invokevirtual(CD, "concat", MethodTypeDesc.of(CD, CD))
                .areturn());

            // User bootstrap delegating to StringConcatFactory with a recipe
            // that mixes argument (\1) and constant (\2) tags.
            method(classBuilder, "concat", concatType, publicStatic, code -> code
                .aload(0).iload(1).lload(2).iload(4).iload(5).aload(6).dload(7)
                .invokedynamic(site(bootstrap("concat", CD, CD), "concat", concatType,
                    "<\u0001|\u0002|\u0001/\u0001/\u0001/\u0001/\u0001/\u0001>", "K\u00e9"))
                .areturn());

            // One static bootstrap argument of every loadable constant kind.
            method(classBuilder, "described", toString, publicStatic, code -> code
                .invokedynamic(site(bootstrap("describe", ConstantDescs.CD_int, ConstantDescs.CD_long, ConstantDescs.CD_float,
                        ConstantDescs.CD_double, CD, ConstantDescs.CD_Class, ConstantDescs.CD_MethodType, ConstantDescs.CD_MethodHandle),
                    "describe", toString,
                    -7, -1L << 40, -0.5f, 1e-300, "str\u00e9", CD.arrayType(),
                    MethodTypeDesc.of(ConstantDescs.CD_Object, ConstantDescs.CD_int, ConstantDescs.CD_long.arrayType()),
                    twice))
                .areturn());

            // Bootstrap that throws.
            method(classBuilder, "broken", toString, publicStatic, code -> code
                .invokedynamic(site(bootstrap("broken"), "broken", toString))
                .areturn());

            // ldc MethodHandle (d8: const-method-handle) of several kinds.
            ClassDesc handle = ConstantDescs.CD_MethodHandle;
            method(classBuilder, "handleStatic", MethodTypeDesc.of(handle), publicStatic, code -> code
                .constantInstruction(twice).areturn());
            method(classBuilder, "handleVirtual", MethodTypeDesc.of(handle), publicStatic, code -> code
                .constantInstruction(MethodHandleDesc.ofMethod(DirectMethodHandleDesc.Kind.VIRTUAL, CD, "length",
                    MethodTypeDesc.of(ConstantDescs.CD_int)))
                .areturn());
            method(classBuilder, "handleInterface", MethodTypeDesc.of(handle), publicStatic, code -> code
                .constantInstruction(MethodHandleDesc.ofMethod(DirectMethodHandleDesc.Kind.INTERFACE_VIRTUAL, CD_CHAR_SEQUENCE,
                    "length", MethodTypeDesc.of(ConstantDescs.CD_int)))
                .areturn());
            method(classBuilder, "handleConstructor", MethodTypeDesc.of(handle), publicStatic, code -> code
                .constantInstruction(MethodHandleDesc.ofConstructor(CD_STRING_BUILDER, CD))
                .areturn());
            method(classBuilder, "handleStaticGetter", MethodTypeDesc.of(handle), publicStatic, code -> code
                .constantInstruction(MethodHandleDesc.ofField(DirectMethodHandleDesc.Kind.STATIC_GETTER, BOOTSTRAPS, "links",
                    ConstantDescs.CD_int))
                .areturn());

            // ldc MethodType (d8: const-method-type).
            ClassDesc type = ConstantDescs.CD_MethodType;
            method(classBuilder, "typeConstant", MethodTypeDesc.of(type), publicStatic, code -> code
                .constantInstruction(MethodTypeDesc.of(ConstantDescs.CD_long.arrayType(), ConstantDescs.CD_int, CD))
                .areturn());
            method(classBuilder, "voidTypeConstant", MethodTypeDesc.of(type), publicStatic, code -> code
                .constantInstruction(MethodTypeDesc.of(ConstantDescs.CD_void))
                .areturn());
        });
        Files.write(out, bytes);
    }

    private static void method(jdk.internal.classfile.ClassBuilder classBuilder, String name, MethodTypeDesc type, int flags,
        Consumer<CodeBuilder> body) {
        classBuilder.withMethodBody(name, type, flags, body::accept);
    }
}
