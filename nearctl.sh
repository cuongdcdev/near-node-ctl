#!/usr/bin/env bash
# nearctl — run extra NEAR nodes on one host next to the existing root node, no Docker. Bash only, run as root.
#
# Each new node = own Linux user (near-<name>) + own --home + own systemd unit (neard-<name>).
#
# One build for everything: neard is compiled once in /root/nearcore (same as the manual upgrade).
# The root node keeps running /root/nearcore/target/release/neard; the build is copied to
# /usr/local/lib/neard/neard-<version> (node users can't read /root) and /usr/local/bin/neard points to it.
#
# The root node's service and data (neard.service, /root/.near) are never modified; it is registered
# as "root" so the dashboard shows it and its ports are never reused.
set -euo pipefail
shopt -s nullglob

REG_DIR=/etc/near-nodes                 # one <name>.env per node
BIN_DIR=/usr/local/lib/neard            # neard-<version> builds, kept for rollback
NEARD=/usr/local/bin/neard              # symlink -> active build
SRC_DIR=/root/nearcore                  # the root node's checkout; built once, shared by all nodes
P2P_BASE=24567
RPC_BASE=3030
MEM_MAX=${MEM_MAX:-16G}                 # per-node cgroup cap: one leaking node can't OOM the others
READY_TIMEOUT=1800                      # rolling restart: max wait for a node to be synced again

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run as root"; }

if [ -t 1 ]; then
  C_OK=$'\e[32m' C_BAD=$'\e[31m' C_WARN=$'\e[33m' C_DIM=$'\e[2m' C_B=$'\e[1m' C_0=$'\e[0m'
else
  C_OK='' C_BAD='' C_WARN='' C_DIM='' C_B='' C_0=''
fi
EL=''   # erase-to-end-of-line, only set inside the TUI

rpc_url_for() {
  case $1 in
    mainnet) echo https://free.rpc.fastnear.com ;;
    testnet) echo https://rpc.testnet.fastnear.com ;;
    *) [ -n "${RPC_URL:-}" ] || die "custom network '$1': set RPC_URL=..."; echo "$RPC_URL" ;;
  esac
}

node_names() { local f; for f in "$REG_DIR"/*.env; do basename "$f" .env; done; }

load_node() {   # sets NODE_NAME NODE_UNIT NODE_MANAGED NODE_USER NODE_HOME NODE_POOL NODE_NET NODE_P2P NODE_RPC
  local name=${1:-}
  [ -n "$name" ] || die "node name required"
  [ -f "$REG_DIR/$name.env" ] || die "unknown node '$name' (see: nearctl list)"
  NODE_UNIT="neard-$name" NODE_MANAGED=1
  # shellcheck disable=SC1090
  . "$REG_DIR/$name.env"
}

port_of() { sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' <<<"$1"; }

register_root_node() {   # read-only registration of the existing root validator; changes nothing of it
  local cfg=/root/.near/config.json
  [ -f /etc/systemd/system/neard.service ] && [ -f "$cfg" ] || return 0
  [ ! -f "$REG_DIR/root.env" ] || return 0
  install -d -m 755 "$REG_DIR"
  {
    echo "NODE_NAME=root"
    echo "NODE_UNIT=neard"
    echo "NODE_MANAGED=0"
    echo "NODE_USER=root"
    echo "NODE_HOME=/root/.near"
    echo "NODE_POOL=$(jq -r '.account_id // "-"' /root/.near/validator_key.json 2>/dev/null | tr -cd 'a-z0-9._-')"
    echo "NODE_NET=$(genesis_chain /root/.near | tr -cd 'a-z0-9._-')"   # grep, not jq: mainnet genesis is huge
    echo "NODE_P2P=$(port_of "$(jq -r '.network.addr' "$cfg")")"
    echo "NODE_RPC=$(port_of "$(jq -r '.rpc.addr' "$cfg")")"
  } > "$REG_DIR/root.env"
  echo "registered existing root node (neard.service, /root/.near) — monitored only, never modified"
}

port_busy() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }

alloc_ports() {   # prints "<p2p> <rpc>" — first pair not in registry and not listening
  local used i p r
  used=$(grep -hoE '^NODE_(P2P|RPC)=[0-9]+' "$REG_DIR"/*.env /dev/null | cut -d= -f2 || true)
  for i in $(seq 0 99); do
    p=$((P2P_BASE + i)); r=$((RPC_BASE + i))
    if grep -qxE "$p|$r" <<<"$used" || port_busy "$p" || port_busy "$r"; then continue; fi
    echo "$p $r"; return 0
  done
  die "no free port pair"
}

tune_config() {   # cfg user net p2p rpc — apply nearctl's settings to a node's config.json
  local cfg=$1 user=$2 net=$3 p2p=$4 rpc=$5 boot
  boot=$(fetch_boot_nodes "$(rpc_url_for "$net")" || true)
  [ -n "$boot" ] || echo "WARN: could not fetch boot nodes, keeping the ones in config"
  jq --arg p2p "0.0.0.0:$p2p" --arg rpc "127.0.0.1:$rpc" --arg boot "$boot" '
        .gc_num_epochs_to_keep = 3
      | .tracked_shards_config = "NoShards"
      | .network.addr = $p2p
      | .rpc.addr = $rpc
      | .rpc.prometheus_addr = null
      | if $boot != "" then .network.boot_nodes = $boot else . end' "$cfg" > "$cfg.tmp"
  mv "$cfg.tmp" "$cfg"
  chown "$user:$user" "$cfg"
}

fetch_boot_nodes() {
  curl -s -m 20 -X POST "$1" -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"network_info","params":[],"id":"dontcare"}' |
  jq -r '.result.active_peers as $l1 | .result.known_producers as $l2 | $l1[] as $p | $l2[]
         | select(.peer_id == $p.id) | "\(.peer_id)@\($p.addr)"' | paste -sd "," -
}

# ---------------------------------------------------------------- host setup / binary

cmd_setup() {
  need_root
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y git binutils-dev libcurl4-openssl-dev zlib1g-dev \
    libdw-dev libiberty-dev cmake gcc g++ python3 protobuf-compiler libssl-dev pkg-config clang llvm \
    tmux jq ccze rclone build-essential make curl wget unzip
  if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  fi
  # near CLIs: root already has them in ~/.cargo/bin (nearauto.sh); install only if missing,
  # then copy to /usr/local/bin so every node user can run them.
  if [ ! -x "$HOME/.cargo/bin/near" ]; then
    curl --proto '=https' --tlsv1.2 -LsSf https://github.com/near/near-cli-rs/releases/latest/download/near-cli-rs-installer.sh | sh
  fi
  if [ ! -x "$HOME/.cargo/bin/near-validator" ]; then
    curl --proto '=https' --tlsv1.2 -LsSf https://github.com/near-cli-rs/near-validator-cli-rs/releases/latest/download/near-validator-installer.sh | sh
  fi
  local b
  for b in near near-validator; do
    if [ -x "$HOME/.cargo/bin/$b" ]; then install -m 755 "$HOME/.cargo/bin/$b" "/usr/local/bin/$b"
    else echo "WARN: $b not found in ~/.cargo/bin"; fi
  done
  # sysctl: nearauto.sh already wrote /etc/sysctl.d/local.conf — nothing to do.

  install -d -m 755 "$REG_DIR" "$BIN_DIR"
  register_root_node

  cmd_install
  echo "setup done. Next: nearctl build <version> && nearctl use <version>"
}

cmd_install() {   # copy this script to /usr/local/bin/nearctl (use after every script update)
  need_root
  local self dst=/usr/local/bin/nearctl
  self=$(readlink -f "$0")
  if [ "$self" = "$dst" ]; then echo "already running $dst"; return 0; fi
  bash -n "$self" || die "$self has syntax errors (truncated upload?) — not installed"
  install -m 755 "$self" "$dst.tmp"
  mv -f "$dst.tmp" "$dst"
  echo "installed $dst ($(wc -l < "$dst") lines, md5 $(md5sum "$dst" | cut -c1-12))"
}

cmd_new_config() {   # regenerate config.json from the shared neard binary's defaults, then re-apply nearctl settings
  need_root
  load_node "${1:-}"
  [ "$NODE_MANAGED" = 1 ] || die "nearctl never modifies the root node's config"
  [ -x "$NEARD" ] || die "no shared neard yet: nearctl build <ver> && nearctl use <ver>"
  local cfg="$NODE_HOME/config.json" tmp bak=""
  tmp=$(mktemp -d /var/tmp/nearctl-config.XXXXXX)   # not /tmp: may be tmpfs, mainnet init can fetch a big genesis
  echo ">>> generating default config with $(readlink -f "$NEARD") (chain $NODE_NET)..."
  if ! "$NEARD" --home "$tmp" init --chain-id "$NODE_NET" >"$tmp.log" 2>&1 || [ ! -f "$tmp/config.json" ]; then
    tail -20 "$tmp.log" >&2
    rm -rf "${tmp:?}" "$tmp.log"
    die "neard init failed"
  fi
  if [ -f "$cfg" ]; then bak="$cfg.bak-$(date +%Y%m%d-%H%M%S)"; cp -p "$cfg" "$bak"; fi
  install -o "$NODE_USER" -g "$NODE_USER" -m 644 "$tmp/config.json" "$cfg"
  rm -rf "${tmp:?}" "$tmp.log"
  tune_config "$cfg" "$NODE_USER" "$NODE_NET" "$NODE_P2P" "$NODE_RPC"
  echo "$NODE_NAME: new config.json (keys, genesis, data untouched)${bak:+; old one saved as $bak}"
  echo "Apply: nearctl restart $NODE_NAME"
}

cmd_build() {
  need_root
  local ver=${1:-}
  [ -n "$ver" ] || die "usage: nearctl build <version>   (https://github.com/near/nearcore/releases)"
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
  [ -d "$SRC_DIR/.git" ] || git clone https://github.com/near/nearcore "$SRC_DIR"
  # same as the manual upgrade: git fetch && git checkout <ver> -f && make release
  # (re-running for an already built version is a fast no-op build)
  git -C "$SRC_DIR" fetch --tags --force
  git -C "$SRC_DIR" checkout -f "$ver"
  # Lowest CPU/IO priority: running validators must keep up while we compile.
  (cd "$SRC_DIR" && nice -n 19 ionice -c 3 make release)
  install -D -m 755 "$SRC_DIR/target/release/neard" "$BIN_DIR/neard-$ver"
  echo "built $ver: $("$BIN_DIR/neard-$ver" --version 2>/dev/null | head -1)"
  echo "  root node binary : $SRC_DIR/target/release/neard (applies on next restart of neard.service)"
  echo "  shared copy      : $BIN_DIR/neard-$ver"
}

cmd_use() {
  need_root
  local ver=${1:-}
  [ -x "$BIN_DIR/neard-$ver" ] || die "no build '$ver'. Available: $(cd "$BIN_DIR" && echo neard-* | sed 's/neard-//g')"
  ln -sfn "$BIN_DIR/neard-$ver" "$NEARD.tmp"
  mv -Tf "$NEARD.tmp" "$NEARD"       # atomic swap; running nodes keep their binary until restarted
  echo "shared neard -> $ver (nearctl nodes pick it up on restart)"
}

# ---------------------------------------------------------------- node lifecycle

cmd_add() {
  need_root
  local name=${1:-} pool=${2:-} net=${3:-mainnet}
  [ -n "$name" ] && [ -n "$pool" ] || die "usage: nearctl add <name> <pool_id> [mainnet|testnet|<chain-id>]"
  [[ $name =~ ^[a-z0-9][a-z0-9-]{0,20}$ ]] || die "name: a-z 0-9 '-' only, max 21 chars"
  [ "$name" != root ] || die "'root' is reserved for the existing root node"
  [[ $pool =~ ^[a-z0-9._-]+$ ]] || die "invalid pool id '$pool'"
  [[ $net =~ ^[a-z0-9._-]+$ ]] || die "invalid network '$net'"
  [[ $MEM_MAX =~ ^([0-9]+[KMGT]?|infinity)$ ]] || die "invalid MEM_MAX '$MEM_MAX'"
  [ ! -e "$REG_DIR/$name.env" ] || die "node '$name' already exists"
  [ -x "$NEARD" ] || die "no shared neard yet: nearctl build <ver> && nearctl use <ver>"

  local user="near-$name" home="/home/near-$name"
  local dir="$home/.near" unit="neard-$name" ports p2p rpc
  [ ! -e "$dir" ] || die "$dir already exists"
  install -d -m 755 "$REG_DIR"
  register_root_node     # reserve the root node's ports even if it happens to be stopped
  ports=$(alloc_ports); p2p=${ports% *}; rpc=${ports#* }

  id "$user" >/dev/null 2>&1 || useradd -m -d "$home" -s /bin/bash "$user"
  runuser -u "$user" -- "$NEARD" --home "$dir" init --chain-id "$net" --account-id "$pool"
  tune_config "$dir/config.json" "$user" "$net" "$p2p" "$rpc"

  grep -qs '^export NEAR_ENV=' "$home/.bashrc" || echo "export NEAR_ENV=$net" >> "$home/.bashrc"
  chown "$user:$user" "$home/.bashrc"

  cat > "$REG_DIR/$name.env" <<EOF
NODE_NAME=$name
NODE_UNIT=$unit
NODE_MANAGED=1
NODE_USER=$user
NODE_HOME=$dir
NODE_POOL=$pool
NODE_NET=$net
NODE_P2P=$p2p
NODE_RPC=$rpc
EOF

  cat > "/etc/systemd/system/$unit.service" <<EOF
[Unit]
Description=NEAR node $name ($pool, $net)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$user
Group=$user
WorkingDirectory=$dir
ExecStart=$NEARD --home $dir run
Restart=on-failure
RestartSec=30
KillSignal=SIGINT
TimeoutStopSec=120
KillMode=mixed
LimitNOFILE=65535
MemoryMax=$MEM_MAX
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$unit"

  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow "$p2p/tcp" comment "$unit"
  fi

  cat <<EOF

=== node '$name' ready ===
user      : $user   (sudo -iu $user  -> near login / near-validator, own credentials)
home      : $dir
service   : $unit   (P2P $p2p public, RPC 127.0.0.1:$rpc)
validator : $(jq -r '.account_id + "  " + .public_key' "$dir/validator_key.json" 2>/dev/null || echo "no validator_key.json")
Next      : open TCP $p2p in cloud firewall, then: nearctl start $name
EOF
}

cmd_remove() {
  need_root
  load_node "${1:-}"
  [ "$NODE_MANAGED" = 1 ] || die "'$NODE_NAME' is the existing root node; nearctl never removes it"
  local a
  read -rp "Stop and unregister '$NODE_NAME' (unit + registry). User and data in $NODE_HOME are KEPT. Continue? [y/N] " a
  [ "$a" = y ] || exit 1
  systemctl disable --now "$NODE_UNIT" || true
  rm -f "/etc/systemd/system/$NODE_UNIT.service" "$REG_DIR/$NODE_NAME.env"
  systemctl daemon-reload
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw delete allow "$NODE_P2P/tcp" || true
  fi
  echo "removed. To delete data too: userdel -r $NODE_USER"
}

wait_ready() {   # name -> 0 once RPC answers syncing=false
  local deadline=$((SECONDS + READY_TIMEOUT)) s
  load_node "$1"
  while [ "$SECONDS" -lt "$deadline" ]; do
    s=$(curl -s -m 2 "http://127.0.0.1:$NODE_RPC/status" | jq -r '.sync_info.syncing' 2>/dev/null || true)
    if [ "$s" = false ]; then echo "    $1 synced"; return 0; fi
    sleep 5
  done
  return 1
}

rolling_restart() {   # $1=with-root to include the root node; one at a time, so nodes never all miss endorsements together
  local n with_root=${1:-} order
  order=$(if [ -f "$REG_DIR/root.env" ]; then echo root; fi; node_names | grep -vx root || true)
  for n in $order; do
    load_node "$n"
    if [ "$NODE_MANAGED" != 1 ] && [ "$with_root" != with-root ]; then
      echo ">>> $n: root node, not touched"; continue
    fi
    systemctl is-active -q "$NODE_UNIT" || { echo ">>> $n stopped, skip"; continue; }
    echo ">>> restarting $n"
    systemctl restart "$NODE_UNIT"
    sleep 10
    wait_ready "$n" || die "$n not synced after ${READY_TIMEOUT}s — rollout halted, check: nearctl logs $n"
  done
}

cmd_ctl() {
  need_root
  local action=$1 target=${2:-} units=() n
  [ -n "$target" ] || die "usage: nearctl $action <name|all>"
  if [ "$target" = all ]; then
    # "all" = nodes created by nearctl; the root node is only ever controlled by name
    [ "$action" = restart ] && { rolling_restart; return; }
    for n in $(node_names); do
      load_node "$n"
      if [ "$NODE_MANAGED" = 1 ]; then units+=("$NODE_UNIT"); fi
    done
    [ ${#units[@]} -gt 0 ] || die "no nearctl nodes"
  else
    load_node "$target"; units=("$NODE_UNIT")
  fi
  systemctl "$action" "${units[@]}"
}

cmd_upgrade() {
  local ver=${1:-}
  [ -n "$ver" ] || die "usage: nearctl upgrade <version>"
  register_root_node
  cmd_build "$ver"
  cmd_use "$ver"
  # root node's binary on disk was just rebuilt too, so restart it (first) along with the others
  rolling_restart with-root
  echo "all running nodes (root + nearctl) on $ver"
}

show_logs() {   # unit
  if command -v ccze >/dev/null; then journalctl -u "$1" -n 200 -f | ccze -A
  else journalctl -u "$1" -n 200 -f; fi
}

cmd_logs() { load_node "${1:-}"; show_logs "$NODE_UNIT"; }

cmd_boot_nodes() {   # refresh network.boot_nodes from the network's public RPC
  need_root
  load_node "${1:-}"
  [ "$NODE_MANAGED" = 1 ] || die "nearctl never modifies the root node's config"
  local cfg="$NODE_HOME/config.json" boot
  boot=$(fetch_boot_nodes "$(rpc_url_for "$NODE_NET")" || true)
  [ -n "$boot" ] || die "could not fetch boot nodes"
  jq --arg boot "$boot" '.network.boot_nodes = $boot' "$cfg" > "$cfg.tmp"
  mv "$cfg.tmp" "$cfg"
  chown "$NODE_USER:$NODE_USER" "$cfg"
  echo "$NODE_NAME: $(tr ',' '\n' <<<"$boot" | wc -l) boot nodes set. Apply: nearctl restart $NODE_NAME"
}

cmd_fix_ports() {   # rewrite config.json ports from the registry (e.g. after copying another node's config)
  need_root
  load_node "${1:-}"
  [ "$NODE_MANAGED" = 1 ] || die "nearctl never modifies the root node's config"
  local cfg="$NODE_HOME/config.json"
  jq --arg p2p "0.0.0.0:$NODE_P2P" --arg rpc "127.0.0.1:$NODE_RPC" \
    '.network.addr = $p2p | .rpc.addr = $rpc | .rpc.prometheus_addr = null' "$cfg" > "$cfg.tmp"
  mv "$cfg.tmp" "$cfg"
  chown "$NODE_USER:$NODE_USER" "$cfg"
  echo "$NODE_NAME: P2P 0.0.0.0:$NODE_P2P, RPC+metrics 127.0.0.1:$NODE_RPC. Apply: nearctl restart $NODE_NAME"
}

D_FAIL=0 D_WARN=0
d_ok()   { printf '  %sOK%s    %s\n' "$C_OK" "$C_0" "$*"; }
d_warn() { printf '  %sWARN%s  %s\n' "$C_WARN" "$C_0" "$*"; D_WARN=$((D_WARN + 1)); }
d_fail() { printf '  %sFAIL%s  %s\n' "$C_BAD" "$C_0" "$*"; D_FAIL=$((D_FAIL + 1)); }

genesis_chain() { grep -m1 -o '"chain_id": *"[^"]*"' "$1/genesis.json" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/'; }

cmd_doctor() {   # read-only health/consistency check of host + every node; exit 1 if any FAIL
  need_root; set +e
  local n cfg c_p2p c_rpc c_prom rpc_host p f perm key acct chain state enabled restarts exe pid lpid st
  local avail use ufw_on=0 units=" " u args
  local -A port_owner vkey_owner nkey_owner

  echo "${C_B}host${C_0}"
  if [ -x "$NEARD" ]; then d_ok "shared neard -> $(readlink -f "$NEARD")"
  else d_warn "no shared neard yet (nearctl build <ver> && nearctl use <ver>)"; fi
  avail=$(awk '/^MemAvailable/ { printf "%d", $2 / 1048576 }' /proc/meminfo)
  if [ "$avail" -ge 8 ]; then d_ok "RAM available ${avail}G"; else d_warn "RAM available only ${avail}G"; fi
  use=$(df --output=pcent /home | tail -1 | tr -dc 0-9)
  if [ "$use" -lt 85 ]; then d_ok "/home disk ${use}% used"; else d_warn "/home disk ${use}% used"; fi
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then ufw_on=1; fi

  for n in $(node_names); do
    load_node "$n"
    units+="$NODE_UNIT.service "
    cfg="$NODE_HOME/config.json"
    echo; echo "${C_B}$n${C_0}  ($NODE_UNIT, $NODE_HOME)"

    # --- files & ownership
    if [ ! -d "$NODE_HOME" ]; then d_fail "home dir missing"; continue; fi
    if ! jq -e . "$cfg" >/dev/null 2>&1; then d_fail "config.json missing or invalid JSON"; continue; fi
    if [ "$NODE_MANAGED" = 1 ]; then
      u=$(find "$NODE_HOME" -xdev ! -user "$NODE_USER" -print -quit 2>/dev/null)
      if [ -z "$u" ]; then d_ok "all files owned by $NODE_USER"
      else d_fail "file not owned by $NODE_USER: $u  -> chown -R $NODE_USER: $NODE_HOME"; fi
    fi

    # --- ports: registry vs config, collisions between nodes
    c_p2p=$(port_of "$(jq -r '.network.addr // ""' "$cfg")")
    c_rpc=$(port_of "$(jq -r '.rpc.addr // ""' "$cfg")")
    c_prom=$(port_of "$(jq -r '.rpc.prometheus_addr // ""' "$cfg")")
    if [ "$c_p2p" = "$NODE_P2P" ] && [ "$c_rpc" = "$NODE_RPC" ]; then
      d_ok "config ports match registry (P2P $c_p2p, RPC $c_rpc)"
    elif [ "$NODE_MANAGED" = 1 ]; then
      d_fail "config P2P $c_p2p / RPC $c_rpc != registry $NODE_P2P / $NODE_RPC (copied config?) -> nearctl fix-ports $n"
    else
      d_warn "config P2P $c_p2p / RPC $c_rpc != registry $NODE_P2P / $NODE_RPC (rm $REG_DIR/root.env; nearctl setup)"
    fi
    for p in $c_p2p $c_rpc $c_prom; do
      if [ -n "${port_owner[$p]:-}" ]; then d_fail "port $p also configured on node '${port_owner[$p]}'"
      else port_owner[$p]=$n; fi
    done
    p=$(jq -r '.network.boot_nodes // ""' "$cfg" | tr ',' '\n' | grep -c @)
    if [ "$p" -gt 0 ]; then d_ok "$p boot nodes in config"
    elif [ "$NODE_MANAGED" = 1 ]; then d_warn "no boot nodes in config -> nearctl boot-nodes $n"
    else d_warn "no boot nodes in config"; fi
    rpc_host=$(jq -r '.rpc.addr // ""' "$cfg"); rpc_host=${rpc_host%:*}
    if [ "$NODE_MANAGED" = 1 ] && [ "$rpc_host" != 127.0.0.1 ]; then d_warn "RPC bound to $rpc_host (public)"; fi

    # --- keys: present, private, unique across nodes, match pool / network
    for f in validator_key.json node_key.json; do
      if [ ! -f "$NODE_HOME/$f" ]; then
        d_fail "$f missing"; continue
      fi
      perm=$(stat -c %a "$NODE_HOME/$f")
      [ "$perm" = 600 ] || d_warn "$f mode $perm -> chmod 600 $NODE_HOME/$f"
      key=$(jq -r '.public_key // ""' "$NODE_HOME/$f")
      if [ "$f" = validator_key.json ]; then
        if [ -n "${vkey_owner[$key]:-}" ]; then
          d_fail "SAME validator key as node '${vkey_owner[$key]}' — one key must never run on two nodes"
        else vkey_owner[$key]=$n; fi
        acct=$(jq -r '.account_id // ""' "$NODE_HOME/$f")
        if [ "$NODE_POOL" = "-" ] || [ "$acct" = "$NODE_POOL" ]; then d_ok "validator key: $acct"
        else d_warn "validator_key account '$acct' != registry pool '$NODE_POOL'"; fi
      else
        if [ -n "${nkey_owner[$key]:-}" ]; then
          d_fail "SAME node_key as node '${nkey_owner[$key]}' (copied?) — peers will drop one of them"
        else nkey_owner[$key]=$n; fi
      fi
    done
    chain=$(genesis_chain "$NODE_HOME")
    if [ "$NODE_NET" = "-" ] || [ "$chain" = "$NODE_NET" ]; then d_ok "genesis chain_id: ${chain:-?}"
    else d_fail "genesis chain_id '$chain' != registry network '$NODE_NET'"; fi

    # --- service
    if ! systemctl cat "$NODE_UNIT" >/dev/null 2>&1; then d_fail "unit $NODE_UNIT not found"; continue; fi
    state=$(systemctl show "$NODE_UNIT" -p ActiveState --value)
    enabled=$(systemctl is-enabled "$NODE_UNIT" 2>/dev/null)
    restarts=$(systemctl show "$NODE_UNIT" -p NRestarts --value)
    exe=$(systemctl show "$NODE_UNIT" -p ExecStart --value | sed -n 's/.*path=\([^ ;]*\).*/\1/p')
    pid=$(systemctl show "$NODE_UNIT" -p MainPID --value)
    if [ -x "$exe" ]; then d_ok "binary $exe"; else d_fail "ExecStart binary missing: $exe"; fi
    [ "$enabled" = enabled ] || d_warn "unit is $enabled (won't start at boot) -> systemctl enable $NODE_UNIT"
    if [ "$state" = active ]; then
      d_ok "service active (pid $pid)"
      [ "${restarts:-0}" -eq 0 ] || d_warn "service restarted $restarts times since last start — check: nearctl logs $n"
    else
      d_fail "service $state"
      journalctl -u "$NODE_UNIT" -n 300 --no-pager -o cat 2>/dev/null |
        grep -E 'ERROR|panicked|error|Error' | tail -3 | sed 's/^/          /'
    fi

    # --- who really listens on this node's P2P port
    if [ -n "$c_p2p" ]; then
      lpid=$(ss -Hltnp "sport = :$c_p2p" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)
      if [ -z "$lpid" ]; then
        [ "$state" != active ] || d_warn "nothing listening on P2P $c_p2p yet"
      elif [ "$lpid" = "$pid" ]; then d_ok "listening on P2P $c_p2p"
      else
        d_fail "P2P port $c_p2p held by pid $lpid ($(ps -o unit=,args= -p "$lpid" | cut -c1-80)), not by this node"
      fi
      if [ "$ufw_on" = 1 ]; then
        if ufw status | grep -qE "^$c_p2p(/tcp)? +ALLOW"; then d_ok "ufw allows $c_p2p/tcp"
        else d_warn "ufw active but $c_p2p/tcp not allowed -> ufw allow $c_p2p/tcp"; fi
      fi
    fi

    # --- sync
    if [ "$state" = active ] && [ -n "$c_rpc" ]; then
      st=$(curl -s -m 2 "http://127.0.0.1:$c_rpc/status" |
           jq -r '"\(.sync_info.syncing) \(.sync_info.latest_block_height) \(.version.version)"' 2>/dev/null)
      case $st in
        false*) d_ok "synced, height $(cut -d' ' -f2 <<<"$st"), neard $(cut -d' ' -f3 <<<"$st")" ;;
        true*)  d_warn "still syncing, height $(cut -d' ' -f2 <<<"$st")" ;;
        *)      d_warn "RPC 127.0.0.1:$c_rpc not answering (starting up?)" ;;
      esac
      p=$(curl -s -m 2 -X POST "http://127.0.0.1:$c_rpc" -H 'Content-Type: application/json' \
          -d '{"jsonrpc":"2.0","method":"network_info","params":[],"id":"x"}' | jq -r '.result.num_active_peers // empty' 2>/dev/null)
      if [ -z "$p" ]; then :
      elif [ "$p" -eq 0 ]; then
        d_fail "0 peers -> duplicate node_key with another node? stale boot nodes (nearctl boot-nodes $n)? outbound firewall?"
      elif [ "$p" -lt 5 ]; then d_warn "only $p peers"
      else d_ok "$p peers"; fi
    fi
  done

  # --- neard processes not started by any registered unit (manual runs = double-sign risk)
  echo; echo "${C_B}processes${C_0}"
  local stray=0
  for pid in $(pgrep -x neard); do
    u=$(ps -o unit= -p "$pid" | tr -d ' ')
    case $units in *" $u "*) ;; *)
      args=$(ps -o args= -p "$pid" | cut -c1-100)
      d_fail "neard pid $pid not from a registered unit (unit=$u): $args"; stray=1 ;;
    esac
  done
  [ "$stray" = 1 ] || d_ok "every running neard belongs to a registered node"

  echo
  if [ "$D_FAIL" -gt 0 ]; then echo "${C_BAD}$D_FAIL FAIL${C_0}, $D_WARN WARN"; return 1; fi
  echo "${C_OK}no failures${C_0}, $D_WARN WARN"
}

cmd_info() {
  need_root
  load_node "${1:-}"
  cat "$REG_DIR/$NODE_NAME.env"
  echo "VALIDATOR_KEY=$(jq -r '.account_id + " " + .public_key' "$NODE_HOME/validator_key.json" 2>/dev/null || echo n/a)"
  echo "NODE_KEY=$(jq -r .public_key "$NODE_HOME/node_key.json" 2>/dev/null || echo n/a)"
  curl -s -m 2 "http://127.0.0.1:$NODE_RPC/status" |
    jq '{version: .version.version, height: .sync_info.latest_block_height,
         syncing: .sync_info.syncing, validator: .validator_account_id}' 2>/dev/null ||
    echo "rpc: not reachable"
}

# ---------------------------------------------------------------- dashboard

declare -A CPU_PREV CPU_TS CPU_PID DISK DISK_TS
CLK_TCK=$(getconf CLK_TCK)
F=''   # rendered frame

collect() {   # sets R_STATE R_CPU R_RAM R_DISK R_HEIGHT R_SYNC for node $1; no subshell (caches persist)
  local n=$1 pid ticks now st
  load_node "$n"
  R_STATE=$(systemctl show "$NODE_UNIT" -p ActiveState --value 2>/dev/null)
  pid=$(systemctl show "$NODE_UNIT" -p MainPID --value 2>/dev/null)
  R_CPU='-' R_RAM='-' R_HEIGHT='-' R_SYNC='-'
  if [ "${pid:-0}" != 0 ] && [ -r "/proc/$pid/stat" ]; then
    ticks=$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null)
    now=$(date +%s%N)
    if [ -n "$ticks" ]; then
      if [ "${CPU_PID[$n]:-}" = "$pid" ]; then
        R_CPU=$(awk -v d=$((ticks - CPU_PREV[$n])) -v ns=$((now - CPU_TS[$n])) -v hz="$CLK_TCK" \
          'BEGIN { printf "%.0f%%", d / hz / (ns / 1e9) * 100 }')
      fi
      CPU_PREV[$n]=$ticks CPU_TS[$n]=$now CPU_PID[$n]=$pid
    fi
    R_RAM=$(awk '/^VmRSS/ { printf "%.1fG", $2 / 1048576 }' "/proc/$pid/status" 2>/dev/null)
    st=$(curl -s -m 1 "http://127.0.0.1:$NODE_RPC/status" 2>/dev/null |
         jq -r '"\(.sync_info.latest_block_height) \(.sync_info.syncing)"' 2>/dev/null)
    if [ -n "$st" ]; then
      R_HEIGHT=${st% *}
      if [ "${st#* }" = false ]; then R_SYNC=ok; else R_SYNC=SYNCING; fi
    fi
  fi
  # du over a big RocksDB dir is slow: refresh every 5 min
  if [ $((SECONDS - ${DISK_TS[$n]:--999})) -ge 300 ]; then
    DISK[$n]=$(du -sh "$NODE_HOME" 2>/dev/null | cut -f1)
    DISK_TS[$n]=$SECONDS
  fi
  R_DISK=${DISK[$n]:-?}
}

build_frame() {   # $1 = selected row index (-1 none); result in $F
  local sel=$1 i=0 n sc mark state
  F="${C_B}NEAR nodes @ $(cat /proc/sys/kernel/hostname)${C_0}  shared neard: $(basename "$(readlink -f "$NEARD" 2>/dev/null || echo none)")"
  F+="  load: $(cut -d' ' -f1-3 /proc/loadavg)  cores: $(nproc)$EL"$'\n'
  F+="$(free -g | awk '/^Mem:/ { printf "RAM %sG used / %sG (avail %sG)", $3, $2, $7 }')"
  F+="$(df -h /home | awk 'NR==2 { printf "   Disk /home %s used / %s (free %s)", $3, $2, $4 }')$EL"$'\n'$EL$'\n'
  F+="$(printf '  %-14s %-10s %6s %7s %7s %6s %5s %11s %-8s' NAME STATE CPU RAM DISK P2P RPC HEIGHT SYNC)$EL"$'\n'
  for n in "${NODES[@]}"; do
    collect "$n"
    case $R_STATE in active) sc=$C_OK ;; failed) sc=$C_BAD ;; *) sc=$C_WARN ;; esac
    mark=' '; [ "$i" -eq "$sel" ] && mark='>'
    state=$(printf '%-10s' "$R_STATE")
    F+="$(printf '%s %-14s ' "$mark" "$n")${sc}${state}${C_0}"
    F+="$(printf ' %6s %7s %7s %6s %5s %11s %-8s' "$R_CPU" "$R_RAM" "$R_DISK" "$NODE_P2P" "$NODE_RPC" "$R_HEIGHT" "$R_SYNC")$EL"$'\n'
    F+="${C_DIM}    pool=$NODE_POOL  user=$NODE_USER  unit=$NODE_UNIT  path=$NODE_HOME${C_0}$EL"$'\n'
    i=$((i + 1))
  done
  [ ${#NODES[@]} -gt 0 ] || F+="  (no nodes — nearctl add <name> <pool_id>)$EL"$'\n'
}

cmd_list() {
  need_root; set +e
  mapfile -t NODES < <(node_names)
  build_frame -1          # first pass primes CPU counters
  sleep 1
  build_frame -1
  printf '%s' "$F"
}

tui_action() {
  local key=$1 n=$2 verb a
  case $key in s) verb=start ;; x) verb=stop ;; r) verb=restart ;; esac
  load_node "$n"
  printf '\e[2J\e[H'; tput cnorm
  [ "$NODE_MANAGED" = 1 ] || echo "${C_WARN}!! '$n' is your existing ROOT validator (neard.service)${C_0}"
  read -rp "$verb $NODE_UNIT ? [y/N] " a
  if [ "$a" = y ]; then systemctl "$verb" "$NODE_UNIT" && echo "done"; sleep 1; fi
  tput civis; printf '\e[2J'
}

cmd_tui() {
  need_root; set +e
  local sel=0 key rest n
  EL=$'\e[K'
  tput civis
  trap 'tput cnorm; printf "\e[0m\n"' EXIT
  trap ':' INT      # Ctrl-C only closes the log view; 'q' quits
  printf '\e[2J'
  while :; do
    mapfile -t NODES < <(node_names)
    if [ "$sel" -ge "${#NODES[@]}" ]; then sel=$(( ${#NODES[@]} > 0 ? ${#NODES[@]} - 1 : 0 )); fi
    build_frame "$sel"
    F+="$EL"$'\n'"${C_DIM}↑/↓ j/k select   s start   x stop   r restart   l logs   i info   q quit   (refresh 3s, disk 5m)${C_0}$EL"
    printf '\e[H%s\e[J' "$F"
    key=''
    IFS= read -rsn1 -t 3 key
    if [ "$key" = $'\e' ]; then IFS= read -rsn2 -t 0.05 rest; key+=$rest; fi
    n=${NODES[$sel]:-}
    case $key in
      q) break ;;
      $'\e[A'|k) [ "$sel" -gt 0 ] && sel=$((sel - 1)) ;;
      $'\e[B'|j) [ "$sel" -lt $(( ${#NODES[@]} - 1 )) ] && sel=$((sel + 1)) ;;
      s|x|r) [ -n "$n" ] && tui_action "$key" "$n" ;;
      l) if [ -n "$n" ]; then
           load_node "$n"
           printf '\e[2J\e[H'; tput cnorm; echo "$NODE_UNIT logs — Ctrl-C to return"
           show_logs "$NODE_UNIT"; tput civis; printf '\e[2J'
         fi ;;
      i) if [ -n "$n" ]; then
           printf '\e[2J\e[H'; ( cmd_info "$n" ); read -rsn1 -p $'\n[any key]'; printf '\e[2J'
         fi ;;
    esac
  done
}

usage() {
  cat <<'EOF'
nearctl — extra NEAR nodes on one host next to the root node (no Docker, one shared neard binary)

  setup                              first time: deps, register root node (read-only), then install
  install                            copy this script to /usr/local/bin/nearctl (after each script update)
  build <version>                    compile once in /root/nearcore, copy to /usr/local/lib/neard/neard-<version>
  use <version>                      point shared /usr/local/bin/neard at that build
  upgrade <version>                  build + use + rolling restart of ALL nodes (root first), waits for sync
  add <name> <pool_id> [network]     new node: user near-<name>, home /home/near-<name>/.near, unit neard-<name>
  remove <name>                      stop + unregister (keeps user and data); refuses the root node
  start|stop|restart <name|all>      "all" = nearctl nodes only; restart all = rolling
  logs <name>                        follow journal
  info <name>                        ports, keys, sync status
  doctor                             read-only check: ports, keys, ownership, service, sync, stray neard processes
  new-config <name>                  fresh config.json from shared neard defaults + nearctl settings (old one backed up)
  fix-ports <name>                   reset a node's config.json ports from the registry (after copying a config)
  boot-nodes <name>                  refresh a node's boot_nodes from the public RPC
  list                               one-shot table
  tui                                interactive dashboard (default)

Env: MEM_MAX per-node memory cap (default 16G), RPC_URL for custom networks
EOF
}

case ${1:-tui} in
  setup)   cmd_setup ;;
  install) cmd_install ;;
  new-config) cmd_new_config "${2:-}" ;;
  build)   cmd_build "${2:-}" ;;
  use)     cmd_use "${2:-}" ;;
  upgrade) need_root; cmd_upgrade "${2:-}" ;;
  add)     cmd_add "${2:-}" "${3:-}" "${4:-mainnet}" ;;
  remove)  cmd_remove "${2:-}" ;;
  start|stop|restart) cmd_ctl "$1" "${2:-}" ;;
  logs)    cmd_logs "${2:-}" ;;
  info)    cmd_info "${2:-}" ;;
  doctor)  cmd_doctor ;;
  fix-ports) cmd_fix_ports "${2:-}" ;;
  boot-nodes) cmd_boot_nodes "${2:-}" ;;
  list)    cmd_list ;;
  tui)     cmd_tui ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
