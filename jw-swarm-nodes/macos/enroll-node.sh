#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  enroll-node.sh --base-url https://swarm.example.com --node-id node-macbook-01 --token <one-time-token> [--out-dir <dir>]

This script:
  1) Generates a local private key and CSR.
  2) Downloads the Fleet Manager CA cert.
  3) Exchanges CSR + token for a signed node cert.
  4) Writes node.pem (cert+key) and ca.crt for JWSwarmNode config.
USAGE
}

BASE_URL=""
NODE_ID=""
TOKEN=""
OUT_DIR="${HOME}/.jw-swarm-node"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      BASE_URL="$2"
      shift 2
      ;;
    --node-id)
      NODE_ID="$2"
      shift 2
      ;;
    --token)
      TOKEN="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$BASE_URL" || -z "$NODE_ID" || -z "$TOKEN" ]]; then
  usage
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

KEY_PATH="$OUT_DIR/${NODE_ID}.key"
CSR_PATH="$OUT_DIR/${NODE_ID}.csr"
CERT_PATH="$OUT_DIR/${NODE_ID}.crt"
NODE_PEM_PATH="$OUT_DIR/node.pem"
CA_PATH="$OUT_DIR/ca.crt"

openssl genrsa -out "$KEY_PATH" 2048
openssl req -new -key "$KEY_PATH" -subj "/CN=${NODE_ID}" -out "$CSR_PATH"

curl -fsS "$BASE_URL/bootstrap/ca.crt" -o "$CA_PATH"

ENROLL_JSON="$OUT_DIR/enroll-response.json"
python3 - "$BASE_URL" "$NODE_ID" "$TOKEN" "$CSR_PATH" "$ENROLL_JSON" <<'PY'
import json
import pathlib
import sys
import urllib.request

base_url, node_id, token, csr_path, out_path = sys.argv[1:6]
csr = pathlib.Path(csr_path).read_text(encoding="utf-8")
payload = {
    "node_id": node_id,
    "token": token,
    "csr_pem": csr,
}
req = urllib.request.Request(
    url=f"{base_url}/bootstrap/enroll",
    data=json.dumps(payload).encode("utf-8"),
    headers={"content-type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req) as resp:
        data = resp.read().decode("utf-8")
except Exception as exc:
    raise SystemExit(f"enroll request failed: {exc}")
pathlib.Path(out_path).write_text(data, encoding="utf-8")
PY

python3 - "$ENROLL_JSON" "$CERT_PATH" <<'PY'
import json
import pathlib
import sys

resp_path, cert_path = sys.argv[1:3]
obj = json.loads(pathlib.Path(resp_path).read_text(encoding="utf-8"))
cert = obj.get("node_cert_pem")
if not cert:
    raise SystemExit("missing node_cert_pem in enrollment response")
pathlib.Path(cert_path).write_text(cert, encoding="utf-8")
PY

cat "$CERT_PATH" "$KEY_PATH" > "$NODE_PEM_PATH"
chmod 600 "$KEY_PATH" "$NODE_PEM_PATH"

cat <<EOF
Enrollment complete.

Use these in JWSwarmNode Configuration:
  Fleet URL: ${BASE_URL/https:/wss:}/node/connect
  Node Cert (PEM): $NODE_PEM_PATH
  CA Cert: $CA_PATH
EOF
