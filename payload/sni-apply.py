#!/usr/bin/env python3
import json
import sys

new_sni, secondary_sni, inbound_id, in_file, out_file = sys.argv[1:6]
with open(in_file, "r", encoding="utf-8") as f:
    data = json.load(f)

obj = data.get("obj", data)
if isinstance(obj, dict) and "inbounds" in obj:
    candidates = obj["inbounds"]
elif isinstance(obj, list):
    candidates = obj
elif isinstance(obj, dict) and "id" in obj:
    candidates = [obj]
else:
    raise SystemExit("3x-ui API response does not contain inbound list")

selected = None
for item in candidates:
    if str(item.get("id", "")) == str(inbound_id):
        selected = item
        break
if selected is None:
    for item in candidates:
        if item.get("remark") == "warren-reality":
            selected = item
            break
if selected is None:
    for item in candidates:
        if str(item.get("port", "")) == "443" and item.get("protocol") == "vless":
            selected = item
            break
if selected is None:
    raise SystemExit("Warren Reality inbound not found")

selected.pop("clientStats", None)
stream_raw = selected.get("streamSettings") or "{}"
stream = json.loads(stream_raw) if isinstance(stream_raw, str) else stream_raw
reality = stream.setdefault("realitySettings", {})
old_target = reality.get("target", "")
old_names = reality.get("serverNames", [])
reality["target"] = f"{new_sni}:443"
reality["serverNames"] = [new_sni] if secondary_sni == new_sni else [new_sni, secondary_sni]
selected["streamSettings"] = json.dumps(stream, separators=(",", ":"))

with open(out_file, "w", encoding="utf-8") as f:
    json.dump(selected, f, separators=(",", ":"))

print(f"INBOUND_ID={selected.get('id')}")
print(f"OLD_TARGET={old_target}")
print(f"OLD_SERVER_NAMES={','.join(old_names) if isinstance(old_names, list) else old_names}")
print(f"NEW_TARGET={new_sni}:443")
print(f"NEW_SERVER_NAMES={','.join(reality['serverNames'])}")
