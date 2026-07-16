#!/usr/bin/env bash
# Render this directory's .env secrets from AWS SSM Parameter Store.
#
# Fetches /fuze-store/{env}/websocket/* (SecureStrings, via the EC2 instance
# role) and rewrites ONLY those keys in the existing .env — every other line
# (Soketi tuning, hosts, ports) is left exactly as-is. Atomic write; the
# previous .env is kept at .env.previous.
#
# SAFE-SKIP: if SSM is unreachable, the path is empty, or any value is still
# "PLACEHOLDER" (seed with fuze-store-api-tf/scripts/seed-ssm.sh), the
# existing .env is left untouched and the script exits 0.
#
# Usage: ./render-env.sh <dev|prod>
# After a successful render: docker compose up -d --force-recreate
set -euo pipefail

ENVIRONMENT="${1:?usage: render-env.sh <dev|prod>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
REGION="${AWS_REGION:-ap-southeast-1}"
SSM_PATH="/fuze-store/${ENVIRONMENT}/websocket"
OUT_FILE="$DIR/.env"

if [ ! -f "$OUT_FILE" ]; then
  echo "render-env: $OUT_FILE not found — create it from .env.example first"
  exit 0
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "render-env: aws CLI not installed — keeping existing .env"
  echo "  install: sudo snap install aws-cli --classic   (or: sudo apt-get install -y awscli)"
  exit 0
fi

params_file=$(mktemp)
aws_err=$(mktemp)
chmod 600 "$params_file"
trap 'rm -f "$params_file" "$aws_err" "$OUT_FILE.tmp"' EXIT

if ! aws ssm get-parameters-by-path \
    --path "$SSM_PATH" --with-decryption --region "$REGION" \
    --output json > "$params_file" 2>"$aws_err"; then
  echo "render-env: cannot reach SSM (${SSM_PATH}) — keeping existing .env"
  sed 's/^/  aws: /' "$aws_err" | head -4
  exit 0
fi

set +e
python3 - "$OUT_FILE" "$params_file" "$OUT_FILE.tmp" <<'PYEOF'
import json, re, sys

base_path, params_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(params_path) as f:
    payload = json.load(f)

params = {p["Name"].rsplit("/", 1)[-1]: p["Value"] for p in payload.get("Parameters", [])}

if not params:
    print("render-env: no parameters under SSM path — keeping existing .env")
    sys.exit(3)

placeholders = sorted(k for k, v in params.items() if v == "PLACEHOLDER")
if placeholders:
    print("render-env: unseeded PLACEHOLDER params (%s) — keeping existing .env"
          % ", ".join(placeholders))
    sys.exit(3)

# SSM can't store empty strings — __EMPTY__ is the seeded sentinel for an
# intentionally-blank secret (see fuze-store-api-tf/scripts/seed-ssm.sh).
params = {k: ("" if v == "__EMPTY__" else v) for k, v in params.items()}

def quote(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_./:@+-]*", value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

key_re = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=")
out_lines, seen = [], set()

with open(base_path) as f:
    for raw in f.read().splitlines():
        m = key_re.match(raw)
        if m and m.group(1) in params:
            key = m.group(1)
            out_lines.append(f"{key}={quote(params[key])}")
            seen.add(key)
        else:
            out_lines.append(raw)

extra = [k for k in sorted(params) if k not in seen]
if extra:
    out_lines.append("")
    out_lines.append("# --- Rendered from SSM (keys not present before)")
    out_lines.extend(f"{k}={quote(params[k])}" for k in extra)

with open(out_path, "w") as f:
    f.write("\n".join(out_lines) + "\n")
PYEOF
status=$?
set -e

if [ "$status" -eq 3 ]; then
  exit 0
elif [ "$status" -ne 0 ]; then
  echo "render-env: merge failed (exit $status)" >&2
  exit "$status"
fi

chmod 600 "$OUT_FILE.tmp"
cp -p "$OUT_FILE" "$OUT_FILE.previous"
mv "$OUT_FILE.tmp" "$OUT_FILE"
echo "render-env: rendered $OUT_FILE with ${SSM_PATH}/*"
echo "  restart soketi:  sudo systemctl restart soketi   (EC2 systemd install via setup.sh)"
echo "  or local dev:    docker compose up -d --force-recreate"
