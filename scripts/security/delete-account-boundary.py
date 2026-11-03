#!/usr/bin/env python3
"""Delete accounts through the real local delete-account function.

The function's unit tests replace requireUser and the database client. This
sends real Auth tokens through the local gateway, edge runtime and database:
a student's own token deletes that account and no other, and a missing,
forged or spent token deletes nothing. It exercises only a local Supabase
stack and never prints sessions or API keys.
"""
import argparse
import json
import shlex
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", default=".", help="Local Supabase project directory")
    args = parser.parse_args()
    result = subprocess.run(["supabase", "status", "--workdir", args.workdir, "-o", "env"],
                            text=True, capture_output=True, check=False)
    check(result.returncode == 0, "Cannot read local Supabase status")
    values = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            parsed = shlex.split(value)
            if parsed:
                values[key] = parsed[0]
    api = values.get("API_URL", "").rstrip("/")
    url = urllib.parse.urlsplit(api)
    check(url.scheme == "http" and url.hostname in ("localhost", "127.0.0.1", "::1"),
          "Refusing a non-local API endpoint")
    key = values.get("PUBLISHABLE_KEY") or values.get("ANON_KEY")
    admin_key = values.get("SERVICE_ROLE_KEY") or values.get("SECRET_KEY")
    check(key and admin_key, "Local publishable and admin keys are required")

    # Do not follow redirects with a local credential.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = urllib.request.build_opener(NoRedirect)

    def call(path, body=None, *, token=None, admin=False, method="POST", timeout=15):
        headers = {"apikey": admin_key if admin else key, "Content-Type": "application/json",
                   "X-Supabase-Api-Version": "2024-01-01"}
        if admin:
            headers["Authorization"] = "Bearer " + admin_key
        elif token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(api + path,
                                     data=None if body is None else json.dumps(body).encode(),
                                     headers=headers, method=method)
        try:
            with opener.open(req, timeout=timeout) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            try:
                payload = json.loads(error.read())
            except (ValueError, UnicodeDecodeError):
                payload = {}
            return error.code, payload

    def exists(identifier):
        status, _ = call("/auth/v1/admin/users/" + identifier, admin=True, method="GET")
        check(status in (200, 404), "Cannot inspect local users")
        return status == 200

    def delete_account(token=None, timeout=15):
        return call("/functions/v1/delete-account", {}, token=token, timeout=timeout)

    created = []
    leftover = []
    try:
        sessions = []
        for _ in range(2):
            status, body = call("/auth/v1/signup", {})
            user = body.get("user") if isinstance(body.get("user"), dict) else {}
            if isinstance(user.get("id"), str):
                created.append(user["id"])
            check(status in (200, 201) and body.get("access_token") and user.get("id"),
                  "Cannot make a local test account")
            sessions.append((user["id"], body["access_token"]))
        (first, first_token), (second, _) = sessions

        # The first request also warms the edge runtime, which loads the
        # function's dependencies, so it gets longer.
        status, _ = delete_account(timeout=90)
        check(status == 401 and exists(first) and exists(second),
              "A request without a token was not refused, or deleted an account")
        print("PASS: no token is refused (401); nothing deleted")

        header, payload, signature = first_token.split(".")
        forged = ".".join((header, payload, ("A" if signature[0] != "A" else "B") + signature[1:]))
        status, _ = delete_account(forged)
        check(status == 401 and exists(first) and exists(second),
              "A forged token was not refused, or deleted an account")
        print("PASS: a forged token is refused (401); nothing deleted")

        status, body = delete_account(first_token, timeout=30)
        check(status == 200 and body == {"deleted": True, "apple_revoked": False},
              "The account's own token did not delete it")
        check(not exists(first), "The account still exists after deletion")
        check(exists(second), "Deleting one account removed another")
        print("PASS: a student's own token deletes exactly that account; the other remains")

        status, _ = delete_account(first_token)
        check(status == 401 and exists(second),
              "A deleted account's token was not refused, or deleted another account")
        print("PASS: a deleted account's token is refused (401); the other account remains")
    finally:
        # Try every removal before reporting any, so one failure strands no others.
        for identifier in created:
            try:
                status, _ = call("/auth/v1/admin/users/" + identifier, admin=True, method="DELETE")
            except OSError:
                status = None
            if status not in (200, 404):
                leftover.append(identifier)
        if leftover:
            # Said here as well, because a failed check may already be on its way out.
            print(f"FAIL: {len(leftover)} local test account(s) could not be removed", file=sys.stderr)
    check(not leftover, "Could not remove every local test account")
    print("PASS: 4 checks; local test accounts removed")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, subprocess.SubprocessError):
        # Upstream exceptions can include requests or credentials. Fixed output only.
        print("FAIL: delete-account boundary checks did not complete; inspect the local stack", file=sys.stderr)
        sys.exit(1)
