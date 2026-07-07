#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

"""Rotate the OVH Object Storage S3 credentials for the GitOps state-backend
user and upload the new pair straight into GitHub Actions environment secrets.

The secret access key NEVER passes through stdout, a log line, a command-line
argument, or a temp file: it is created via the OVH API, handed to `aws` for
verification through the subprocess environment, and piped into `gh secret set`
over stdin. The only thing printed is a non-sensitive summary (masked access
key id, secret names, counts).

Flow (create -> verify -> push -> revoke, so a broken key is never pushed and
working old credentials are never revoked before the new ones are proven):

  1. Locate the OVH cloud project and the GitOps user (by id or description).
  2. Create a fresh S3 credential pair for that user.
  3. Verify it against the state bucket: read, conditional-write lock, delete.
  4. Push AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY to the GitHub environment.
  5. Revoke the previously existing credentials (rotation) unless --keep-old.
     On any failure after step 2, the just-created key is rolled back and the
     old credentials are left intact.

Requirements:
  - OVH credentials with /cloud access (a root/cloud-capable key). A key in
    ~/.ovh.conf is loaded explicitly so direnv-exported OVH_* env vars (often
    scoped to /dedicated only) do not shadow it; pass --use-env to override.
  - `gh` authenticated with access to the repository's Actions secrets.
  - `aws` CLI for verification (or pass --skip-verify).

Usage:
  scripts/rotate-s3-credentials.py                 # auto-detect everything
  scripts/rotate-s3-credentials.py --dry-run       # show the plan, change nothing
  scripts/rotate-s3-credentials.py --keep-old      # add a key without revoking
  scripts/rotate-s3-credentials.py --revoke-first  # at the OVH per-user cred limit

Exit codes: 0 success; 1 error (nothing pushed / old credentials preserved).
"""

import argparse
import configparser
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

try:
    import ovh
except ImportError:
    print("ERROR: python-ovh is required (pip install -r requirements.txt).", file=sys.stderr)
    sys.exit(1)

ACCESS_SECRET_NAME = "AWS_ACCESS_KEY_ID"
SECRET_SECRET_NAME = "AWS_SECRET_ACCESS_KEY"
DEFAULT_USER_DESCRIPTION = "gitops-state-backend"
DEFAULT_ENVIRONMENT = "production"


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def mask(value: str) -> str:
    """Show only the last 4 characters of an identifier (never a secret)."""
    return f"...{value[-4:]}" if len(value) > 4 else "...."


def scrub(text: str, *secrets: str) -> str:
    """Remove any secret substrings from captured output before it is printed."""
    for s in secrets:
        if s:
            text = text.replace(s, "[redacted]")
    return text


# --- Configuration -----------------------------------------------------------

def parse_backend_tfvars(path: Path) -> dict:
    """Extract bucket, region, and S3 endpoint from backend.tfvars."""
    if not path.is_file():
        return {}
    text = path.read_text()
    out = {}
    for key in ("bucket", "region"):
        m = re.search(rf'{key}\s*=\s*"([^"]+)"', text)
        if m:
            out[key] = m.group(1)
    m = re.search(r'https://[^"\s]+', text)
    if m:
        out["endpoint"] = m.group(0).rstrip("/") + "/"
    return out


def make_ovh_client(use_env: bool) -> "ovh.Client":
    """Build an OVH client.

    By default, load credentials explicitly from ~/.ovh.conf when present, so
    that direnv-exported OVH_* env vars (typically scoped to /dedicated) do not
    shadow a cloud-capable key. --use-env falls back to python-ovh's own
    resolution (env vars, then config files).
    """
    conf = Path.home() / ".ovh.conf"
    if not use_env and conf.is_file():
        cp = configparser.ConfigParser()
        cp.read(conf)
        endpoint = cp.get("default", "endpoint", fallback="ovh-eu")
        if not cp.has_section(endpoint):
            raise SystemExit(
                f"ERROR: ~/.ovh.conf has no [{endpoint}] section for its endpoint."
            )
        return ovh.Client(
            endpoint=endpoint,
            application_key=cp.get(endpoint, "application_key"),
            application_secret=cp.get(endpoint, "application_secret"),
            consumer_key=cp.get(endpoint, "consumer_key"),
        )
    return ovh.Client()


# --- OVH operations ----------------------------------------------------------

# OVH can intermittently reject a request pre-auth on clock skew vs. its edge
# nodes ("Invalid time"/"please retry"). Such rejections happen BEFORE
# execution, so retrying is safe even for the credential-creating POST —
# nothing was created. Retry only these known-transient rejections.
# (Note: a persistent "Invalid signature" usually means a malformed request,
# not skew — it is not retried into oblivion because the retry cap is small.)
_TRANSIENT = ("invalid time", "please retry", "try again", "invalid signature")


def ovh_call(fn, *args, retries: int = 4, **kwargs):
    for attempt in range(1, retries + 1):
        try:
            return fn(*args, **kwargs)
        except ovh.exceptions.APIError as e:
            if attempt < retries and any(t in str(e).lower() for t in _TRANSIENT):
                time.sleep(0.5 * attempt)
                continue
            raise


def find_project(client: "ovh.Client", project: str | None) -> str:
    if project:
        return project
    projects = ovh_call(client.get, "/cloud/project")
    if len(projects) == 1:
        return projects[0]
    raise SystemExit(
        f"ERROR: {len(projects)} cloud projects found; pass --project explicitly."
    )


def find_user(client: "ovh.Client", sn: str, user_id: str | None, description: str) -> str:
    if user_id:
        return user_id
    # The list endpoint returns full user objects (id, description, ...), so
    # match on description directly — no per-user GET needed.
    for user in ovh_call(client.get, f"/cloud/project/{sn}/user"):
        if user.get("description") == description:
            return str(user["id"])
    raise SystemExit(
        f"ERROR: no cloud user with description {description!r}; pass --user-id."
    )


def list_access_keys(client: "ovh.Client", sn: str, uid: str) -> list[str]:
    creds = ovh_call(client.get, f"/cloud/project/{sn}/user/{uid}/s3Credentials")
    return [c["access"] for c in creds]


def create_credentials(client: "ovh.Client", sn: str, uid: str) -> tuple[str, str]:
    cred = ovh_call(client.post, f"/cloud/project/{sn}/user/{uid}/s3Credentials")
    return cred["access"], cred["secret"]


def revoke_credentials(client: "ovh.Client", sn: str, uid: str, access_keys: list[str]) -> None:
    for access in access_keys:
        ovh_call(client.delete, f"/cloud/project/{sn}/user/{uid}/s3Credentials/{access}")


# --- Verification (aws CLI; secret only via subprocess env) -------------------

def verify_credentials(access: str, secret: str, bucket: str, region: str, endpoint: str) -> None:
    """Prove the new credentials can read, write, and lock the state bucket.

    Raises RuntimeError on failure. All captured output is scrubbed of the
    credentials before it can appear in an error message.
    """
    env = {
        **os.environ,
        "AWS_ACCESS_KEY_ID": access,
        "AWS_SECRET_ACCESS_KEY": secret,
        "AWS_EC2_METADATA_DISABLED": "true",
    }
    base = ["--endpoint-url", endpoint, "--region", region]

    def run(args: list[str]) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["aws", *args, *base], env=env, capture_output=True, text=True, timeout=60
        )

    # 1. read
    r = run(["s3api", "list-objects-v2", "--bucket", bucket, "--max-items", "1"])
    if r.returncode != 0:
        raise RuntimeError("read check failed: " + scrub(r.stderr.strip(), access, secret))

    # 2. conditional-write lock (the use_lockfile mechanism) + 3. cleanup
    probe_key = f"rotation-probe-{os.getpid()}.lock"
    with tempfile.NamedTemporaryFile("w", suffix=".probe") as body:
        body.write("rotation probe\n")
        body.flush()
        w = run([
            "s3api", "put-object", "--bucket", bucket, "--key", probe_key,
            "--if-none-match", "*", "--body", body.name,
        ])
    if w.returncode != 0:
        raise RuntimeError("write/lock check failed: " + scrub(w.stderr.strip(), access, secret))
    run(["s3", "rm", f"s3://{bucket}/{probe_key}"])  # best-effort cleanup


# --- GitHub operations -------------------------------------------------------

def gh_detect_repo() -> str:
    r = subprocess.run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise SystemExit("ERROR: could not detect repo; pass --repo owner/name.")
    return r.stdout.strip()


def gh_set_secret(name: str, value: str, environment: str, repo: str) -> None:
    """Set a GitHub Actions environment secret, reading the value from stdin."""
    r = subprocess.run(
        ["gh", "secret", "set", name, "--env", environment, "--repo", repo],
        input=value, text=True, capture_output=True,
    )
    if r.returncode != 0:
        # gh does not echo the secret value; stderr is safe to surface.
        raise RuntimeError(f"gh secret set {name} failed: {r.stderr.strip()}")


def gh_confirm_secrets(names: list[str], environment: str, repo: str) -> None:
    r = subprocess.run(
        ["gh", "secret", "list", "--env", environment, "--repo", repo, "--json", "name"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return  # non-fatal confirmation
    present = {n.strip('"') for n in re.findall(r'"name":\s*"([^"]+)"', r.stdout)}
    missing = [n for n in names if n not in present]
    if missing:
        raise RuntimeError(f"secrets not visible after push: {', '.join(missing)}")


# --- Main --------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("--project", help="OVH cloud project id (auto-detected if only one)")
    ap.add_argument("--user-id", help="OVH cloud user id (else found by --description)")
    ap.add_argument("--description", default=DEFAULT_USER_DESCRIPTION,
                    help=f"OVH user description to match (default: {DEFAULT_USER_DESCRIPTION})")
    ap.add_argument("--repo", help="GitHub owner/name (auto-detected via gh)")
    ap.add_argument("--environment", default=DEFAULT_ENVIRONMENT,
                    help=f"GitHub environment (default: {DEFAULT_ENVIRONMENT})")
    ap.add_argument("--backend-tfvars", default="backend.tfvars",
                    help="Path to backend.tfvars for bucket/region/endpoint (verification)")
    ap.add_argument("--bucket", help="Override state bucket name")
    ap.add_argument("--region", help="Override bucket region")
    ap.add_argument("--endpoint", help="Override S3 endpoint URL")
    ap.add_argument("--keep-old", action="store_true",
                    help="Add the new credential without revoking existing ones")
    ap.add_argument("--revoke-first", action="store_true",
                    help="Revoke existing credentials BEFORE creating the new one "
                         "(use only when at the OVH per-user credential limit)")
    ap.add_argument("--skip-verify", action="store_true",
                    help="Do not verify the new credentials against the bucket (needs no aws CLI)")
    ap.add_argument("--use-env", action="store_true",
                    help="Resolve OVH credentials via env vars instead of ~/.ovh.conf")
    ap.add_argument("--dry-run", action="store_true", help="Show the plan and change nothing")
    args = ap.parse_args()

    backend = parse_backend_tfvars(Path(args.backend_tfvars))
    bucket = args.bucket or backend.get("bucket")
    region = args.region or backend.get("region")
    endpoint = args.endpoint or backend.get("endpoint")
    if not args.skip_verify and not all((bucket, region, endpoint)):
        eprint("ERROR: bucket/region/endpoint unresolved; set --backend-tfvars or "
               "--bucket/--region/--endpoint, or pass --skip-verify.")
        return 1

    client = make_ovh_client(args.use_env)
    try:
        sn = find_project(client, args.project)
        uid = find_user(client, sn, args.user_id, args.description)
    except ovh.exceptions.APIError as e:
        eprint(f"ERROR: OVH API call failed (need /cloud access): {e}")
        eprint("Hint: use a cloud-capable key in ~/.ovh.conf; direnv OVH_* vars scoped "
               "to /dedicated will shadow it unless you avoid --use-env.")
        return 1

    repo = args.repo or gh_detect_repo()
    old_keys = list_access_keys(client, sn, uid)

    print("Plan:")
    print(f"  OVH project:   {sn}")
    print(f"  OVH user:      {uid} ({args.description})")
    print(f"  GitHub repo:   {repo}  (environment: {args.environment})")
    print(f"  Secrets:       {ACCESS_SECRET_NAME}, {SECRET_SECRET_NAME}")
    print(f"  Existing keys: {len(old_keys)}"
          + (f" ({', '.join(mask(k) for k in old_keys)})" if old_keys else ""))
    print(f"  Verify bucket: {bucket if not args.skip_verify else '(skipped)'}")
    print(f"  Old keys:      {'kept' if args.keep_old else 'revoked after success'}")
    if args.dry_run:
        print("\nDry run — no changes made.")
        return 0

    if args.revoke_first and old_keys and not args.keep_old:
        print(f"Revoking {len(old_keys)} existing credential(s) before creation (--revoke-first)...")
        revoke_credentials(client, sn, uid, old_keys)
        old_keys = []

    print("Creating new S3 credentials...")
    new_access, new_secret = create_credentials(client, sn, uid)

    try:
        if not args.skip_verify:
            print("Verifying new credentials (read + conditional-write lock)...")
            verify_credentials(new_access, new_secret, bucket, region, endpoint)
        print(f"Pushing {ACCESS_SECRET_NAME} and {SECRET_SECRET_NAME} to GitHub...")
        gh_set_secret(ACCESS_SECRET_NAME, new_access, args.environment, repo)
        gh_set_secret(SECRET_SECRET_NAME, new_secret, args.environment, repo)
        gh_confirm_secrets([ACCESS_SECRET_NAME, SECRET_SECRET_NAME], args.environment, repo)
    except Exception as e:  # noqa: BLE001 — roll back the unproven key on any failure
        eprint(f"ERROR: {e}")
        eprint("Rolling back the newly created credential; old credentials are untouched.")
        try:
            revoke_credentials(client, sn, uid, [new_access])
        except Exception as re:  # noqa: BLE001
            eprint(f"WARNING: rollback failed — delete access {mask(new_access)} manually: {re}")
        return 1
    finally:
        del new_secret  # drop the secret reference as soon as possible

    revoked = 0
    if not args.keep_old and old_keys:
        print(f"Revoking {len(old_keys)} old credential(s)...")
        revoke_credentials(client, sn, uid, old_keys)
        revoked = len(old_keys)

    print("\n✅ Rotation complete")
    print(f"   OVH user:       {uid} ({args.description})")
    print(f"   New access key: {mask(new_access)}  (secret pushed, never displayed)")
    print(f"   GitHub secrets: {ACCESS_SECRET_NAME}, {SECRET_SECRET_NAME} "
          f"→ {repo} (env: {args.environment})")
    print(f"   Old credentials: {revoked} revoked"
          + ("" if not args.keep_old else " (kept: --keep-old)"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
