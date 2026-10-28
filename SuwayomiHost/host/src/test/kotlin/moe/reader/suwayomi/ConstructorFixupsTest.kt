package moe.reader.suwayomi

import com.googlecode.dex2jar.ir.IrMethod
import com.googlecode.dex2jar.ir.expr.Exprs
import com.googlecode.dex2jar.ir.expr.InvokeExpr
import com.googlecode.dex2jar.ir.expr.Value
import com.googlecode.dex2jar.ir.stmt.Stmts
import com.googlecode.dex2jar.ir.ts.NewTransformer
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Opcodes
import org.objectweb.asm.Type
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertSame

class ConstructorFixupsTest {
    open class InitializedParent(
        val label: String,
        val sequence: Long,
        val count: Int,
        val ratio: Double,
        val suffix: String,
    )

    @Test
    fun objectConstructorStillAllocatesTheSubclass() {
        for (localReceiver in listOf(false, true)) {
            val name = "moe/reader/suwayomi/generated/ObjectChild"
            val (allocation, needed) = convertAllocation(name, Any::class.java, emptyArray(), emptyArray(), localReceiver)
            val original = subclass(name, Any::class.java, allocation).toByteArray()
            val repaired = ConstructorFixups.addMissing(original, needed.getValue(name))
            val child = GeneratedClassLoader().define(name, repaired)

            // Invoke generated consumer bytecode, not reflection on the repaired constructor.
            val instance = child.getMethod("create").invoke(null)
            assertSame(child, instance.javaClass)
            assertEquals(name, child.getMethod("kind").invoke(instance))
        }
    }

    @Test
    fun repairedConstructorInitializesInheritedStateIncludingWideArguments() {
        val argumentTypes = arrayOf("Ljava/lang/String;", "J", "I", "D", "Ljava/lang/String;")
        val arguments = arrayOf<Value>(
            Exprs.nString("source"),
            Exprs.nLong(0x123456789ABCDEFL),
            Exprs.nInt(37),
            Exprs.nDouble(1.625),
            Exprs.nString("after-wide-slots"),
        )
        for (localReceiver in listOf(false, true)) {
            val name = "moe/reader/suwayomi/generated/InitializedChild"
            val (allocation, needed) = convertAllocation(name, InitializedParent::class.java, argumentTypes, arguments, localReceiver)
            val original = subclass(name, InitializedParent::class.java, allocation).toByteArray()
            val repaired = ConstructorFixups.addMissing(original, needed.getValue(name))
            val child = GeneratedClassLoader().define(name, repaired)
            val instance = child.getMethod(
                "create",
                String::class.java,
                Long::class.javaPrimitiveType!!,
                Int::class.javaPrimitiveType!!,
                Double::class.javaPrimitiveType!!,
                String::class.java,
            ).invoke(null, "source", 0x123456789ABCDEFL, 37, 1.625, "after-wide-slots")

            assertSame(child, instance.javaClass)
            val initialized = assertIs<InitializedParent>(instance)
            assertEquals("source", initialized.label)
            assertEquals(0x123456789ABCDEFL, initialized.sequence)
            assertEquals(37, initialized.count)
            assertEquals(1.625, initialized.ratio)
            assertEquals("after-wide-slots", initialized.suffix)
            assertEquals(name, child.getMethod("kind").invoke(instance))
        }
    }

    @Test
    fun existingConstructorIsLeftUntouched() {
        val name = "moe/reader/suwayomi/generated/ExistingChild"
        val (allocation, needed) = convertAllocation(name, Any::class.java, emptyArray(), emptyArray(), false)
        val writer = subclass(name, Any::class.java, allocation)
        writer.visitMethod(Opcodes.ACC_PUBLIC, "<init>", "()V", null, null).apply {
            visitCode()
            visitVarInsn(Opcodes.ALOAD, 0)
            visitMethodInsn(Opcodes.INVOKESPECIAL, "java/lang/Object", "<init>", "()V", false)
            visitInsn(Opcodes.RETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        val original = writer.toByteArray()
        val repaired = ConstructorFixups.addMissing(original, needed.getValue(name))

        assertSame(original, repaired, "An existing constructor must not be replaced or duplicated")
        val child = GeneratedClassLoader().define(name, repaired)
        val instance = child.getMethod("create").invoke(null)
        assertSame(child, instance.javaClass)
        assertEquals(name, child.getMethod("kind").invoke(instance))
    }

    private fun convertAllocation(
        name: String,
        superclass: Class<*>,
        argumentTypes: Array<String>,
        arguments: Array<Value>,
        localReceiver: Boolean,
    ): Pair<InvokeExpr, Map<String, List<ConstructorFixups.Needed>>> {
        val method = IrMethod().apply {
            owner = "L$name;"
            this.name = "allocate"
            args = emptyArray()
            ret = "V"
            isStatic = true
        }
        val newInstance = Exprs.nNew("L$name;")
        val receiver = if (localReceiver) {
            Exprs.nLocal(0).also {
                method.locals.add(it)
                method.stmts.add(Stmts.nAssign(it, newInstance))
            }
        } else {
            newInstance
        }
        val invocation = Exprs.nInvokeSpecial(
            arrayOf(receiver, *arguments),
            Type.getDescriptor(superclass),
            "<init>",
            argumentTypes,
            "V",
        )
        method.stmts.add(Stmts.nVoidInvoke(invocation))
        method.stmts.add(Stmts.nReturnVoid())
        return ConstructorFixups.collect {
            // Exercise both patched NewTransformer paths: a local NEW and an inline NEW.
            NewTransformer().transform(method)
            val first = method.stmts.first
            assertIs<InvokeExpr>(if (localReceiver) first.op2 else first.op)
        }
    }

    /** No constructor is generated here: R8 removed it from the allocated class. */
    private fun subclass(name: String, superclass: Class<*>, allocation: InvokeExpr): ClassWriter {
        val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
        writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC or Opcodes.ACC_SUPER, name, null, Type.getInternalName(superclass), null)
        val argumentTypes = allocation.args.map { Type.getType(it) }.toTypedArray()
        val constructorDescriptor = Type.getMethodDescriptor(Type.VOID_TYPE, *argumentTypes)
        val allocatedName = Type.getType(allocation.owner).internalName
        writer.visitMethod(
            Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC,
            "create",
            Type.getMethodDescriptor(Type.getType(Any::class.java), *argumentTypes),
            null,
            null,
        ).apply {
            visitCode()
            visitTypeInsn(Opcodes.NEW, allocatedName)
            visitInsn(Opcodes.DUP)
            var slot = 0
            for (argument in argumentTypes) {
                visitVarInsn(argument.getOpcode(Opcodes.ILOAD), slot)
                slot += argument.size
            }
            visitMethodInsn(Opcodes.INVOKESPECIAL, allocatedName, "<init>", constructorDescriptor, false)
            visitInsn(Opcodes.ARETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitMethod(Opcodes.ACC_PUBLIC, "kind", "()Ljava/lang/String;", null, null).apply {
            visitCode()
            visitLdcInsn(name)
            visitInsn(Opcodes.ARETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitEnd()
        return writer
    }

    private class GeneratedClassLoader : ClassLoader(ConstructorFixupsTest::class.java.classLoader) {
        fun define(name: String, bytes: ByteArray): Class<*> = defineClass(name.replace('/', '.'), bytes, 0, bytes.size)
    }
}
