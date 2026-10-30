#!/usr/bin/env python3
"""Track every extension in an extension repository against the MihonCompat engine.

Each run checks two things per APK:

- static: the APK's DEX host references compared with the engine's native
  registry (`analyze_compat.audit_apk`). Pure Python 3.10+, runs anywhere.
- live: the Linux build of the runtime harness (`SiteTests/harness`) loads the
  APK and exercises popular, search, details, chapters and pages. The harness
  reaches the network, or replays recorded fixtures with `--replay`. On Windows
  it runs inside WSL; elsewhere it runs natively (`--distro ""`).

Results go under `SiteTests/matrix/`, which is git-ignored because package
names identify sites:

    inventory.json   every index entry, its APK file and whether that file exists
    runs/<id>.json   one record per run: engine fingerprint and per-extension results
    status.json      latest result per extension, merged across runs
    logs/<pkg>.log   latest live harness output per extension
    REPORT.md        status table (written by `run` and `report`)
    CHANGES.md       regressions and fixes between two runs (written by `diff`)

Subcommands:

    extension_matrix.py build                      build the Linux harness
    extension_matrix.py run [--live] [--only PKG,...] [--limit N]
    extension_matrix.py diff [RUN_A RUN_B]         default: the two latest runs
    extension_matrix.py history PKG
    extension_matrix.py report
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import shutil
import re
import subprocess
import sys
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import analyze_compat  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
MATRIX = ROOT / "SiteTests" / "matrix"
DEFAULT_REPO = Path(os.environ.get("MOEREADER_EXTENSION_REPO", ROOT / "SiteTests" / "keiyoushi-extensions"))
DEFAULT_DISTRO = os.environ.get("MOE_HARNESS_WSL_DISTRO", "Ubuntu-24.04" if sys.platform == "win32" else "")
DEFAULT_HARNESS = "/tmp/sitetest-harness/.build/release/Harness"
APK_NAME = re.compile(r"^tachiyomi-(.+)-v[^/]+\.apk$")

# Lower is healthier. Outcomes not listed (skipped, missing, not run) are not ranked.
RANK = {"ok": 0, "fail": 1, "load-fail": 2, "crash": 2, "timeout": 2, "error": 2}
ORDER = {"crash": 0, "timeout": 1, "error": 2, "load-fail": 3, "fail": 4, "not run": 5,
         "missing": 6, "skipped": 7, "ok": 8}

HARNESS_RESULT = re.compile(r"^RESULT (OK|FAIL)(.*)$")
HARNESS_STEP_FAILED = re.compile(r"^!!! (.+?) failed: (.*)$")
HARNESS_SOURCES = re.compile(r"^sources (\d+):")
HARNESS_REQUESTS = re.compile(r"requests=(\d+)$")


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def load_json(path: Path, default):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else default


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")


def git(repo: Path, *args: str) -> str:
    done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else ""


def to_wsl(path: Path) -> str:
    resolved = Path(path).resolve()
    if resolved.drive:
        return f"/mnt/{resolved.drive[0].lower()}{resolved.as_posix()[2:]}"
    return resolved.as_posix()


def host_path(args, path: Path) -> str:
    return to_wsl(path) if args.distro else str(path)


def escape(value) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


# ---------------------------------------------------------------- inventory

def build_inventory(repo: Path) -> dict:
    index = json.loads((repo / "index.json").read_text(encoding="utf-8"))
    items = []
    for entry in index["extensionList"]["extensions"]:
        url = entry["resources"]["apkUrl"]
        match = APK_NAME.match(url.rsplit("/", 1)[-1])
        if not match:
            raise SystemExit(f"unrecognised APK URL in index: {url}")
        sources = entry.get("sources", [])
        items.append({
            "package": entry["packageName"],
            "name": entry["name"],
            "version": entry["versionName"],
            "version_code": int(entry["versionCode"]),
            "lib": entry["extensionLib"],
            "nsfw": entry.get("contentWarning") == "CONTENT_WARNING_NSFW",
            "languages": sorted({s["language"] for s in sources}),
            "sources": [{"id": s["id"], "name": s["name"], "language": s["language"]} for s in sources],
            "apk": match.group(1) + ".apk",
            "apk_url": url,
            "apk_present": (repo / "apk" / (match.group(1) + ".apk")).is_file(),
        })
    for key in ("package", "apk"):
        values = [item[key] for item in items]
        if len(set(values)) != len(values):
            raise SystemExit(f"duplicate {key} values in index")
    return {
        "generated": now(),
        "repo_commit": git(repo, "rev-parse", "HEAD"),
        "count": len(items),
        "extensions": items,
    }


# ------------------------------------------------------------------ engine

def engine_info() -> dict:
    """Fingerprint the engine and harness sources so a regression can be traced."""
    digest = hashlib.sha256()
    files = sorted([*(ROOT / "MoeReader" / "MihonCompat").rglob("*.swift"),
                    *(ROOT / "SiteTests" / "harness").glob("*.swift")])
    for path in files:
        digest.update(path.relative_to(ROOT).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
    return {
        "fingerprint": digest.hexdigest()[:16],
        "commit": git(ROOT, "rev-parse", "--short", "HEAD"),
        "dirty": bool(git(ROOT, "status", "--porcelain", "--", "MoeReader/MihonCompat")),
        "files": len(files),
    }


# ------------------------------------------------------------------ static

_REGISTRY = None


def static_audit(apk_path: str) -> dict:
    """Runs in a worker process: compare one APK's host references with the registry."""
    global _REGISTRY
    if _REGISTRY is None:
        _REGISTRY = analyze_compat.parse_registry()
    try:
        audits = analyze_compat.audit_apk(Path(apk_path), _REGISTRY)
    except Exception as error:  # malformed archive or DEX the auditor cannot read
        return {"status": "error", "error": f"{type(error).__name__}: {error}"[:300]}
    gaps = []
    for audit in audits:
        for descriptor in audit.missing_classes:
            gaps.append(f"class {analyze_compat.descriptor_name(descriptor)}")
        for descriptor, keys in audit.missing_methods.items():
            for key in keys:
                gaps.append(f"method {analyze_compat.descriptor_name(descriptor)} {key}")
    return {
        "status": "ok",
        "dex": len(audits),
        "missing_classes": sum(len(a.missing_classes) for a in audits),
        "missing_methods": sum(len(keys) for a in audits for keys in a.missing_methods.values()),
        "gaps": sorted(gaps),
    }


# -------------------------------------------------------------------- live

def parse_harness(text: str) -> dict:
    parsed = {"result": None, "failures": [], "errors": {}, "requests": None, "sources": None}
    for line in text.splitlines():
        if (match := HARNESS_SOURCES.match(line)):
            parsed["sources"] = int(match.group(1))
        elif (match := HARNESS_STEP_FAILED.match(line)):
            parsed["errors"][match.group(1)] = match.group(2)[:300]
        elif (match := HARNESS_RESULT.match(line)):
            rest = match.group(2).strip()
            requests = HARNESS_REQUESTS.search(rest)
            if requests:
                parsed["requests"] = int(requests.group(1))
                rest = rest[:requests.start()].strip()
            parsed["result"] = match.group(1)
            parsed["failures"] = [s for s in rest.split(", ") if s] if match.group(1) == "FAIL" else []
    return parsed


def classify(parsed: dict, exit_code: int | None) -> str:
    if parsed["result"] == "OK":
        return "ok"
    if parsed["result"] == "FAIL":
        return "load-fail" if parsed["failures"] == ["load"] else "fail"
    if exit_code is None or exit_code in (124, 137):  # Python timeout, or `timeout` / SIGKILL
        return "timeout"
    return "crash" if exit_code != 0 else "error"


def live_one(package: str, apk: Path, args, overrides: dict) -> dict:
    entry = overrides.get(package, {})
    if "skip" in entry:
        return {"outcome": "skipped", "note": entry["skip"], "log": ""}
    env = dict(getattr(args, "live_env", {}))
    env.update(entry.get("env", {}))
    if args.record:
        env["HARNESS_RECORD"] = host_path(args, args.record / package)
    if args.replay:
        env["HARNESS_REPLAY"] = host_path(args, args.replay / package)
    inner = [args.harness, host_path(args, apk)]
    if args.distro:
        assignments = [f"{key}={value}" for key, value in env.items()]
        cmd = ["wsl.exe", "-d", args.distro, "--", "timeout", "-k", "10", str(args.timeout),
               "env", *assignments, *inner]
        child_env = None
    else:
        cmd = ["timeout", "-k", "10", str(args.timeout), *inner] if shutil.which("timeout") else inner
        child_env = {**os.environ, **env}
    started = time.monotonic()
    exit_code: int | None
    try:
        done = subprocess.run(cmd, capture_output=True, timeout=args.timeout + 120, env=child_env)
        text = done.stdout.decode("utf-8", "replace") + done.stderr.decode("utf-8", "replace")
        exit_code = done.returncode
    except subprocess.TimeoutExpired as expired:
        raw = (expired.stdout or b"") + (expired.stderr or b"")
        text = raw.decode("utf-8", "replace")
        exit_code = None
    parsed = parse_harness(text)
    return {
        "outcome": classify(parsed, exit_code),
        "failures": parsed["failures"],
        "errors": parsed["errors"],
        "requests": parsed["requests"],
        "sources": parsed["sources"],
        "exit": exit_code,
        "seconds": round(time.monotonic() - started, 1),
        "log": text,
    }



def preflight(args) -> None:
    if args.distro:
        cmd = ["wsl.exe", "-d", args.distro, "--", "test", "-x", args.harness]
        try:
            ok = subprocess.run(cmd, capture_output=True).returncode == 0
        except OSError as error:
            raise SystemExit(f"cannot run wsl.exe: {error}")
    else:
        ok = os.access(args.harness, os.X_OK)
    if not ok:
        raise SystemExit(f"harness not found at {args.harness}; run: extension_matrix.py build")


# --------------------------------------------------------------- commands

def select(items: list[dict], only: str | None, limit: int | None) -> list[dict]:
    if only:
        wanted = {p.strip() for p in only.split(",") if p.strip()}
        items = [item for item in items if item["package"] in wanted]
        missing = wanted - {item["package"] for item in items}
        if missing:
            raise SystemExit(f"not in index: {', '.join(sorted(missing))}")
    return items[:limit] if limit else items


def cmd_inventory(args) -> None:
    inventory = build_inventory(args.repo)
    write_json(MATRIX / "inventory.json", inventory)
    absent = [i["package"] for i in inventory["extensions"] if not i["apk_present"]]
    print(f"inventory: {inventory['count']} extensions, repo {inventory['repo_commit'][:12]}, "
          f"APK missing for {len(absent)}")


def cmd_build(args) -> None:
    script = ROOT / "SiteTests" / "harness" / "build.sh"
    if not script.is_file():
        raise SystemExit(f"missing {script}; the harness lives in the git-ignored SiteTests/ directory")
    cmd = ["wsl.exe", "-d", args.distro, "--", "bash", to_wsl(script)] if args.distro else ["bash", str(script)]
    raise SystemExit(subprocess.run(cmd).returncode)


def cmd_run(args) -> None:
    inventory = build_inventory(args.repo)
    write_json(MATRIX / "inventory.json", inventory)
    items = select(inventory["extensions"], args.only, args.limit)
    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    run_path = MATRIX / "runs" / f"{run_id}.json"
    if run_path.exists():
        raise SystemExit(f"run {run_id} already recorded; retry in a second")
    engine = engine_info()
    started = now()
    results: dict[str, dict] = {}
    for item in items:
        results[item["package"]] = {"name": item["name"], "version": item["version"],
                                    "lang": ",".join(item["languages"]), "nsfw": item["nsfw"]}
    apk_dir = args.repo / "apk"
    runnable = []
    for item in items:
        if (apk_dir / item["apk"]).is_file():
            runnable.append(item)
        else:
            if args.static:
                results[item["package"]]["static"] = {"status": "missing"}
            if args.live:
                results[item["package"]]["live"] = {"outcome": "missing"}

    if args.static:
        paths = [str(apk_dir / item["apk"]) for item in runnable]
        with cf.ProcessPoolExecutor(max_workers=args.workers) as pool:
            for item, result in zip(runnable, pool.map(static_audit, paths, chunksize=8)):
                results[item["package"]]["static"] = result
        print(f"static: {len(runnable)} audited")

    if args.live:
        preflight(args)
        if args.record:
            args.record.mkdir(parents=True, exist_ok=True)
        if args.replay:
            args.replay.mkdir(parents=True, exist_ok=True)
        overrides = load_json(args.overrides, {})
        logs = MATRIX / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        with cf.ThreadPoolExecutor(max_workers=args.live_workers) as pool:
            futures = {pool.submit(live_one, item["package"], apk_dir / item["apk"], args, overrides): item
                       for item in runnable}
            for done, future in enumerate(cf.as_completed(futures), 1):
                item = futures[future]
                result = future.result()
                (logs / f"{item['package']}.log").write_text(result.pop("log"), encoding="utf-8")
                results[item["package"]]["live"] = result
                print(f"[{done}/{len(futures)}] {item['package']} {result['outcome']} "
                      f"{','.join(result['failures'])} ({result.get('seconds', 0)}s)", flush=True)

    record = {
        "id": run_id,
        "started": started,
        "finished": now(),
        "mode": {"static": args.static, "live": args.live,
                 "record": str(args.record) if args.record else None,
                 "replay": str(args.replay) if args.replay else None,
                 "timeout": args.timeout, "only": args.only, "limit": args.limit},
        "engine": engine,
        "repo_commit": inventory["repo_commit"],
        "results": results,
    }
    write_json(run_path, record)
    update_status(run_id, engine, results)
    write_report()
    print_summary(results, run_id)


def print_summary(results: dict, run_id: str) -> None:
    live = Counter(r.get("live", {}).get("outcome", "not run") for r in results.values())
    static = Counter(r.get("static", {}).get("status", "not run") for r in results.values())
    print(f"run {run_id}: {len(results)} extensions")
    print("  live:   " + ", ".join(f"{k}={v}" for k, v in sorted(live.items(), key=lambda kv: ORDER.get(kv[0], 9))))
    print("  static: " + ", ".join(f"{k}={v}" for k, v in sorted(static.items())))


def update_status(run_id: str, engine: dict, results: dict) -> None:
    path = MATRIX / "status.json"
    status = load_json(path, {})
    for package, result in results.items():
        entry = status.setdefault(package, {})
        entry.update(name=result["name"], version=result["version"], lang=result["lang"], nsfw=result["nsfw"])
        if "static" in result:
            static = result["static"]
            entry["static"] = {"run": run_id, "status": static["status"],
                               "gaps": len(static.get("gaps", [])), "error": static.get("error")}
        if "live" in result:
            live = result["live"]
            entry["live"] = {"run": run_id, "engine": engine["fingerprint"], "outcome": live["outcome"],
                             "failures": live.get("failures", []), "errors": live.get("errors", {}),
                             "note": live.get("note")}
    write_json(path, dict(sorted(status.items())))


def write_report() -> None:
    status = load_json(MATRIX / "status.json", {})
    live_counts = Counter(e.get("live", {}).get("outcome", "not run") for e in status.values())
    static_counts = Counter(e.get("static", {}).get("status", "not run") for e in status.values())
    zero_gap = sum(1 for e in status.values() if e.get("static", {}).get("gaps") == 0)
    lines = [
        "# Extension matrix", "",
        f"Updated {now()}. {len(status)} extensions.", "",
        "| Live outcome | Count |", "| --- | ---: |",
        *[f"| {k} | {v} |" for k, v in sorted(live_counts.items(), key=lambda kv: ORDER.get(kv[0], 9))],
        "",
        f"Static: {static_counts.get('ok', 0)} audited, {zero_gap} with no host gaps.", "",
        "| Package | Name | Lang | Version | Live | Failing stages | First error | Static gaps | Run |",
        "| --- | --- | --- | --- | --- | --- | --- | ---: | --- |",
    ]

    def sort_key(item):
        package, entry = item
        outcome = entry.get("live", {}).get("outcome", "not run")
        return (ORDER.get(outcome, 9), package)

    for package, entry in sorted(status.items(), key=sort_key):
        live = entry.get("live", {})
        static = entry.get("static", {})
        first_error = next(iter(live.get("errors", {}).values()), "")[:100]
        gaps = static.get("gaps", static.get("status", "-"))
        lines.append(
            f"| {escape(package)} | {escape(entry.get('name', ''))} | {escape(entry.get('lang', ''))} "
            f"| {escape(entry.get('version', ''))} | {live.get('outcome', 'not run')} "
            f"| {escape(', '.join(live.get('failures', [])))} | {escape(first_error)} "
            f"| {gaps} | {live.get('run', static.get('run', '-'))} |"
        )
    (MATRIX / "REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def cmd_report(args) -> None:
    write_report()
    print(f"wrote {MATRIX / 'REPORT.md'}")


def list_runs() -> list[str]:
    return sorted(p.stem for p in (MATRIX / "runs").glob("*.json"))


def load_run(run_id: str) -> dict:
    path = MATRIX / "runs" / f"{run_id}.json"
    if not path.exists():
        raise SystemExit(f"no such run: {run_id}")
    return load_json(path, {})


def compare(before: dict | None, after: dict | None) -> tuple[str, list[str]]:
    """Classify one extension between two runs. Returns (kind, detail)."""
    live_a = (before or {}).get("live", {})
    live_b = (after or {}).get("live", {})
    out_a, out_b = live_a.get("outcome"), live_b.get("outcome")
    if out_a in RANK and out_b in RANK and RANK[out_b] != RANK[out_a]:
        kind = "REGRESSED" if RANK[out_b] > RANK[out_a] else "FIXED"
    elif out_a != out_b and out_a and out_b:
        kind = "CHANGED"
    elif out_a in RANK and set(live_a.get("failures", [])) != set(live_b.get("failures", [])):
        kind = "CHANGED"
    else:
        kind = ""
    detail = [f"{out_a or '-'} -> {out_b or '-'}"]
    if kind and live_b.get("failures"):
        detail.append(", ".join(live_b["failures"]))
    return kind, detail


def cmd_diff(args) -> None:
    runs = list_runs()
    if args.a and args.b:
        a_id, b_id = args.a, args.b
    elif len(runs) >= 2:
        a_id, b_id = runs[-2], runs[-1]
    else:
        raise SystemExit("need two runs to diff")
    a, b = load_run(a_id), load_run(b_id)
    ra, rb = a["results"], b["results"]
    sections: dict[str, list[str]] = {k: [] for k in ("REGRESSED", "FIXED", "CHANGED", "NEW", "REMOVED", "STATIC")}
    for package in sorted(set(ra) | set(rb)):
        before, after = ra.get(package), rb.get(package)
        if before is None:
            sections["NEW"].append(f"| {escape(package)} | {escape(after['name'])} | {live_summary(after)} |")
            continue
        if after is None:
            sections["REMOVED"].append(f"| {escape(package)} | {escape(before['name'])} |")
            continue
        kind, detail = compare(before, after)
        if kind:
            sections[kind].append(f"| {escape(package)} | {escape(after['name'])} | {escape(detail[0])} "
                                  f"| {escape(detail[1] if len(detail) > 1 else '')} |")
        gaps_a = set(before.get("static", {}).get("gaps", []))
        gaps_b = set(after.get("static", {}).get("gaps", []))
        if gaps_a != gaps_b:
            sections["STATIC"].append(f"| {escape(package)} | {escape(after['name'])} "
                                      f"| +{len(gaps_b - gaps_a)} | -{len(gaps_a - gaps_b)} |")

    headers = {
        "REGRESSED": ("| Package | Name | Live | Failing stages |", "| --- | --- | --- | --- |"),
        "FIXED": ("| Package | Name | Live | Failing stages |", "| --- | --- | --- | --- |"),
        "CHANGED": ("| Package | Name | Live | Failing stages |", "| --- | --- | --- | --- |"),
        "NEW": ("| Package | Name | Live |", "| --- | --- | --- |"),
        "REMOVED": ("| Package | Name |", "| --- | --- |"),
        "STATIC": ("| Package | Name | Gaps added | Gaps removed |", "| --- | --- | ---: | ---: |"),
    }
    lines = [
        "# Extension matrix changes", "",
        f"From run `{a_id}` (engine {a['engine']['fingerprint']}, commit {a['engine']['commit']}) "
        f"to run `{b_id}` (engine {b['engine']['fingerprint']}, commit {b['engine']['commit']}).",
        "Engine changed." if a["engine"]["fingerprint"] != b["engine"]["fingerprint"] else "Engine unchanged.",
        "",
    ]
    for name in ("REGRESSED", "FIXED", "CHANGED", "NEW", "REMOVED", "STATIC"):
        rows = sections[name]
        lines += [f"## {name.title()} ({len(rows)})", ""]
        if rows:
            lines += list(headers[name]) + rows
        else:
            lines.append("None.")
        lines.append("")
    text = "\n".join(lines)
    (MATRIX / "CHANGES.md").write_text(text, encoding="utf-8")
    print(text)


def live_summary(result: dict) -> str:
    return result.get("live", {}).get("outcome", "not run")


def cmd_history(args) -> None:
    for run_id in list_runs():
        run = load_run(run_id)
        result = run["results"].get(args.package)
        if result is None:
            continue
        live = result.get("live", {})
        static = result.get("static", {})
        print(f"{run_id}  engine={run['engine']['fingerprint']}  version={result['version']}  "
              f"live={live.get('outcome', '-')} {','.join(live.get('failures', []))}  "
              f"static_gaps={len(static.get('gaps', []))}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=DEFAULT_REPO, help="extension repository checkout")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("inventory", help="write inventory.json from the repository index")

    build = sub.add_parser("build", help="build the Linux harness (SiteTests/harness/build.sh)")
    build.add_argument("--distro", default=DEFAULT_DISTRO, help="WSL distro; empty runs build.sh natively")

    run = sub.add_parser("run", help="audit APKs and record a run")
    run.add_argument("--live", action="store_true", help="run the Linux harness on each APK")
    run.add_argument("--no-static", dest="static", action="store_false", help="skip the static audit")
    run.add_argument("--only", help="comma-separated package names")
    run.add_argument("--limit", type=int, help="first N extensions after --only")
    run.add_argument("--workers", type=int, default=min(8, os.cpu_count() or 4), help="static audit processes")
    run.add_argument("--live-workers", type=int, default=4, help="concurrent harness runs")
    run.add_argument("--live-env", action="append", default=[], metavar="KEY=VALUE",
                     help="environment applied to every live run (repeatable; per-package overrides win)")
    run.add_argument("--timeout", type=int, default=300, help="seconds per live run")
    run.add_argument("--distro", default=DEFAULT_DISTRO, help="WSL distro; empty runs the harness natively")
    run.add_argument("--harness", default=DEFAULT_HARNESS, help="harness binary path on the Linux side")
    run.add_argument("--overrides", type=Path, default=MATRIX / "overrides.json",
                     help="per-package {skip|env} overrides")
    fixtures = run.add_mutually_exclusive_group()
    fixtures.add_argument("--record", type=Path, help="record harness responses under DIR/<pkg>")
    fixtures.add_argument("--replay", type=Path, help="replay recorded responses from DIR/<pkg>")

    diff = sub.add_parser("diff", help="regressions and fixes between two runs")
    diff.add_argument("a", nargs="?")
    diff.add_argument("b", nargs="?")

    history = sub.add_parser("history", help="one extension across all runs")
    history.add_argument("package")

    sub.add_parser("report", help="regenerate REPORT.md from status.json")

    args = parser.parse_args(argv)
    args.repo = args.repo.resolve()
    if args.command == "run":
        args.live = bool(args.live)
        args.static = bool(args.static)
        live_env = {}
        for item in args.live_env:
            key, sep, value = item.partition("=")
            if not sep or not key:
                parser.error(f"--live-env expects KEY=VALUE, got {item!r}")
            live_env[key] = value
        args.live_env = live_env
        if args.record:
            args.record = args.record.resolve()
        if args.replay:
            args.replay = args.replay.resolve()
        if not args.live and not args.static:
            parser.error("nothing to do: pass --live or leave static enabled")
    handlers = {
        "inventory": cmd_inventory,
        "build": cmd_build,
        "run": cmd_run,
        "diff": cmd_diff,
        "history": cmd_history,
        "report": cmd_report,
    }
    handlers[args.command](args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
