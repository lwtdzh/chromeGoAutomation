#!/usr/bin/env bash
set -euo pipefail

SKIP_TEST=0
NO_PUSH=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-test|-SkipTest) SKIP_TEST=1 ;;
    --no-push) NO_PUSH=1 ;;
    -h|--help)
      echo "Usage: $0 [--skip-test] [--no-push]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODES_DIR="$WORK_DIR/nodes"
OUTPUT_FILE="$WORK_DIR/list"
SUBSCRIPTION_LIST_URL="https://github.com/lwtdzh/temp-storage/blob/main/chromego-filter-then-push-github.list"
SUBSCRIPTION_LIST="$WORK_DIR/chromego-filter-then-push-github.list"
REPO_URL="git@github.com:bang-dream/free-scriptions.git"
REPO_DIR="$WORK_DIR/repo"
XRAY_EXE="$WORK_DIR/xray/xray"
SINGBOX_EXE="$WORK_DIR/sing-box/sing-box"
TEST_URL="https://www.gstatic.com/generate_204"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "missing required command: $1"
  fi
}

install_packages_if_needed() {
  local missing=()
  for cmd in curl git python3 unzip tar; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    return
  fi
  if command -v apt-get >/dev/null 2>&1; then
    log "Installing packages: ${missing[*]}"
    apt-get update
    apt-get install -y "${missing[@]}"
  else
    die "missing commands and apt-get is unavailable: ${missing[*]}"
  fi
}

arch_name() {
  case "$(uname -m)" in
    aarch64|arm64) echo "arm64" ;;
    x86_64|amd64) echo "amd64" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

github_latest_asset_url() {
  local repo="$1" pattern="$2"
  python3 - "$repo" "$pattern" <<'PY'
import json, re, sys, urllib.request
repo, pattern = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/releases/latest",
    headers={"User-Agent": "chromego-linux-sync"},
)
with urllib.request.urlopen(req, timeout=30) as r:
    release = json.load(r)
rx = re.compile(pattern, re.I)
for asset in release.get("assets", []):
    name = asset.get("name", "")
    if rx.search(name):
        print(asset["browser_download_url"])
        sys.exit(0)
print(f"no asset matched {pattern!r}", file=sys.stderr)
sys.exit(1)
PY
}

download_xray() {
  [ -x "$XRAY_EXE" ] && { log "  xray already exists"; return; }
  local arch asset tmp
  arch="$(arch_name)"
  mkdir -p "$WORK_DIR/xray"
  tmp="$(mktemp -d)"
  if [ "$arch" = "arm64" ]; then
    asset="$(github_latest_asset_url XTLS/Xray-core 'Xray-linux-arm64-v8a\.zip$')"
  else
    asset="$(github_latest_asset_url XTLS/Xray-core 'Xray-linux-64\.zip$')"
  fi
  log "  Downloading xray: $asset"
  curl -L --fail --retry 3 -o "$tmp/xray.zip" "$asset"
  unzip -q "$tmp/xray.zip" -d "$tmp/xray"
  cp "$tmp/xray/xray" "$XRAY_EXE"
  chmod +x "$XRAY_EXE"
  rm -rf "$tmp"
  log "  xray installed"
}

download_singbox() {
  [ -x "$SINGBOX_EXE" ] && { log "  sing-box already exists"; return; }
  local arch asset tmp
  arch="$(arch_name)"
  mkdir -p "$WORK_DIR/sing-box"
  tmp="$(mktemp -d)"
  asset="$(github_latest_asset_url SagerNet/sing-box "sing-box-.*linux-${arch}.*\\.tar\\.gz$")"
  log "  Downloading sing-box: $asset"
  curl -L --fail --retry 3 -o "$tmp/sing-box.tar.gz" "$asset"
  tar -xzf "$tmp/sing-box.tar.gz" -C "$tmp"
  find "$tmp" -type f -name sing-box -exec cp {} "$SINGBOX_EXE" \; -quit
  [ -x "$SINGBOX_EXE" ] || chmod +x "$SINGBOX_EXE"
  rm -rf "$tmp"
  log "  sing-box installed"
}

download_subscriptions() {
  fetch_subscription_list
  [ -s "$SUBSCRIPTION_LIST" ] || die "subscription list not found: $SUBSCRIPTION_LIST"
  rm -rf "$NODES_DIR"
  mkdir -p "$NODES_DIR"

  local i=0 url out ok=0
  while IFS= read -r url || [ -n "$url" ]; do
    url="${url%%#*}"
    url="$(printf '%s' "$url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$url" ] && continue
    i=$((i + 1))
    out="$NODES_DIR/subscription-$(printf '%02d' "$i").yaml"
    if curl -L --fail --retry 2 --connect-timeout 15 --max-time 60 -o "$out" "$url"; then
      ok=$((ok + 1))
      log "  [$i] downloaded: $url"
    else
      rm -f "$out"
      log "  [$i] failed: $url"
    fi
  done < "$SUBSCRIPTION_LIST"

  [ "$ok" -gt 0 ] || die "no subscription YAML files downloaded"
  log "  Downloaded $ok subscription files"
}

fetch_subscription_list() {
  local url="$SUBSCRIPTION_LIST_URL"
  local raw_url="$url"
  local owner repo branch path

  if [[ "$url" =~ ^https://github.com/([^/]+)/([^/]+)/blob/([^/]+)/(.*)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    branch="${BASH_REMATCH[3]}"
    path="${BASH_REMATCH[4]}"
    raw_url="https://raw.githubusercontent.com/$owner/$repo/$branch/$path"
  else
    owner=""
    repo=""
    branch=""
    path=""
  fi

  log "  Fetching subscription list: $url"
  if curl -L --fail --retry 2 --connect-timeout 15 --max-time 60 -o "$SUBSCRIPTION_LIST" "$raw_url"; then
    log "  Subscription list fetched over HTTPS"
    return
  fi

  if [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$branch" ] && [ -n "$path" ]; then
    log "  HTTPS fetch failed; trying GitHub SSH fallback"
    if git archive --remote="git@github.com:$owner/$repo.git" "$branch" "$path" | tar -xO > "$SUBSCRIPTION_LIST"; then
      log "  Subscription list fetched over GitHub SSH"
      return
    fi
  fi

  die "failed to fetch subscription list from $url"
}

process_nodes() {
  python3 - "$WORK_DIR" "$NODES_DIR" "$OUTPUT_FILE" "$XRAY_EXE" "$SINGBOX_EXE" "$TEST_URL" "$SKIP_TEST" <<'PY'
import base64
import json
import os
import random
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

work_dir, nodes_dir, output_file, xray_exe, singbox_exe, test_url, skip_test_s = sys.argv[1:]
skip_test = skip_test_s == "1"
fake_servers = ("127.", "0.0.0.0", "localhost", "192.168.", "10.", "172.")
xray_protocols = {"vmess", "vless", "ss", "trojan"}
singbox_protocols = {"hysteria2", "hysteria", "tuic"}
ip_country_cache = {}

def log(msg=""):
    print(msg, flush=True)

def is_fake_node(server):
    return any(str(server).startswith(prefix) for prefix in fake_servers)

def extract_value(line):
    if ":" not in line:
        return ""
    val = line.split(":", 1)[1].strip()
    if len(val) >= 2 and ((val[0] == '"' and val[-1] == '"') or (val[0] == "'" and val[-1] == "'")):
        val = val[1:-1]
    return val.strip()

def new_node():
    return {
        "name": "", "type": "", "server": "", "port": 0, "uuid": "",
        "password": "", "alterId": 0, "cipher": "auto", "network": "tcp",
        "tls": False, "sni": "", "skipCertVerify": False, "publicKey": "",
        "shortId": "", "obfs": "", "obfsPassword": "", "authStr": "",
        "up": "", "down": "", "alpn": "", "congestionController": "bbr",
        "udpRelayMode": "native", "reduceRtt": True,
    }

def parse_bool(value):
    return str(value).strip().lower() == "true"

def parse_node_field(line, node, section):
    t = line.strip()
    if section == "reality":
        if t.startswith("public-key"):
            node["publicKey"] = extract_value(t)
        elif t.startswith("short-id"):
            node["shortId"] = extract_value(t)
        return
    if section == "hysteria2":
        if t.startswith("obfs-salamander"):
            node["obfs"] = extract_value(t)
        elif t.startswith("obfs-password"):
            node["obfsPassword"] = extract_value(t)
        return

    mapping = {
        "name:": "name", "type:": "type", "server:": "server",
        "uuid:": "uuid", "password:": "password", "auth:": "password",
        "auth-str:": "authStr", "cipher:": "cipher", "network:": "network",
        "sni:": "sni", "servername:": "sni", "obfs-salamander:": "obfs",
        "obfs-password:": "obfsPassword", "up:": "up", "down:": "down",
        "congestion-controller:": "congestionController",
        "congestion_controller:": "congestionController",
        "udp-relay-mode:": "udpRelayMode",
    }
    if t.startswith("port:"):
        try:
            node["port"] = int(extract_value(t))
        except ValueError:
            pass
    elif t.startswith("alterId:"):
        try:
            node["alterId"] = int(extract_value(t))
        except ValueError:
            pass
    elif t.startswith("tls:"):
        node["tls"] = parse_bool(extract_value(t))
    elif t.startswith("skip-cert-verify:"):
        node["skipCertVerify"] = parse_bool(extract_value(t))
    elif t.startswith("alpn:"):
        val = extract_value(t)
        if val.startswith("[") and val.endswith("]"):
            val = val[1:-1]
        node["alpn"] = val.replace('"', "").replace("'", "").strip()
    elif t.startswith("reduce-rtt:"):
        node["reduceRtt"] = parse_bool(extract_value(t))
    else:
        for prefix, key in mapping.items():
            if t.startswith(prefix):
                val = extract_value(t)
                if key in ("type", "congestionController"):
                    val = val.lower()
                node[key] = val
                break

def parse_nodes_from_yaml(content):
    nodes = []
    if not content:
        return nodes
    lines = content.splitlines()
    first_numeric = [line for line in lines[:10] if line.strip().isdigit()]
    if len(first_numeric) >= 5:
        chars = []
        for line in lines:
            s = line.strip()
            if s.isdigit():
                try:
                    chars.append(chr(int(s)))
                except ValueError:
                    pass
        lines = "".join(chars).splitlines()

    in_proxies = False
    current = None
    section = ""

    def flush_current():
        if current and current.get("server") and current.get("port", 0) > 0 and not is_fake_node(current["server"]):
            nodes.append(current.copy())

    for line in lines:
        trimmed = line.strip()
        if trimmed == "proxies:":
            in_proxies = True
            continue
        if in_proxies and line and line[0].isalpha() and not line.startswith("  ") and not line.startswith("-"):
            flush_current()
            current = None
            in_proxies = False
            section = ""
            continue
        if not in_proxies:
            continue
        if trimmed == "reality-opts:":
            section = "reality"
            continue
        if trimmed == "hysteria2-opts:":
            section = "hysteria2"
            continue
        if section and line.startswith("  ") and not line.startswith("    ") and trimmed and trimmed[0].isalpha():
            section = ""
        if line.startswith("  - ") or line.startswith("- "):
            flush_current()
            current = new_node()
            section = ""
            after_dash = line[4:].strip() if line.startswith("  - ") else line[2:].strip()
            if after_dash:
                parse_node_field(after_dash, current, "")
        elif current is not None and trimmed and not trimmed.startswith("-"):
            parse_node_field(trimmed, current, section)
    flush_current()
    return nodes

def get_country_from_ip(host):
    if host in ip_country_cache:
        return ip_country_cache[host]
    if is_fake_node(host):
        ip_country_cache[host] = "Local"
        return "Local"
    for url in (
        f"http://ip-api.com/json/{urllib.parse.quote(host)}?fields=countryCode&lang=en",
        f"https://ipinfo.io/{urllib.parse.quote(host)}/country",
    ):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "chromego-linux-sync"})
            with urllib.request.urlopen(req, timeout=5) as r:
                data = r.read().decode("utf-8", "replace").strip()
            if "ip-api.com" in url:
                country = json.loads(data).get("countryCode", "")
            else:
                country = data.strip()
            if country:
                ip_country_cache[host] = country
                return country
        except Exception:
            pass
    ip_country_cache[host] = "XX"
    return "XX"

def quote_name(name):
    return urllib.parse.quote(name, safe="")

def b64(s):
    return base64.b64encode(s.encode("utf-8")).decode("ascii")

def convert_node(node, serial, country):
    typ = node.get("type", "")
    addr, port = node.get("server", ""), int(node.get("port") or 0)
    if not addr or port <= 0:
        return None
    password = node.get("password") or node.get("uuid") or ""
    alias = f"【ChromeGo】{serial}-{country}"
    name_enc = quote_name(alias)
    if typ == "vmess":
        if not node.get("uuid"):
            return None
        j = {
            "v": "2", "ps": alias, "add": addr, "port": str(port),
            "id": node["uuid"], "aid": str(node.get("alterId", 0)),
            "scy": node.get("cipher", "auto"), "net": node.get("network", "tcp"),
            "type": "none", "tls": "tls" if node.get("tls") else "",
            "sni": node.get("sni", ""), "host": "", "path": "",
        }
        return "vmess://" + b64(json.dumps(j, ensure_ascii=False, separators=(",", ":")))
    if typ == "vless":
        if not node.get("uuid"):
            return None
        params = [("type", node.get("network") or "tcp")]
        if node.get("publicKey"):
            params += [("security", "reality"), ("pbk", node["publicKey"])]
            if node.get("shortId"):
                params.append(("sid", node["shortId"]))
        elif node.get("tls"):
            params.append(("security", "tls"))
        if node.get("sni"):
            params.append(("sni", node["sni"]))
        return f"vless://{node['uuid']}@{addr}:{port}?{urllib.parse.urlencode(params)}#{name_enc}"
    if typ == "ss":
        if not node.get("cipher") or not password:
            return None
        return f"ss://{b64(node['cipher'] + ':' + password)}@{addr}:{port}#{name_enc}"
    if typ == "trojan":
        if not password:
            return None
        sni = node.get("sni") or addr
        return f"trojan://{password}@{addr}:{port}?{urllib.parse.urlencode({'sni': sni})}#{name_enc}"
    if typ == "hysteria2":
        if not password:
            return None
        params = []
        if node.get("sni"):
            params.append(("sni", node["sni"]))
        if node.get("obfs"):
            params.append(("obfs", node["obfs"]))
        if node.get("obfsPassword"):
            params.append(("obfs-password", node["obfsPassword"]))
        q = "?" + urllib.parse.urlencode(params) if params else ""
        return f"hysteria2://{password}@{addr}:{port}{q}#{name_enc}"
    if typ == "hysteria":
        auth = node.get("authStr") or node.get("password") or ""
        if not auth:
            return None
        params = [("auth", auth)]
        for src, dst in (("up", "up"), ("down", "down"), ("alpn", "alpn"), ("sni", "sni")):
            if node.get(src):
                params.append((dst, node[src]))
        return f"hysteria://{addr}:{port}?{urllib.parse.urlencode(params)}#{name_enc}"
    if typ == "tuic":
        if not node.get("uuid") or not password:
            return None
        params = [("congestion_controller", node.get("congestionController", "bbr"))]
        if node.get("alpn"):
            params.append(("alpn", node["alpn"]))
        if node.get("sni"):
            params.append(("sni", node["sni"]))
        if node.get("udpRelayMode"):
            params.append(("udp_relay_mode", node["udpRelayMode"]))
        return f"tuic://{node['uuid']}:{password}@{addr}:{port}?{urllib.parse.urlencode(params)}#{name_enc}"
    return None

def xray_config(node, port):
    inbound = {"port": port, "protocol": "socks", "settings": {"auth": "noauth", "udp": True}}
    typ = node["type"]
    outbound = None
    if typ == "vmess" and node.get("uuid"):
        outbound = {
            "protocol": "vmess",
            "settings": {"vnext": [{"address": node["server"], "port": node["port"], "users": [{"id": node["uuid"], "alterId": node.get("alterId", 0), "security": node.get("cipher", "auto")}]}]},
            "streamSettings": {"network": node.get("network", "tcp"), "security": "tls" if node.get("tls") else "none"},
        }
        if node.get("tls"):
            outbound["streamSettings"]["tlsSettings"] = {"allowInsecure": True, "serverName": node.get("sni", "")}
    elif typ == "vless" and node.get("uuid"):
        outbound = {
            "protocol": "vless",
            "settings": {"vnext": [{"address": node["server"], "port": node["port"], "users": [{"id": node["uuid"], "encryption": "none"}]}]},
            "streamSettings": {"network": node.get("network", "tcp"), "security": "tls" if node.get("tls") else "none"},
        }
        if node.get("publicKey"):
            outbound["streamSettings"]["security"] = "reality"
            outbound["streamSettings"]["realitySettings"] = {"show": False, "fingerprint": "chrome", "serverName": node.get("sni", ""), "publicKey": node["publicKey"], "shortId": node.get("shortId", "")}
        elif node.get("tls"):
            outbound["streamSettings"]["tlsSettings"] = {"allowInsecure": True, "serverName": node.get("sni", "")}
    elif typ == "ss" and node.get("password") and node.get("cipher"):
        outbound = {"protocol": "shadowsocks", "settings": {"servers": [{"address": node["server"], "port": node["port"], "password": node["password"], "method": node["cipher"]}]}}
    elif typ == "trojan" and node.get("password"):
        outbound = {
            "protocol": "trojan",
            "settings": {"servers": [{"address": node["server"], "port": node["port"], "password": node["password"]}]},
            "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"allowInsecure": True, "serverName": node.get("sni", "")}},
        }
    if not outbound:
        return None
    return json.dumps({"inbounds": [inbound], "outbounds": [outbound]}, ensure_ascii=False)

def mbps(value, default=100):
    digits = "".join(ch for ch in str(value) if ch.isdigit())
    return int(digits) if digits else default

def singbox_config(node, port):
    typ = node["type"]
    outbound = None
    if typ == "hysteria2" and node.get("password"):
        outbound = {"type": "hysteria2", "tag": "proxy", "server": node["server"], "server_port": node["port"], "password": node["password"], "tls": {"enabled": True, "server_name": node.get("sni", ""), "insecure": node.get("skipCertVerify", False)}}
        if node.get("obfs") and node.get("obfsPassword"):
            outbound["obfs"] = {"type": node["obfs"], "password": node["obfsPassword"]}
    elif typ == "hysteria":
        auth = node.get("authStr") or node.get("password") or ""
        if auth:
            outbound = {"type": "hysteria", "tag": "proxy", "server": node["server"], "server_port": node["port"], "auth": auth, "up_mbps": mbps(node.get("up")), "down_mbps": mbps(node.get("down")), "tls": {"enabled": True, "server_name": node.get("sni", ""), "insecure": node.get("skipCertVerify", False), "alpn": [x.strip() for x in (node.get("alpn") or "h3").split(",") if x.strip()]}}
    elif typ == "tuic" and node.get("uuid") and node.get("password"):
        outbound = {"type": "tuic", "tag": "proxy", "server": node["server"], "server_port": node["port"], "uuid": node["uuid"], "password": node["password"], "congestion_control": node.get("congestionController", "bbr"), "udp_relay_mode": node.get("udpRelayMode", "native"), "zero_rtt_handshake": node.get("reduceRtt", True), "tls": {"enabled": True, "server_name": node.get("sni", ""), "insecure": node.get("skipCertVerify", False), "alpn": [x.strip() for x in (node.get("alpn") or "h3").split(",") if x.strip()]}}
    if not outbound:
        return None
    return json.dumps({"log": {"level": "warn"}, "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": port}], "outbounds": [outbound]}, ensure_ascii=False)

def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

def test_node(node, config_text, proxy_exe, port):
    fd, config_file = tempfile.mkstemp(prefix=f"proxy-test-{port}-", suffix=".json")
    os.close(fd)
    with open(config_file, "w", encoding="utf-8") as f:
        f.write(config_text)
    proc = subprocess.Popen([proxy_exe, "run", "-c", config_file], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(1.5 if node["type"] in singbox_protocols else 0.8)
        if proc.poll() is not None:
            return False, f"startup failed (exit: {proc.returncode})"
        out = subprocess.run(["curl", "--socks5-hostname", f"127.0.0.1:{port}", "-m", "10", "-k", "-s", "-o", os.devnull, "-w", "%{http_code}", test_url], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        code = out.stdout.strip()
        return code in ("200", "204"), f"HTTP {code}"
    except Exception as e:
        return False, str(e)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
        try:
            os.unlink(config_file)
        except OSError:
            pass

log("Step 1: Parsing YAML...")
all_nodes = []
for name in sorted(os.listdir(nodes_dir)):
    if not name.endswith((".yaml", ".yml")):
        continue
    path = os.path.join(nodes_dir, name)
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        all_nodes.extend(parse_nodes_from_yaml(f.read()))
log(f"  Parsed: {len(all_nodes)} nodes")

type_counts = {}
for node in all_nodes:
    type_counts[node["type"]] = type_counts.get(node["type"], 0) + 1
log("  Types:" + "".join(f" {k}={v}" for k, v in sorted(type_counts.items(), key=lambda kv: kv[1], reverse=True)))

log("Step 2: Deduplicating...")
unique = {}
for node in all_nodes:
    key = f"{node.get('type')}|{node.get('server')}:{node.get('port')}"
    unique.setdefault(key, node)
deduped = list(unique.values())
log(f"  Unique: {len(deduped)}")

supported = [n for n in deduped if n.get("type") in (xray_protocols | singbox_protocols)]
xray_nodes = [n for n in supported if n.get("type") in xray_protocols]
singbox_nodes = [n for n in supported if n.get("type") in singbox_protocols]
sorted_nodes = singbox_nodes + xray_nodes
log(f"  Xray (vmess/vless/ss/trojan): {len(xray_nodes)}")
log(f"  Singbox (hysteria2/hysteria/tuic): {len(singbox_nodes)}")
log(f"  Sorted: {len(singbox_nodes)} sing-box first, then {len(xray_nodes)} xray")

log("Step 3: Testing proxies...")
stats = {"xray_ok": 0, "xray_fail": 0, "singbox_ok": 0, "singbox_fail": 0}
if skip_test:
    log("  SKIP TEST - including all")
    valid = sorted_nodes
    stats["xray_ok"] = len(xray_nodes)
    stats["singbox_ok"] = len(singbox_nodes)
else:
    valid = []
    subprocess.run(["pkill", "-x", os.path.basename(xray_exe)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["pkill", "-x", os.path.basename(singbox_exe)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for idx, node in enumerate(sorted_nodes, 1):
        port = free_port()
        if node["type"] in xray_protocols:
            config = xray_config(node, port)
            exe = xray_exe
            ok_key, fail_key = "xray_ok", "xray_fail"
        else:
            config = singbox_config(node, port)
            exe = singbox_exe
            ok_key, fail_key = "singbox_ok", "singbox_fail"
        if not config:
            log(f"  [{idx}] SKIP: {node['server']}:{node['port']} [{node['type']}]")
            continue
        ok, reason = test_node(node, config, exe, port)
        if ok:
            valid.append(node)
            stats[ok_key] += 1
            log(f"  [{idx}] OK: {node['server']}:{node['port']} [{node['type']}]")
        else:
            stats[fail_key] += 1
            log(f"  [{idx}] FAIL: {node['server']}:{node['port']} [{node['type']}] - {reason}")
        time.sleep(0.1)

log()
log(f"  Xray: ok={stats['xray_ok']}, fail={stats['xray_fail']}")
log(f"  Singbox: ok={stats['singbox_ok']}, fail={stats['singbox_fail']}")
log(f"  Total valid: {len(valid)}")

log("Step 4: Getting IP geolocation and converting...")
final = []
serial = 1
for node in valid:
    country = get_country_from_ip(node["server"])
    log(f"  Node #{serial}: {node['server']} -> {country} [{node['type']}]")
    text = convert_node(node, serial, country)
    if text:
        final.append(text)
        serial += 1

header = [
    "# ChromeGo Node List",
    "# Updated: " + time.strftime("%Y-%m-%d %H:%M:%S"),
    "# Total: " + str(len(final)),
    "# Format: 【ChromeGo】number-country (x=serial, y=country)",
    "# Protocols: vmess, vless, ss, trojan, hysteria2, hysteria, tuic",
    "",
]
with open(output_file, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(header))
    if final:
        f.write("\n".join(final) + "\n")
log(f"  Saved: {output_file}")
log(f"Valid nodes: {len(final)}")
PY
}

push_to_github() {
  if [ "$NO_PUSH" = "1" ]; then
    log "Step 6: Push skipped (--no-push)"
    return
  fi

  log "Step 6: Pushing to GitHub..."
  if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" fetch origin
    git -C "$REPO_DIR" reset --hard origin/main
  else
    rm -rf "$REPO_DIR"
    git clone "$REPO_URL" "$REPO_DIR"
  fi

  cp "$OUTPUT_FILE" "$REPO_DIR/list"
  git -C "$REPO_DIR" config user.name "$(git -C "$REPO_DIR" config user.name || echo lwtdzh)"
  git -C "$REPO_DIR" config user.email "$(git -C "$REPO_DIR" config user.email || echo root@debian-termux.local)"
  git -C "$REPO_DIR" add list
  if git -C "$REPO_DIR" diff --cached --quiet; then
    log "  No changes to push"
    return
  fi
  git -C "$REPO_DIR" commit -m "Update nodes - $(date '+%Y-%m-%d %H:%M')"
  git -C "$REPO_DIR" push origin main
  log "  Pushed to GitHub"
}

log "=== Node Sync Linux (Enhanced: hysteria2, hysteria, TUIC) ==="
log "Time: $(date '+%Y-%m-%d %H:%M:%S')"
log "WorkDir: $WORK_DIR"

log "Step 0: Checking tools..."
install_packages_if_needed
need_cmd curl
need_cmd git
need_cmd python3
need_cmd unzip
need_cmd tar
download_xray
download_singbox

log "Step 0.5: Downloading subscriptions..."
download_subscriptions

process_nodes
log "Step 5: Saving complete"
push_to_github

log "=== Done ==="
