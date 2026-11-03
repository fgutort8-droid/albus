#!/usr/bin/env python3
"""Exercise only a local Supabase Auth stack; never print sessions or API keys."""
import argparse
import base64
import hashlib
import hmac
import json
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tomllib
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

BUNDLE_ID = "com.felipegutierrez.albus"


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def forged_apple_token():
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).rstrip(b"=")
    now = int(time.time())
    # A valid JWT structure and a fresh, throwaway HMAC key. Apple never signs
    # with this key/algorithm, so accepting this token would be a regression.
    unsigned = b".".join((encode({"alg": "HS256", "typ": "JWT", "kid": "local-test-only"}),
                          encode({"iss": "https://appleid.apple.com", "aud": BUNDLE_ID,
                                  "sub": str(uuid.uuid4()), "iat": now, "exp": now + 300})))
    signature = hmac.new(secrets.token_bytes(32), unsigned, hashlib.sha256).digest()
    return (unsigned + b"." + base64.urlsafe_b64encode(signature).rstrip(b"=")).decode()


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
    if not api:
        # CLI 2.98.2 omits API_URL when PostgREST is excluded, even with Kong
        # and Auth running. Use its local DB host and the configured API port.
        db_host = urllib.parse.urlsplit(values.get("DB_URL", "")).hostname
        check(db_host in ("localhost", "127.0.0.1", "::1"), "Local status has no API URL or local DB host")
        settings = tomllib.loads((Path(args.workdir) / "supabase/config.toml").read_text())
        host = "[::1]" if db_host == "::1" else db_host
        api = f"http://{host}:{settings['api']['port']}"
    url = urllib.parse.urlsplit(api)
    check(url.scheme == "http" and url.hostname in ("localhost", "127.0.0.1", "::1"),
          "Refusing a non-local Auth endpoint")
    key = values.get("PUBLISHABLE_KEY") or values.get("ANON_KEY")
    admin_key = values.get("SERVICE_ROLE_KEY") or values.get("SECRET_KEY")
    check(key and admin_key, "Local publishable and admin keys are required")
    # Do not follow redirects with a local admin credential.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = urllib.request.build_opener(NoRedirect)

    def call(path, body=None, *, admin=False, method="POST"):
        credential = admin_key if admin else key
        headers = {"apikey": credential, "Content-Type": "application/json",
                   "X-Supabase-Api-Version": "2024-01-01"}
        if admin:
            headers["Authorization"] = "Bearer " + credential
        req = urllib.request.Request(api + "/auth/v1/" + path,
                                     data=None if body is None else json.dumps(body).encode(),
                                     headers=headers, method=method)
        try:
            with opener.open(req, timeout=15) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            try:
                payload = json.loads(error.read())
            except (ValueError, UnicodeDecodeError):
                payload = {}
            return error.code, payload

    fixture_email = "apple-only-existing-" + uuid.uuid4().hex + "@example.invalid"
    new_email = "apple-only-new-" + uuid.uuid4().hex + "@example.invalid"
    created = []
    leftover = []

    def remember(body):
        # Queue any account a response carries, so even one that should never
        # have been made is removed before a failed check is reported.
        user = body.get("user") if isinstance(body.get("user"), dict) else body
        identifier = user.get("id") if isinstance(user, dict) else None
        if isinstance(identifier, str) and identifier not in created:
            created.append(identifier)

    try:
        status, body = call("signup", {"email": new_email, "password": secrets.token_urlsafe(24)})
        remember(body)
        check(status == 400 and body.get("code") == "email_provider_disabled", "Password signup was not refused by the email-provider setting")
        print("PASS: password signup refused (400 email_provider_disabled)")
        status, body = call("otp", {"email": new_email, "create_user": True})
        check(status == 422 and body.get("code") == "email_provider_disabled", "New-address OTP was not refused by the email-provider setting")
        page = 1
        while True:
            status, listing = call(f"admin/users?page={page}&per_page=1000", admin=True, method="GET")
            check(status == 200, "Cannot inspect local users after OTP refusal")
            users = listing.get("users", [])
            for user in users:
                if user.get("email") == new_email:
                    remember(user)
            check(not any(user.get("email") == new_email for user in users), "OTP created a user")
            if len(users) < 1000:
                break
            page += 1
        print("PASS: new-address OTP refused (422 email_provider_disabled); no user created")
        status, user = call("admin/users", {"email": fixture_email, "email_confirm": True}, admin=True)
        remember(user)
        check(status in (200, 201) and user.get("id"), "Cannot create local existing-user fixture")
        for create_user in (False, True):
            status, body = call("otp", {"email": fixture_email, "create_user": create_user})
            check(status == 422 and body.get("code") == "email_provider_disabled", "Existing-user OTP remained enabled")
        print("PASS: existing-address OTP refused for create_user=false and true (422 email_provider_disabled)")
        status, body = call("token?grant_type=id_token", {"provider": "apple", "id_token": forged_apple_token()})
        message = str(body.get("msg", body.get("message", body.get("error_description", "")))).lower()
        check(status == 400 and (body.get("code") in ("validation_failed", "bad_jwt") or
                                (body.get("error") == "invalid request" and body.get("error_description") == "Bad ID token"))
              and any(text in message for text in ("id token", "id_token", "jwt", "signature"))
              and not any(text in message for text in ("not enabled", "provider is disabled", "detect issuer")),
              "Forged Apple token did not reach token verification")
        print("PASS: Apple provider enabled; forged ID token refused by token verification")
        status, body = call("signup", {})
        remember(body)
        check(status in (200, 201) and body.get("user", {}).get("is_anonymous") is True,
              "Anonymous signup failed on the local compatibility stack")
        print("PASS: local anonymous signup works; production switches it off after testers update")
    finally:
        # Try every removal before reporting any, so one failure strands no others.
        for identifier in created:
            try:
                status, _ = call("admin/users/" + identifier, admin=True, method="DELETE")
            except OSError:
                status = None
            if status != 200:
                leftover.append(identifier)
        if leftover:
            # Said here as well, because a failed check may already be on its way out.
            print(f"FAIL: {len(leftover)} local test account(s) could not be removed", file=sys.stderr)
    check(not leftover, "Could not remove every local test account")
    print("PASS: 5 checks; local test accounts removed")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, subprocess.SubprocessError):
        # Upstream exceptions can include requests or credentials. Fixed output only.
        print("FAIL: Apple-only sign-in checks did not complete; inspect the local stack and configuration", file=sys.stderr)
        sys.exit(1)
