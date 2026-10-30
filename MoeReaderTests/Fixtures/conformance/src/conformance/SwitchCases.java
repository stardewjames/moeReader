package conformance;

import static conformance.Fmt.o;
import static conformance.Fmt.v;

public final class SwitchCases {
    private SwitchCases() {}

    enum Color { RED, GREEN, BLUE, ALPHA }

    private static String packed(int x) {
        switch (x) {
            case 0: return "zero";
            case 1: return "one";
            case 2: return "two";
            case 3: return "three";
            case 4: return "four";
            case 5: return "five";
            default: return "d";
        }
    }

    private static String sparse(int x) {
        switch (x) {
            case Integer.MIN_VALUE: return "min";
            case -1000: return "-1000";
            case 0: return "0";
            case 7: return "7";
            case 1 << 20: return "2^20";
            case Integer.MAX_VALUE: return "max";
            default: return "d";
        }
    }

    public static String packedSwitch() {
        StringBuilder out = new StringBuilder();
        for (int i = -1; i <= 7; i++) out.append(packed(i)).append(';');
        out.append(packed(Integer.MIN_VALUE)).append(packed(Integer.MAX_VALUE));
        return out.toString();
    }

    public static String packedSwitchNegativeBase() {
        StringBuilder out = new StringBuilder();
        for (int i = -5; i <= 0; i++) {
            switch (i) {
                case -4: out.append('a'); break;
                case -3: out.append('b'); break;
                case -2: out.append('c'); break;
                case -1: out.append('d'); break;
                default: out.append('_');
            }
        }
        return out.toString();
    }

    public static String sparseSwitch() {
        StringBuilder out = new StringBuilder();
        int[] probes = {Integer.MIN_VALUE, -1001, -1000, -1, 0, 6, 7, 8, 1 << 20, (1 << 20) + 1, Integer.MAX_VALUE};
        for (int p : probes) out.append(sparse(p)).append(';');
        return out.toString();
    }

    public static String fallThrough() {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < 4; i++) {
            switch (i) {
                case 0: out.append('a');
                case 1: out.append('b');
                    break;
                case 2: out.append('c');
                default: out.append('d');
            }
            out.append('|');
        }
        return out.toString();
    }

    private static String strings(String s) {
        switch (s) {
            case "a": return "A";
            case "b": return "B";
            case "Aa": return "Aa";
            case "BB": return "BB";
            case "": return "empty";
            case "\u00e9": return "e-acute";
            default: return "d:" + s;
        }
    }

    public static String stringSwitch() {
        StringBuilder out = new StringBuilder();
        for (String s : new String[] {"a", "b", "Aa", "BB", "C#", "", "\u00e9", "aa", "c"}) out.append(strings(s)).append(';');
        return out.toString();
    }

    public static String stringSwitchNull() {
        return strings((String) o(null));
    }

    private static String colors(Color c) {
        switch (c) {
            case GREEN: return "g";
            case RED: return "r";
            case ALPHA: return "a";
            default: return "other";
        }
    }

    public static String enumSwitch() {
        StringBuilder out = new StringBuilder();
        for (Color c : Color.values()) out.append(colors(c)).append(c.ordinal()).append(c.name()).append(';');
        return out.toString();
    }

    public static String enumSwitchNull() {
        return colors((Color) o(null));
    }

    public static String enumHelpers() {
        StringBuilder out = new StringBuilder();
        out.append(Color.valueOf("BLUE").ordinal()).append(';').append(Color.BLUE.compareTo(Color.RED)).append(';')
            .append(Color.values().length).append(';').append(Color.values() != Color.values()).append(';')
            .append(Enum.valueOf(Color.class, "ALPHA")).append(';').append(Color.RED.getDeclaringClass().getSimpleName());
        try {
            Color.valueOf("PURPLE");
        } catch (IllegalArgumentException e) {
            out.append(";IAE");
        }
        try {
            Color.valueOf(null);
        } catch (NullPointerException e) {
            out.append(";NPE");
        }
        return out.toString();
    }

    public static String charSwitch() {
        StringBuilder out = new StringBuilder();
        for (char c : "az\uffff\u0000Q".toCharArray()) {
            switch (c) {
                case 'a': out.append("A"); break;
                case 'z': out.append("Z"); break;
                case '\uffff': out.append("max"); break;
                case 0: out.append("nul"); break;
                default: out.append((int) c);
            }
        }
        return out.toString();
    }

    public static String switchExpression() {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < 5; i++) {
            String r = switch (i) {
                case 0, 1 -> "low";
                case 2 -> {
                    String t = "mid";
                    yield t + i;
                }
                default -> "high" + (i * 2);
            };
            out.append(r).append(';');
        }
        String day = v("TUE");
        int len = switch (day) {
            case "MON", "TUE" -> 3;
            default -> -1;
        };
        return out.append(len).toString();
    }

    public static String labeledBreakContinue() {
        StringBuilder out = new StringBuilder();
        outer:
        for (int i = 0; i < 4; i++) {
            for (int j = 0; j < 4; j++) {
                switch ((i + j) % 3) {
                    case 0: continue;
                    case 1:
                        if (j == 2) continue outer;
                        out.append(i).append(j).append('.');
                        break;
                    default:
                        if (i == 3) break outer;
                        out.append('x');
                }
            }
            out.append('|');
        }
        return out.toString();
    }

    public static String longKeysThroughHash() {
        StringBuilder out = new StringBuilder();
        for (long key : new long[] {1L << 40, -1L, 3L}) {
            switch (Long.hashCode(key)) {
                case 256: out.append("2^40;"); break;
                case 0: out.append("minus-one;"); break;
                default: out.append(Long.hashCode(key)).append(';');
            }
        }
        return out.toString();
    }
}
