package conformance;

/** Literals from another class, to check cross-class literal interning. */
final class StringPeer {
    private StringPeer() {}

    static final String HELLO = "hello";

    static String hello() {
        return "hello";
    }

    static String zq() {
        return "zq";
    }
}
