#!/bin/bash
# A Qwen3.8 conversation keeps its prompt cache when only the reasoning effort changes.
set -euo pipefail
MODEL="${1:?Usage: test_effort_hint_cache.sh <qwen3.8 model_dir> [port]}"
PORT="${2:-11369}"
BINARY="${MLX_SERVE_BINARY:-./zig-out/bin/mlx-serve}"
SCRATCH=$(mktemp -d)
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$SCRATCH"
}
trap cleanup EXIT
HOME="$SCRATCH" "$BINARY" --model "$MODEL" --serve --host 127.0.0.1 --port "$PORT" \
    --prefix-cache-entries 8 --log-file "$SCRATCH/server.log" > "$SCRATCH/stdout.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 600); do
    if curl -fsS "http://127.0.0.1:$PORT/health" > /dev/null 2>&1; then break; fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        printf 'FAIL: server stopped during load; log: %s\n' "$SCRATCH/stdout.log"
        exit 1
    fi
    sleep 1
done
python3 - "$PORT" <<'PY'
import json
import sys
import urllib.request

base = f"http://127.0.0.1:{sys.argv[1]}"
# The effort sentence plus the assistant opener: at most 47 tokens (xhigh), 5 with no sentence.
HINT_TAIL = 48

def respond(messages, effort):
    body = {"model": "mlx-serve", "input": messages, "reasoning": {"effort": effort},
            "max_output_tokens": 1, "temperature": 0, "stream": False}
    request = urllib.request.Request(base + "/v1/responses", json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=900) as response:
        usage = json.load(response)["usage"]
    return usage["input_tokens"], usage["input_tokens_details"]["cached_tokens"]

document = "\n".join(f"Record {i}: region {i % 23}, units {i * 37 % 1009}, check {i * i % 7919}." for i in range(400))
question = [{"role": "user", "content": document + "\nWhich region has the most units?"}]
print("effort  input  cached  prefilled")
previous = None
for step, effort in enumerate(["medium", "medium", "high", "medium", "low"]):
    total, cached = respond(question, effort)
    print(f"{effort:7} {total:6} {cached:7} {total - cached:10}")
    if step > 0:
        assert cached > 0, f"{effort} after {previous}: nothing reused"
        assert total - cached <= HINT_TAIL + 31, f"{effort}: prefilled {total - cached} tokens"
    previous = effort

print("turn effort  input  cached  prefilled")
turns = list(question)
last_input = None
for turn, effort in enumerate(["low", "high", "low", "medium", "high"]):
    total, cached = respond(turns, effort)
    print(f"{turn + 1:4} {effort:6} {total:6} {cached:7} {total - cached:10}")
    if last_input is not None:
        assert cached >= last_input - HINT_TAIL, f"turn {turn + 1}: reused {cached} of the previous {last_input}"
    last_input = total
    turns += [{"role": "assistant", "content": f"Answer {turn + 1}: region {turn * 5 % 23}."},
              {"role": "user", "content": f"Now check region {turn * 7 % 23} against record {turn * 41}."}]
print("PASS: every effort reuses the conversation")
PY
if grep -q "jinja render failed" "$SCRATCH/server.log"; then
    echo "FAIL: the template fell back"
    exit 1
fi
