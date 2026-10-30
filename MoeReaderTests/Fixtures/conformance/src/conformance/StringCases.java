package conformance;

import java.nio.charset.StandardCharsets;
import java.util.Locale;

import static conformance.Fmt.join;
import static conformance.Fmt.o;
import static conformance.Fmt.v;

public final class StringCases {
    private StringCases() {}

    public static String loneSurrogateLiteral() {
        String s = "\uD800x";
        return join(s.length(), (int) s.charAt(0), (int) s.charAt(1), Character.isHighSurrogate(s.charAt(0)),
            s.codePointAt(0), s.codePointCount(0, s.length()));
    }

    public static String trailingLoneSurrogate() {
        String s = "y\uDC00";
        return join(s.length(), (int) s.charAt(1), Character.isLowSurrogate(s.charAt(1)), s.equals("y" + (char) v(0xDC00)));
    }

    public static String surrogatePairLiteral() {
        String s = "\uD83D\uDE00";
        return join(s.length(), s.codePointAt(0), s.codePointCount(0, 2), (int) s.charAt(1), Character.charCount(s.codePointAt(0)),
            new String(Character.toChars(0x1F600)).equals(s));
    }

    public static String embeddedNulLiteral() {
        String s = "a\u0000b";
        return join(s.length(), (int) s.charAt(1), s.indexOf('\u0000'), s.getBytes(StandardCharsets.UTF_8).length);
    }

    public static String nonAsciiLiteral() {
        String s = "\u00e9\u4e2d\u0800\u07ff";
        return join(s.length(), (int) s.charAt(0), (int) s.charAt(1), (int) s.charAt(2), (int) s.charAt(3),
            s.getBytes(StandardCharsets.UTF_8).length, s);
    }

    public static String literalIdentity() {
        String a = "a";
        String b = "a";
        return join(a == b, "hello" == StringPeer.hello(), "a" + "b" == "ab", v("a") + "b" == "ab", StringPeer.HELLO == "hello");
    }

    public static String internIdentity() {
        String fresh = new String("a");
        String built = v("a") + v("b");
        return join(fresh == "a", fresh.intern() == "a", built == "ab", built.intern() == "ab", fresh.equals("a"),
            new String(new char[] {'z', 'q'}).intern() == StringPeer.zq());
    }

    public static String hashCodes() {
        return join("".hashCode(), "a".hashCode(), "polygenelubricants".hashCode(), "Aa".hashCode() == "BB".hashCode(),
            "\uD800x".hashCode(), "\u00e9".hashCode());
    }

    public static String concatenation() {
        char c = v('a');
        long l = v(-5L);
        Object n = o(null);
        boolean z = v(true);
        String s = null;
        return "" + c + 1 + ';' + (c + 1) + ';' + l + n + z + s + ';' + 1.5 + ';' + (char) v(0x263a) + 'x' + 2.0f;
    }

    public static String concatenationOfCharArithmetic() {
        return ('a' + 1) + "" + (char) ('a' + 1) + 'b' + 'c' + ('b' + 'c');
    }

    public static String compareAndEquals() {
        return join("abc".compareTo("abd"), "b".compareTo("abc"), "abc".compareTo("ab"), "ABC".equalsIgnoreCase("abc"),
            "a".compareToIgnoreCase("B"), "\uD800".compareTo("\uE000"), "".isEmpty(), "x".equals(null));
    }

    public static String splitting() {
        return join("a,b,,c,,".split(",").length, "a,b,,c,,".split(",", -1).length, ",a".split(",").length, "".split(",").length,
            "a1b22c".split("\\d+").length, String.join("|", "a1b22c".split("(?<=\\d)(?=\\D)")));
    }

    public static String trimmingAndCase() {
        return join("[" + "  x \t".trim() + "]", "[" + "\u2003y\u2003".strip() + "]", "\u00df".toUpperCase(Locale.ROOT),
            "I".toLowerCase(Locale.ROOT), "aBc".toUpperCase(Locale.ROOT), "\u00c9".toLowerCase(Locale.ROOT));
    }

    public static String searching() {
        String s = "abcabc";
        return join(s.indexOf('c', -5), s.indexOf("bc", 2), s.lastIndexOf('a'), s.lastIndexOf("abc", 2), s.indexOf(""),
            s.indexOf("", 99), s.contains("ca"), s.startsWith("bc", 1), s.endsWith(""), s.indexOf(0x1F600));
    }

    public static String substringErrors() {
        StringBuilder out = new StringBuilder();
        try {
            out.append("abc".substring(2, 1));
        } catch (StringIndexOutOfBoundsException e) {
            out.append("SIOOBE1;");
        }
        try {
            out.append("abc".charAt(3));
        } catch (StringIndexOutOfBoundsException e) {
            out.append("SIOOBE2;");
        }
        try {
            out.append("abc".substring(-1));
        } catch (IndexOutOfBoundsException e) {
            out.append("IOOBE;");
        }
        out.append("abc".substring(3)).append('|').append("abc".substring(1, 1)).append('|').append("abc".subSequence(0, 2));
        return out.toString();
    }

    public static String charAtEscapes() {
        return String.valueOf("abc".charAt(v(-1)));
    }

    public static String builderOperations() {
        StringBuilder b = new StringBuilder("hello");
        b.insert(0, 12).append('!').append(-1L).append(true).append((Object) null).reverse();
        StringBuilder d = new StringBuilder("abcdef");
        d.delete(1, 3).deleteCharAt(0).replace(0, 1, "XY").setCharAt(1, 'z');
        StringBuilder e = new StringBuilder("ab");
        e.setLength(4);
        return join(b, d, e.length(), (int) e.charAt(3), new StringBuilder("q").indexOf("q"));
    }

    public static String builderReverseKeepsSurrogates() {
        String reversed = new StringBuilder("a\uD83D\uDE00b").reverse().toString();
        return join(reversed.length(), (int) reversed.charAt(1), (int) reversed.charAt(2), reversed.codePointAt(1));
    }

    public static String valueOfAndConversions() {
        char[] chars = {'x', 'y', 'z'};
        return join(String.valueOf((Object) null), String.valueOf(chars, 1, 2), String.valueOf(true), String.valueOf('c'),
            String.valueOf(-0L), new String(chars, 0, 1), String.copyValueOf(chars), "abc".toCharArray().length);
    }

    public static String repeatAndJoin() {
        return join("ab".repeat(3), "x".repeat(0).isEmpty(), String.join("-", "a", "b", "c"), String.join(",", new java.util.ArrayList<String>()),
            "  ".isBlank(), "a\nb\r\nc".lines().count());
    }

    public static String formatRoot() {
        return String.format(Locale.ROOT, "%05d|%-3s|%x|%X|%c|%b|%%|%s|%,d|%+d|%o", 42, "a", 255, -1, 'q', null, "z", 1234567, 7, 8);
    }

    public static String utf8RoundTrip() {
        String s = "a\u00e9\u4e2d\uD83D\uDE00";
        byte[] bytes = s.getBytes(StandardCharsets.UTF_8);
        StringBuilder hex = new StringBuilder();
        for (byte b : bytes) hex.append(Integer.toHexString(b & 0xff)).append(' ');
        return join(bytes.length, hex.toString().trim(), new String(bytes, StandardCharsets.UTF_8).equals(s),
            s.getBytes(StandardCharsets.UTF_16BE).length, s.getBytes(StandardCharsets.ISO_8859_1).length);
    }

    public static String charClassification() {
        return join(Character.isDigit('7'), Character.isLetter('\u00e9'), Character.isWhitespace('\u00a0'),
            Character.isWhitespace('\t'), Character.isUpperCase('A'), (int) Character.toUpperCase('z'),
            Character.digit('f', 16), Character.digit('g', 16), Character.isJavaIdentifierStart('$'));
    }

    public static String nullReceiver() {
        String s = (String) o(null);
        return Integer.toString(s.length());
    }

    public static String equalsAndContentEquals() {
        StringBuilder sb = new StringBuilder("abc");
        return join("abc".contentEquals(sb), "abc".equals(sb), "abc".equals(sb.toString()), "abc".regionMatches(true, 1, "XBC", 1, 2),
            "a".concat("b"), "aaa".replace("aa", "b"), "a.b.c".replaceAll("\\.", "/"), "aXbXc".replaceFirst("X", "-"));
    }
}
