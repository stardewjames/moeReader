package moe.reader.suwayomi

import com.googlecode.dex2jar.ir.expr.InvokeExpr
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes
import org.objectweb.asm.Type

/**
 * Constructors R8 inlined away. Android code may allocate `Lz;` and run a
 * superclass constructor on it directly; JVM bytecode cannot express that, so
 * the patched dex2jar NewTransformer keeps `new z(...)` and records here that
 * `z` needs an `<init>` with the same descriptor delegating to the superclass
 * constructor the dex called. [addMissing] then adds exactly those.
 */
object ConstructorFixups {
    class Needed(
        /** Internal name of the delegate's owner, e.g. `java/lang/Object`. */
        val owner: String,
        val descriptor: String,
    )

    private val recording = ThreadLocal<MutableMap<String, MutableList<Needed>>?>()

    /** Runs [body] (a dex2jar conversion) and returns the constructors it needs, by internal class name. */
    fun <T> collect(body: () -> T): Pair<T, Map<String, List<Needed>>> {
        val needed = HashMap<String, MutableList<Needed>>()
        recording.set(needed)
        try {
            return body() to needed
        } finally {
            recording.remove()
        }
    }

    /** Called by NewTransformer: the type to allocate for `NEW type` + `ie` (an `<init>` call). */
    @JvmStatic
    fun allocatedType(
        newType: String,
        ie: InvokeExpr,
    ): String {
        val owner = ie.owner
        if (newType == owner) return owner
        val descriptor = Type.getMethodDescriptor(Type.VOID_TYPE, *ie.args.map { Type.getType(it) }.toTypedArray())
        val type = Type.getType(newType).internalName
        recording.get()?.getOrPut(type) { mutableListOf() }?.let { list ->
            if (list.none { it.descriptor == descriptor }) list += Needed(Type.getType(owner).internalName, descriptor)
        }
        return newType
    }

    /** [bytes] of one class with the constructors it lacks added. */
    fun addMissing(
        bytes: ByteArray,
        needed: List<Needed>,
    ): ByteArray {
        val reader = ClassReader(bytes)
        val declared = HashSet<String>()
        reader.accept(
            object : ClassVisitor(Opcodes.ASM9) {
                override fun visitMethod(
                    access: Int,
                    name: String,
                    descriptor: String,
                    signature: String?,
                    exceptions: Array<out String>?,
                ): MethodVisitor? {
                    if (name == "<init>") declared += descriptor
                    return null
                }
            },
            ClassReader.SKIP_CODE,
        )
        val missing = needed.filter { it.descriptor !in declared }
        if (missing.isEmpty()) return bytes
        val writer = ClassWriter(reader, 0)
        reader.accept(writer, 0)
        for (constructor in missing) {
            val method = writer.visitMethod(Opcodes.ACC_PUBLIC or Opcodes.ACC_SYNTHETIC, "<init>", constructor.descriptor, null, null)
            method.visitCode()
            method.visitVarInsn(Opcodes.ALOAD, 0)
            var slot = 1
            for (argument in Type.getArgumentTypes(constructor.descriptor)) {
                method.visitVarInsn(argument.getOpcode(Opcodes.ILOAD), slot)
                slot += argument.size
            }
            method.visitMethodInsn(Opcodes.INVOKESPECIAL, constructor.owner, "<init>", constructor.descriptor, false)
            method.visitInsn(Opcodes.RETURN)
            method.visitMaxs(slot, slot)
            method.visitEnd()
        }
        return writer.toByteArray()
    }
}
