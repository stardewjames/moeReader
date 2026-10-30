package conformance;

import java.io.IOException;
import java.io.UncheckedIOException;

import static conformance.Fmt.join;
import static conformance.Fmt.name;
import static conformance.Fmt.o;
import static conformance.Fmt.v;

public final class ExceptionCases {
    private ExceptionCases() {}

    static final class MyException extends RuntimeException {
        MyException(String message) {
            super(message);
        }
    }

    static final class CheckedOne extends Exception {
        CheckedOne() {}
    }

    static final class Resource implements AutoCloseable {
        private final String label;
        private final StringBuilder log;
        private final boolean failOnClose;

        Resource(String label, StringBuilder log, boolean failOnClose) {
            this.label = label;
            this.log = log;
            this.failOnClose = failOnClose;
            log.append("open:").append(label).append(';');
        }

        @Override
        public void close() {
            log.append("close:").append(label).append(';');
            if (failOnClose) throw new IllegalStateException(label);
        }
    }

    public static String nestedFinallyOrder() {
        StringBuilder sb = new StringBuilder();
        try {
            sb.append("t1;");
            try {
                sb.append("t2;");
                if (v(true)) throw new IllegalStateException();
                sb.append("unreached;");
            } catch (IllegalArgumentException e) {
                sb.append("wrong;");
            } finally {
                sb.append("f2;");
            }
            sb.append("unreached2;");
        } catch (IllegalStateException e) {
            sb.append("c1;");
        } finally {
            sb.append("f1;");
        }
        return sb.toString();
    }

    private static String finallyReturnOrder(StringBuilder log) {
        try {
            log.append("try;");
            return log.append("ret;").toString();
        } finally {
            log.append("finally;");
        }
    }

    public static String finallyAfterReturnValue() {
        StringBuilder log = new StringBuilder();
        String returned = finallyReturnOrder(log);
        return returned + "|" + log;
    }

    @SuppressWarnings("finally")
    private static int finallyOverridesReturn() {
        try {
            if (v(true)) throw new MyException("lost");
            return 1;
        } finally {
            return 2;
        }
    }

    public static String finallyReturnSwallowsException() {
        return Integer.toString(finallyOverridesReturn());
    }

    public static String finallyOnLoopControl() {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < 4; i++) {
            try {
                if (i == 1) continue;
                if (i == 3) break;
                out.append(i);
            } finally {
                out.append('f');
            }
        }
        return out.toString();
    }

    public static String catchAllThrowable() {
        try {
            if (v(true)) throw new AssertionError("x");
            return "none";
        } catch (Throwable t) {
            return name(t) + ":" + (t instanceof Error);
        }
    }

    public static String rethrowSameInstance() {
        RuntimeException[] saved = new RuntimeException[1];
        try {
            try {
                if (v(true)) throw new MyException("m");
            } catch (MyException e) {
                saved[0] = e;
                throw e;
            }
            return "none";
        } catch (RuntimeException outer) {
            return join(outer == saved[0], name(outer), outer.getMessage());
        }
    }

    public static String exceptionInCatchReplaces() {
        try {
            try {
                if (v(true)) throw new IllegalArgumentException();
            } catch (IllegalArgumentException e) {
                throw new UnsupportedOperationException();
            } finally {
                Fmt.v(0);
            }
            return "none";
        } catch (RuntimeException e) {
            return join(name(e), e.getCause());
        }
    }

    public static String causeChain() {
        Throwable t = new RuntimeException(new IOException(new Error()));
        StringBuilder out = new StringBuilder();
        for (Throwable c = t; c != null; c = c.getCause()) out.append(name(c)).append('>');
        return out.toString();
    }

    public static String causeConstructorsMessage() {
        RuntimeException plain = new RuntimeException(new IOException("io"));
        RuntimeException nullCause = new RuntimeException((Throwable) null);
        RuntimeException withMessage = new RuntimeException("m", new Error());
        return join(plain.getMessage(), nullCause.getMessage(), nullCause.getCause(), withMessage.getMessage(),
            name(withMessage.getCause()), new UncheckedIOException(new IOException("u")).getMessage());
    }

    public static String initCause() {
        Exception e = new Exception();
        StringBuilder out = new StringBuilder();
        out.append(e.getCause()).append(';');
        Throwable returned = e.initCause(new ArithmeticException());
        out.append(returned == e).append(';').append(name(e.getCause())).append(';');
        try {
            e.initCause(new Error());
        } catch (IllegalStateException again) {
            out.append("ISE;");
        }
        Exception self = new Exception();
        try {
            self.initCause(self);
        } catch (IllegalArgumentException loop) {
            out.append("IAE;");
        }
        Exception constructed = new Exception("m", null);
        try {
            constructed.initCause(new Error());
        } catch (IllegalStateException fixed) {
            out.append("ISE2;");
        }
        Exception nullInit = new Exception();
        nullInit.initCause(null);
        out.append(nullInit.getCause());
        return out.toString();
    }

    public static String throwableToString() {
        return join(new MyException("boom").toString(), new IllegalStateException().toString(),
            new CheckedOne().getMessage(), "[" + new Exception("").toString() + "]");
    }

    public static String tryWithResourcesSuppressed() {
        StringBuilder log = new StringBuilder();
        try (Resource a = new Resource("a", log, true); Resource b = new Resource("b", log, true)) {
            log.append("body;");
            throw new MyException("body");
        } catch (MyException e) {
            Throwable[] suppressed = e.getSuppressed();
            log.append("suppressed=").append(suppressed.length);
            for (Throwable s : suppressed) log.append(':').append(s.getMessage());
        }
        return log.toString();
    }

    public static String tryWithResourcesCloseFailure() {
        StringBuilder log = new StringBuilder();
        try (Resource a = new Resource("a", log, true); Resource b = new Resource("b", log, false)) {
            log.append("body;");
        } catch (IllegalStateException e) {
            log.append("caught:").append(e.getMessage()).append(";suppressed=").append(e.getSuppressed().length);
        }
        return log.toString();
    }

    public static String tryWithResourcesNullResource() {
        StringBuilder log = new StringBuilder();
        try (Resource a = null) {
            log.append("body:").append(a == null);
        }
        return log.toString();
    }

    public static String addSuppressedRules() {
        Exception e = new Exception();
        StringBuilder out = new StringBuilder();
        try {
            e.addSuppressed(e);
        } catch (IllegalArgumentException self) {
            out.append("IAE;");
        }
        try {
            e.addSuppressed(null);
        } catch (NullPointerException npe) {
            out.append("NPE;");
        }
        e.addSuppressed(new Error());
        e.addSuppressed(new MyException("s"));
        out.append(e.getSuppressed().length).append(name(e.getSuppressed()[1]));
        return out.toString();
    }

    public static String catchOrderAndMultiCatch() {
        StringBuilder out = new StringBuilder();
        RuntimeException[] errors = {new IllegalArgumentException(), new IllegalStateException(), new NumberFormatException(),
            new ArithmeticException(), new MyException("x")};
        for (RuntimeException error : errors) {
            try {
                throw error;
            } catch (NumberFormatException e) {
                out.append("NFE;");
            } catch (IllegalArgumentException | IllegalStateException e) {
                out.append("multi:").append(name(e)).append(';');
            } catch (MyException e) {
                out.append("mine;");
            } catch (RuntimeException e) {
                out.append("rt;");
            }
        }
        return out.toString();
    }

    private static int depth(int n, StringBuilder log) {
        try {
            if (n == 0) throw new MyException("deep");
            return depth(n - 1, log);
        } finally {
            log.append(n);
        }
    }

    public static String unwindThroughFrames() {
        StringBuilder log = new StringBuilder();
        try {
            depth(4, log);
            return "none";
        } catch (MyException e) {
            return log.append(';').append(e.getMessage()).toString();
        }
    }

    public static String uncaughtCustomException() {
        throw new MyException("escapes");
    }

    public static String uncaughtChecked() throws CheckedOne {
        if (v(true)) throw new CheckedOne();
        return "none";
    }

    public static String nullPointerSources() {
        StringBuilder out = new StringBuilder();
        Object nothing = o(null);
        try {
            out.append(nothing.hashCode());
        } catch (NullPointerException e) {
            out.append("invoke;");
        }
        try {
            out.append(((ExceptionCases.Resource) nothing).label);
        } catch (NullPointerException e) {
            out.append("field;");
        }
        try {
            throw (RuntimeException) nothing;
        } catch (NullPointerException e) {
            out.append("throw-null;");
        }
        try {
            synchronized (nothing) {
                out.append("locked");
            }
        } catch (NullPointerException e) {
            out.append("monitor;");
        }
        try {
            Integer boxed = (Integer) nothing;
            int unboxed = boxed;
            out.append(unboxed);
        } catch (NullPointerException e) {
            out.append("unbox;");
        }
        return out.toString();
    }

    public static String arithmeticInFinally() {
        StringBuilder out = new StringBuilder();
        try {
            try {
                out.append("body;");
            } finally {
                out.append(v(1) / v(0));
            }
        } catch (ArithmeticException e) {
            out.append("AE");
        }
        return out.toString();
    }

    public static String exceptionFromConstructor() {
        try {
            new Resource("c", null, false);
            return "none";
        } catch (NullPointerException e) {
            return "NPE";
        }
    }

    public static String stackTraceIsArray() {
        Throwable t = new Throwable();
        StackTraceElement[] trace = t.getStackTrace();
        Throwable noTrace = new RuntimeException("m", null, false, false) {};
        noTrace.addSuppressed(new Error());
        return join(trace != null, noTrace.getSuppressed().length, noTrace.getStackTrace().length);
    }

    public static String synchronizedReleasesOnThrow() {
        Object lock = new Object();
        StringBuilder out = new StringBuilder();
        try {
            synchronized (lock) {
                out.append("in;");
                if (v(true)) throw new MyException("x");
            }
        } catch (MyException e) {
            out.append("caught;");
        }
        synchronized (lock) {
            out.append("reentered");
        }
        return out.toString();
    }

    private static final class Locked {
        synchronized boolean instance() { return Thread.holdsLock(this); }
        static synchronized boolean staticMethod() { return Thread.holdsLock(Locked.class); }
        synchronized void throwing() { throw new IllegalStateException(); }
    }

    public static String monitorOwnership() {
        Locked lock = new Locked();
        boolean inside = lock.instance();
        boolean outside = Thread.holdsLock(lock);
        boolean statically = Locked.staticMethod();
        try { lock.throwing(); } catch (IllegalStateException expected) {}
        boolean released = !Thread.holdsLock(lock);
        boolean nested;
        synchronized (lock) {
            synchronized (lock) { nested = Thread.holdsLock(lock); }
            nested &= Thread.holdsLock(lock);
        }
        String result = join(inside, outside, statically, released, nested, Thread.holdsLock(lock));
        try { Thread.holdsLock(null); } catch (NullPointerException expected) { result += ";NPE"; }
        return result;
    }
}
