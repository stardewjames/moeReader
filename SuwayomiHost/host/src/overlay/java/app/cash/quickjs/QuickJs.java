package app.cash.quickjs;

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Modified for MoeReader: overlay of AndroidCompat's app.cash.quickjs.QuickJs.
 * Upstream runs scripts on GraalJS, which is far too heavy for an
 * interpreter-only JVM on a phone. Scripts run in a JavaScriptCore context
 * owned by the app instead (one context per QuickJs instance, released on
 * close), and results are translated to the same Java types upstream returns.
 * Binding host objects into the script (set) is not available: JavaScriptCore
 * cannot call back into the JVM.
 */

import moe.reader.suwayomi.Host;
import moe.reader.suwayomi.JsEvaluationException;
import moe.reader.suwayomi.JsValue;

import java.io.Closeable;
import java.nio.charset.StandardCharsets;
import java.util.List;

public final class QuickJs implements Closeable {
    private long context;

    public static QuickJs create() {
        return new QuickJs();
    }

    public QuickJs() {
        this.context = Host.INSTANCE.getServices().jsCreate();
    }

    public Object evaluate(String script, String ignoredFileName) {
        return evaluate(script);
    }

    public Object evaluate(String script) {
        if (context == 0) throw new IllegalStateException("QuickJs instance is closed");
        try {
            return translate(Host.INSTANCE.getServices().jsEvaluate(context, script));
        } catch (JsEvaluationException exception) {
            throw new QuickJsException(exception.getMessage(), exception);
        }
    }

    public byte[] compile(String sourceCode, String ignoredFileName) {
        return sourceCode.getBytes(StandardCharsets.UTF_8);
    }

    public Object execute(byte[] bytecode) {
        return evaluate(new String(bytecode, StandardCharsets.UTF_8));
    }

    public <T> void set(String name, Class<T> ignoredType, T object) {
        throw new UnsupportedOperationException("QuickJs.set: host objects cannot be bound into JavaScriptCore");
    }

    @Override
    public void close() {
        if (context != 0) {
            Host.INSTANCE.getServices().jsClose(context);
            context = 0;
        }
    }

    private static Object translate(JsValue value) {
        if (value instanceof JsValue.Bool) return ((JsValue.Bool) value).getValue();
        if (value instanceof JsValue.Text) return ((JsValue.Text) value).getValue();
        if (value instanceof JsValue.Number) return number(((JsValue.Number) value).getValue());
        if (value instanceof JsValue.Array) return array(((JsValue.Array) value).getValues());
        return null;
    }

    private static Object number(double value) {
        if (value == Math.rint(value) && !Double.isInfinite(value)) {
            if (value >= Integer.MIN_VALUE && value <= Integer.MAX_VALUE) return (int) value;
            if (value >= Long.MIN_VALUE && value <= Long.MAX_VALUE) return (long) value;
        }
        return value;
    }

    private static Object array(List<JsValue> values) {
        if (values.isEmpty()) return new int[0];
        JsValue first = values.get(0);
        int count = values.size();
        if (first instanceof JsValue.Bool) {
            boolean[] result = new boolean[count];
            for (int i = 0; i < count; i++) result[i] = values.get(i) instanceof JsValue.Bool && ((JsValue.Bool) values.get(i)).getValue();
            return result;
        }
        if (first instanceof JsValue.Number) {
            boolean ints = true;
            for (JsValue element : values) {
                if (!(element instanceof JsValue.Number) || !(number(((JsValue.Number) element).getValue()) instanceof Integer)) {
                    ints = false;
                    break;
                }
            }
            if (ints) {
                int[] result = new int[count];
                for (int i = 0; i < count; i++) result[i] = (int) ((JsValue.Number) values.get(i)).getValue();
                return result;
            }
            double[] result = new double[count];
            for (int i = 0; i < count; i++) {
                JsValue element = values.get(i);
                result[i] = element instanceof JsValue.Number ? ((JsValue.Number) element).getValue() : Double.NaN;
            }
            return result;
        }
        if (first instanceof JsValue.Text) {
            String[] result = new String[count];
            for (int i = 0; i < count; i++) {
                Object element = translate(values.get(i));
                result[i] = element == null ? null : element.toString();
            }
            return result;
        }
        Object[] result = new Object[count];
        for (int i = 0; i < count; i++) result[i] = translate(values.get(i));
        return result;
    }
}
