#!/usr/bin/env bash
set -euo pipefail

MODEL=qwen2.5-coder:14b

if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
fi

if ! command -v gh >/dev/null 2>&1; then
  echo 'Install GitHub CLI first: https://cli.github.com/'
  exit 1
fi

ollama serve >/tmp/ollama.log 2>&1 &
sleep 5
ollama pull ${MODEL}

python3 - <<'PY'
import json
import urllib.request
payload=json.dumps({
  'model':'qwen2.5-coder:14b',
  'prompt':'Return strict JSON {"ok":true}',
  'stream':False,
  'format':'json'
}).encode()
req=urllib.request.Request(
  'http://localhost:11434/api/generate',
  data=payload,
  headers={'Content-Type':'application/json'}
)
print(urllib.request.urlopen(req).read().decode())
PY

echo 'OpenClaude local runtime ready.'
