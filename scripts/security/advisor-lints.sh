#!/usr/bin/env bash
# Local-only Security Advisor gate. Splinter stays outside this public repository.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
exec python3 - "$ROOT" "$@" <<'PYTHON'
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.request

ROOT = Path(sys.argv[1])
COMMIT = "fccca4b1c4d8b48b8ccd69bd6b30e84adcb92975"
SHA256 = "d8d558baad3e03832e521c527907fa50a9a172fabd899dd0f5c2504a5a0e9349"
URL = f"https://raw.githubusercontent.com/supabase/splinter/{COMMIT}/splinter.sql"


def main():
    parser = argparse.ArgumentParser(description="Run checksum-pinned Splinter against local Docker; exit 1 for blocked findings, 2 for execution errors.")
    parser.add_argument("--fixture-sql", type=Path,
                        help="Test-only SQL executed in the same rolled-back transaction as the lints")
    args = parser.parse_args(sys.argv[2:])
    project = re.search(r'^project_id = "([^"\n]+)"',
                        (ROOT / "supabase/config.toml").read_text(), re.M)
    if not project:
        raise ValueError("Missing project_id in supabase/config.toml")
    container = os.environ.get("ALBUS_DB_CONTAINER", "supabase_db_" + project[1])
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", container):
        raise ValueError("ALBUS_DB_CONTAINER must be a local Docker container name")

    entries = json.loads((ROOT / "scripts/security/advisor-allowlist.json").read_text())
    if not isinstance(entries, list):
        raise ValueError("Allowlist must be an array")
    allowlist = {}
    for entry in entries:
        if (not isinstance(entry, dict) or set(entry) != {"name", "object", "reason"}
                or not isinstance(entry["name"], str) or not entry["name"]
                or not isinstance(entry["object"], dict)
                or not all(isinstance(entry["object"].get(k), str) and entry["object"][k]
                           for k in ("schema", "name"))
                or not isinstance(entry["reason"], str) or not entry["reason"].strip()):
            raise ValueError("Each allowlist entry needs a lint name, exact object metadata (including schema/name), and a reason")
        key = (entry["name"], json.dumps(entry["object"], sort_keys=True))
        if key in allowlist:
            raise ValueError("Duplicate allowlist entry")
        allowlist[key] = entry["reason"]

    with urllib.request.urlopen(URL, timeout=30) as response:
        source = response.read()
    if hashlib.sha256(source).hexdigest() != SHA256:
        raise ValueError("Splinter SHA-256 mismatch; no SQL executed")
    sql = source.decode("utf-8")
    # This pinned file has a SET LOCAL and a DO preamble, followed by one
    # UNION query. Preserve every lint and the preamble; only wrap the query
    # to serialize its result, without parsing human-readable psql output.
    preamble, separator, query = sql.partition("\n(\n")
    if not separator or not preamble.rstrip().endswith("end $$;"):
        raise ValueError("Unexpected pinned Splinter query layout")
    query = "(\n" + query.rstrip().removesuffix(";")
    fixture = args.fixture_sql.read_text() if args.fixture_sql else ""
    script = ("BEGIN;\nSET LOCAL statement_timeout = '60s';\n"
              "\\o /dev/null\n" + fixture + "\n" + preamble + "\n\\o\n"
              "SELECT pg_catalog.row_to_json(advisor) FROM (\n" + query
              + "\n) AS advisor;\nROLLBACK;\n")
    result = subprocess.run(
        ["docker", "exec", "-i", container, "psql", "-U", "postgres", "-d", "postgres",
         "-X", "-qAt", "-v", "ON_ERROR_STOP=1"],
        input=script, text=True, capture_output=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f"Splinter SQL failed (exit {result.returncode}): {result.stderr.strip()}")
    if result.stderr.strip():
        print(result.stderr.strip(), file=sys.stderr)
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    blocked = allowed = informational = 0
    for row in sorted(rows, key=lambda r: (r["name"], json.dumps(r["metadata"], sort_keys=True))):
        if (not isinstance(row["metadata"], dict) or not isinstance(row["categories"], list)
                or row["level"] not in ("ERROR", "WARN", "INFO")):
            raise ValueError("Unexpected Splinter result shape")
        security = "SECURITY" in row["categories"] and row["level"] in ("ERROR", "WARN")
        reason = allowlist.get((row["name"], json.dumps(row["metadata"], sort_keys=True)))
        if security and not reason:
            disposition = "BLOCK"
            blocked += 1
        elif security:
            disposition = "ALLOW"
            allowed += 1
        else:
            disposition = "INFO"
            informational += 1
        print(f'{disposition} {row["level"]} {",".join(row["categories"])} {row["name"]} '
              f'object={json.dumps(row["metadata"], sort_keys=True)} detail={row["detail"]}')
        if security and reason:
            print("  Reason: " + reason)
    print(f"Advisor: {len(rows)} findings; {blocked} blocked; {allowed} allowlisted; "
          f"{informational} non-blocking; 29 lints executed together; 0 skipped.")
    return 1 if blocked else 0


try:
    sys.exit(main())
except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
    print("ERROR: " + str(error), file=sys.stderr)
    sys.exit(2)
PYTHON
