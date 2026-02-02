#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# User exits (extendable)
# -----------------------------
EXIT_TAGS=("HK_HKT" "TW_HINET" "HK_CMHK")
EXIT_NAMES=("Hong Kong HKT AS4760" "Taiwan HINET AS3462" "Hong Kong CMHK AS137872")
EXIT_SOCKS=("socks-1.kconnect.to:10000" "socks-2.kconnect.to:10000" "socks-3.kconnect.to:10000")

# -----------------------------
# Rule source (blackmatrix7 Clash)
# Pattern is documented in per-rule README: *.yaml / *_No_Resolve.yaml / *.list etc.
# We'll fetch via jsDelivr CDN for speed.
# -----------------------------
RULE_BASE="https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash"

# Work dirs
SB_DIR="/etc/sing-box"
WORK_DIR="${SB_DIR}/rulesets-socks"
RAW_DIR="${WORK_DIR}/raw"
JSON_DIR="${WORK_DIR}/json"
SRS_DIR="${WORK_DIR}/srs"

mkdir -p "${RAW_DIR}" "${JSON_DIR}" "${SRS_DIR}"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root: sudo $0"
    exit 1
  fi
}

apt_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates nftables python3 jq
}

install_singbox_if_needed() {
  if command -v sing-box >/dev/null 2>&1; then
    return 0
  fi
  echo "[+] Installing sing-box via official install script..."
  # Official install script reference: sing-box.app/install.sh
  curl -fsSL https://sing-box.app/install.sh | sh
}

ensure_systemd_service() {
  if systemctl list-unit-files | grep -q '^sing-box\.service'; then
    return 0
  fi

  cat > /etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=1s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
}

pause() { read -r -p "Press Enter to continue..."; }

menu_single() {
  local prompt="$1"; shift
  local -n _items=$1; shift
  echo
  echo "$prompt"
  local i
  for i in "${!_items[@]}"; do
    printf "  %d) %s\n" "$((i+1))" "${_items[$i]}"
  done
  printf "  0) Direct (no proxy)\n"
  local ans
  while true; do
    read -r -p "Choose: " ans
    if [[ "${ans}" =~ ^[0-9]+$ ]] && (( ans>=0 && ans<=${#_items[@]} )); then
      echo "${ans}"
      return 0
    fi
    echo "Invalid choice."
  done
}

menu_multi() {
  local prompt="$1"; shift
  local -n _items=$1; shift

  echo
  echo "$prompt"
  local i
  for i in "${!_items[@]}"; do
    printf "  %d) %s\n" "$((i+1))" "${_items[$i]}"
  done
  echo "  a) All"
  echo "  0) None/Done"
  local ans
  read -r -p "Input (e.g. 1 2 4 / 1,3 / a): " ans
  ans="${ans//,/ }"

  if [[ -z "${ans}" || "${ans}" == "a" || "${ans}" == "A" ]]; then
    # all
    local out=()
    for i in "${!_items[@]}"; do out+=("$((i+1))"); done
    printf "%s\n" "${out[@]}"
    return 0
  fi

  local out=()
  for tok in ${ans}; do
    if [[ "${tok}" =~ ^[0-9]+$ ]] && (( tok>=1 && tok<=${#_items[@]} )); then
      out+=("${tok}")
    fi
  done
  # unique
  if (( ${#out[@]} == 0 )); then
    return 0
  fi
  printf "%s\n" "${out[@]}" | awk '!seen[$0]++'
}

# -----------------------------
# Services definition: ID -> (Display, RuleDir)
# Only include ones that exist in the repo list.
# -----------------------------
declare -A SVC_NAME SVC_DIR

add_svc() {
  local id="$1" name="$2" dir="$3"
  SVC_NAME["$id"]="$name"
  SVC_DIR["$id"]="$dir"
}

# Global Platform
add_svc "DAZN" "DAZN" "DAZN"
add_svc "DISNEY" "Disney+" "Disney"
add_svc "NETFLIX" "Netflix" "Netflix"
add_svc "AMAZON_PRIME" "Amazon Prime Video" "AmazonPrimeVideo"
add_svc "TVB" "TVB / TVBAnywhere+" "TVB"
add_svc "VIUTV" "Viu.com / Viu.TV" "ViuTV"
add_svc "STEAM" "Steam Store" "Steam"
add_svc "YOUTUBE" "YouTube" "YouTube"
add_svc "GOOGLE_SEARCH" "Google Search" "GoogleSearch"
add_svc "INSTAGRAM" "Instagram" "Instagram"
add_svc "IQIYI" "iQiyi" "iQIYI"
add_svc "TIKTOK" "TikTok" "TikTok"

# Taiwan Media
add_svc "KKTV" "KKTV" "KKTV"
add_svc "LITV" "LiTV" "LiTV"
add_svc "LINETV" "LineTV.TW" "LineTV"
add_svc "HAMI" "Hami Video" "HamiVideo"
add_svc "BAHAMUT" "Bahamut Anime" "Bahamut"
add_svc "HBO_TW" "HBO / Max (Taiwan)" "HBOAsia"
add_svc "BILIBILI" "BiliBili" "BiliBili"
add_svc "FRIDAY" "Friday Video" "friDay"

# Hong Kong Media
add_svc "NOWE" "Now E" "NowE"
add_svc "MYTVSUPER" "MyTVSuper" "myTVSUPER"
add_svc "HBO_HK" "HBO / Max (Hong Kong)" "HBOHK"

# AI Platform
add_svc "OPENAI" "OpenAI" "OpenAI"
add_svc "CLAUDE" "Claude 2" "Claude"
add_svc "GEMINI" "Google Gemini / AI Studio" "Gemini"
add_svc "COPILOT" "Microsoft Copilot (Image)" "Copilot"

# Categories: ordered by priority (AI > Taiwan > HK > Global)
CATS=("Global Platform" "Taiwan Media" "Hong Kong Media" "AI Platform")
declare -A CAT_SVCS
CAT_SVCS["Global Platform"]="DAZN DISNEY NETFLIX AMAZON_PRIME TVB VIUTV STEAM YOUTUBE GOOGLE_SEARCH INSTAGRAM IQIYI TIKTOK"
CAT_SVCS["Taiwan Media"]="KKTV LITV LINETV HAMI BAHAMUT HBO_TW BILIBILI FRIDAY"
CAT_SVCS["Hong Kong Media"]="NOWE VIUTV MYTVSUPER HBO_HK TVB BILIBILI"
CAT_SVCS["AI Platform"]="OPENAI CLAUDE GEMINI COPILOT"

# -----------------------------
# Fetch + convert rules
# -----------------------------
fetch_rule_file() {
  local dir="$1"
  local out="$2"
  local candidates=(
    "${dir}_No_Resolve.yaml"
    "${dir}.yaml"
    "${dir}.list"
  )
  local f url
  for f in "${candidates[@]}"; do
    url="${RULE_BASE}/${dir}/${f}"
    if curl -fsSL --max-time 30 "$url" -o "${out}.tmp"; then
      mv "${out}.tmp" "${out}"
      echo "$f"
      return 0
    fi
  done
  rm -f "${out}.tmp" || true
  return 1
}

to_ruleset_json() {
  local in_file="$1"
  local out_json="$2"
  python3 - "$in_file" "$out_json" <<'PY'
import sys, json

infile, outfile = sys.argv[1], sys.argv[2]
lines = open(infile, "r", encoding="utf-8", errors="ignore").read().splitlines()

rules = []
for raw in lines:
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.lower() == "payload:":
        continue
    if line.startswith("-"):
        line = line[1:].strip()
    line = line.strip(" '\"")
    if not line or line.startswith("#"):
        continue
    if "," not in line:
        continue

    t, v = line.split(",", 1)
    t = t.strip().upper()
    v = v.strip()
    if not v:
        continue

    # Some lines may include ",no-resolve"
    if t in ("IP-CIDR", "IP-CIDR6"):
        v = v.split(",", 1)[0].strip()

    key = None
    if t == "DOMAIN":
        key = "domain"
    elif t == "DOMAIN-SUFFIX":
        key = "domain_suffix"
    elif t == "DOMAIN-KEYWORD":
        key = "domain_keyword"
    elif t == "DOMAIN-REGEX":
        key = "domain_regex"
    elif t in ("IP-CIDR", "IP-CIDR6"):
        key = "ip_cidr"
    else:
        continue

    rules.append({key: [v]})

data = {"version": 2, "rules": rules}
with open(outfile, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
PY
}

compile_ruleset() {
  local json_file="$1"
  local srs_file="$2"
  sing-box rule-set compile --output "$srs_file" "$json_file"
}

# -----------------------------
# Build sing-box config
# -----------------------------
write_config() {
  local selected_tsv="$1"
  local default_outbound="$2"

  python3 - "$selected_tsv" "$default_outbound" <<'PY'
import sys, json

tsv, final_out = sys.argv[1], sys.argv[2]

# Read selected services: id \t dir \t outbound
items = []
with open(tsv, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        sid, sdir, out = line.split("\t")
        items.append((sid, sdir, out))

# Collect outbounds used
used_outbounds = sorted(set([o for _,_,o in items if o != "direct"]))

# DNS servers per outbound (DoH via corresponding outbound)
dns_servers = [
    {"tag": "dns-init", "address": "223.5.5.5", "detour": "direct"},
    {"tag": "dns-direct", "address": "223.5.5.5", "detour": "direct"},
]
for o in used_outbounds:
    dns_servers.append({"tag": f"dns-{o}", "address": "https://1.1.1.1/dns-query", "detour": o})

dns_rules = []
# Ensure socks server hostnames resolve direct
for host in ["socks-1.kconnect.to", "socks-2.kconnect.to", "socks-3.kconnect.to"]:
    dns_rules.append({
        "domain": [host],
        "action": "route",
        "server": "dns-direct"
    })

# Rule-sets
rule_sets = []
route_rules = []

for sid, sdir, out in items:
    rule_sets.append({
        "type": "local",
        "tag": sid,
        "format": "binary",
        "path": f"/etc/sing-box/rulesets-socks/srs/{sid}.srs"
    })
    route_rules.append({
        "rule_set": [sid],
        "outbound": out
    })
    # DNS route: send DNS queries for this rule_set to the same outbound's DNS server (if proxied)
    if out != "direct":
        dns_rules.append({
            "rule_set": [sid],
            "action": "route",
            "server": f"dns-{out}"
        })

# Basic safety: private IP direct + socks servers direct to avoid loops
route_rules = [
    {"ip_is_private": True, "outbound": "direct"},
    {"domain": ["socks-1.kconnect.to", "socks-2.kconnect.to", "socks-3.kconnect.to"], "outbound": "direct"},
] + route_rules

config = {
  "log": {"level": "info"},
  "dns": {
    "servers": dns_servers,
    "rules": dns_rules,
    "final": "dns-direct",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "singtun0",
      "inet4_address": "172.19.0.1/30",
      "mtu": 1500,
      "auto_route": True,
      "auto_redirect": True,
      "sniff": True,
      "sniff_override_destination": True
    }
  ],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"},

    # Socks outbounds (fixed 3; extend in script if needed)
    {"type": "socks", "tag": "HK_HKT", "server": "socks-1.kconnect.to", "server_port": 10000, "version": "5"},
    {"type": "socks", "tag": "TW_HINET", "server": "socks-2.kconnect.to", "server_port": 10000, "version": "5"},
    {"type": "socks", "tag": "HK_CMHK", "server": "socks-3.kconnect.to", "server_port": 10000, "version": "5"},
  ],
  "route": {
    "auto_detect_interface": True,
    "rule_set": rule_sets,
    "rules": route_rules,
    "final": final_out
  }
}

out_path = "/etc/sing-box/config.json"
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
print(out_path)
PY
}

# -----------------------------
# Main interactive flow
# -----------------------------
need_root
apt_deps
install_singbox_if_needed
ensure_systemd_service

echo
echo "======================================================"
echo " sing-box SOCKS Split Router (Debian, TUN global)"
echo " Rules: blackmatrix7/ios_rule_script (Clash)"
echo "======================================================"
echo

MODE_ITEMS=("Recommended (Global/HK -> HK_HKT, Taiwan/AI -> TW_HINET)" "Custom")
mode="$(menu_single "Select mode:" MODE_ITEMS)"
echo

declare -A CAT_OUTBOUND
declare -A SVC_OUTBOUND_OVERRIDE
SELECTED_CATS=()

if [[ "$mode" == "1" ]]; then
  # Recommended
  SELECTED_CATS=("${CATS[@]}")
  CAT_OUTBOUND["Global Platform"]="HK_HKT"
  CAT_OUTBOUND["Hong Kong Media"]="HK_HKT"
  CAT_OUTBOUND["Taiwan Media"]="TW_HINET"
  CAT_OUTBOUND["AI Platform"]="TW_HINET"
else
  # Custom: choose categories
  mapfile -t cat_idxs < <(menu_multi "Select categories (Enter=All):" CATS || true)
  if (( ${#cat_idxs[@]} == 0 )); then
    echo "No category selected. Exit."
    exit 0
  fi
  for idx in "${cat_idxs[@]}"; do
    SELECTED_CATS+=("${CATS[$((idx-1))]}")
  done

  # choose outbound per category
  for c in "${SELECTED_CATS[@]}"; do
    ans="$(menu_single "Outbound for category: ${c}" EXIT_NAMES)"
    if [[ "$ans" == "0" ]]; then
      CAT_OUTBOUND["$c"]="direct"
    else
      CAT_OUTBOUND["$c"]="${EXIT_TAGS[$((ans-1))]}"
    fi
  done
fi

# Optional per-service overrides
for c in "${SELECTED_CATS[@]}"; do
  echo
  echo "Category: ${c}"
  echo "Default outbound: ${CAT_OUTBOUND[$c]}"
  read -r -p "Expand and override specific services in this category? (y/N): " yn
  yn="${yn:-N}"
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    # list services
    IFS=' ' read -r -a svc_ids <<< "${CAT_SVCS[$c]}"
    svc_menu=()
    for sid in "${svc_ids[@]}"; do
      svc_menu+=("${SVC_NAME[$sid]}")
    done
    mapfile -t svc_idxs < <(menu_multi "Select services to override (0=skip):" svc_menu || true)
    if (( ${#svc_idxs[@]} > 0 )); then
      for sidx in "${svc_idxs[@]}"; do
        sid="${svc_ids[$((sidx-1))]}"
        ans="$(menu_single "Outbound for service: ${SVC_NAME[$sid]}" EXIT_NAMES)"
        if [[ "$ans" == "0" ]]; then
          SVC_OUTBOUND_OVERRIDE["$sid"]="direct"
        else
          SVC_OUTBOUND_OVERRIDE["$sid"]="${EXIT_TAGS[$((ans-1))]}"
        fi
      done
    fi
  fi
done

# Default outbound
DEFAULT_ITEMS=("${EXIT_NAMES[@]}")
default_ans="$(menu_single "Default outbound for unmatched traffic:" DEFAULT_ITEMS)"
DEFAULT_OUT="direct"
if [[ "$default_ans" != "0" ]]; then
  DEFAULT_OUT="${EXIT_TAGS[$((default_ans-1))]}"
fi

# Build final service mapping with priority: AI > Taiwan > HK > Global
PRIORITY=("AI Platform" "Taiwan Media" "Hong Kong Media" "Global Platform")

declare -A FINAL_SVC_OUT FINAL_SVC_DIR
for pc in "${PRIORITY[@]}"; do
  # only if selected
  found=0
  for sc in "${SELECTED_CATS[@]}"; do
    if [[ "$sc" == "$pc" ]]; then found=1; break; fi
  done
  ((found==1)) || continue

  IFS=' ' read -r -a svc_ids <<< "${CAT_SVCS[$pc]}"
  for sid in "${svc_ids[@]}"; do
    if [[ -z "${FINAL_SVC_OUT[$sid]+x}" ]]; then
      FINAL_SVC_OUT["$sid"]="${CAT_OUTBOUND[$pc]}"
      FINAL_SVC_DIR["$sid"]="${SVC_DIR[$sid]}"
    fi
  done
done

# Apply overrides
for sid in "${!SVC_OUTBOUND_OVERRIDE[@]}"; do
  FINAL_SVC_OUT["$sid"]="${SVC_OUTBOUND_OVERRIDE[$sid]}"
  FINAL_SVC_DIR["$sid"]="${SVC_DIR[$sid]}"
done

# Prepare selected TSV
SELECTED_TSV="${WORK_DIR}/selected.tsv"
: > "$SELECTED_TSV"

echo
echo "[+] Fetching & compiling rulesets..."
for sid in "${!FINAL_SVC_OUT[@]}"; do
  dir="${FINAL_SVC_DIR[$sid]}"
  out_tag="${FINAL_SVC_OUT[$sid]}"

  raw_path="${RAW_DIR}/${sid}.rule"
  if ! fetched="$(fetch_rule_file "$dir" "$raw_path")"; then
    echo "[-] Skip ${SVC_NAME[$sid]} (${dir}): not found"
    continue
  fi

  json_path="${JSON_DIR}/${sid}.json"
  srs_path="${SRS_DIR}/${sid}.srs"

  to_ruleset_json "$raw_path" "$json_path"
  compile_ruleset "$json_path" "$srs_path"

  printf "%s\t%s\t%s\n" "$sid" "$dir" "$out_tag" >> "$SELECTED_TSV"
  echo "[+] ${SVC_NAME[$sid]} -> ${out_tag} (source: ${dir}/${fetched})"
done

if [[ ! -s "$SELECTED_TSV" ]]; then
  echo "No rulesets built. Abort."
  exit 1
fi

# Backup old config
if [[ -f "${SB_DIR}/config.json" ]]; then
  cp -a "${SB_DIR}/config.json" "${SB_DIR}/config.json.bak.$(date +%Y%m%d-%H%M%S)"
fi

cfg_path="$(write_config "$SELECTED_TSV" "$DEFAULT_OUT")"
echo
echo "[+] sing-box config written: ${cfg_path}"
echo "[+] Enabling & restarting sing-box..."
systemctl enable --now sing-box
systemctl restart sing-box

echo
echo "Done."
echo "Tip: view logs -> journalctl -u sing-box -e"
