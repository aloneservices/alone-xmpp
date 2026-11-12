#!/bin/bash
set -euo pipefail
trap 'echo "alone-chat.sh failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# TODO add ra.pe once its in this Cloudflare account
DOMAINS=(alo.ne e.rip afra.id sexu.al deni.al)
PRIMARY=alo.ne
LEGAL_EMAIL=legal@alo.ne
LEGAL_URL=https://legal.alo.ne
HOSTS_A=(chat irc upload conference proxy turn legal check)
CERT_NAMES="alo.ne conference.alo.ne upload.alo.ne chat.alo.ne irc.alo.ne proxy.alo.ne turn.alo.ne legal.alo.ne check.alo.ne e.rip afra.id sexu.al deni.al"
WG_CHAT_IP=10.20.0.2
WG_ORIGIN_IP=10.20.0.1
STATE=/root/alone-chat.env
MB_REPO=https://github.com/matterbridge-org/matterbridge.git

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mxx %s\033[0m\n' "$*"; exit 1; }
gen() { local s; s=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < <(head -c 4096 /dev/urandom)); printf '%s' "${s:0:${1:-40}}"; }
ask() { local var=$1 prompt=$2 def=${3:-}; local val; read -rp "$prompt${def:+ [$def]}: " val; printf -v "$var" '%s' "${val:-$def}"; }
ask_secret() { local var=$1 prompt=$2; local val; read -rsp "$prompt: " val; echo; printf -v "$var" '%s' "$val"; }
save() { grep -v "^$1=" "$STATE" > "$STATE.tmp" 2>/dev/null || true; printf '%s=%q\n' "$1" "$2" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; chmod 600 "$STATE"; }

[ "$(id -u)" = 0 ] || die "Run as root"
. /etc/os-release
[ "${VERSION_ID:-}" = 13 ] || warn "This script targets Debian 13, found ${PRETTY_NAME:-unknown}"
touch "$STATE"; chmod 600 "$STATE"
# shellcheck disable=SC1090
. "$STATE"

hint() { printf '\033[0;37m%s\033[0m\n' "$@"; }

say "Questions (Enter keeps the saved value; leave bridge tokens empty to skip that platform)"
if [ -z "${CF_TOKEN:-}" ]; then
  hint "Cloudflare: dash.cloudflare.com > My Profile > API Tokens > Create Token > template 'Edit zone DNS'." \
       "  Add a second permission row: Zone > Zone > Read (needed to look zones up by name)." \
       "  Zone Resources: Include > Specific zone, add all six: ${DOMAINS[*]}"
  ask_secret CF_TOKEN "Cloudflare API token"
fi
ask LE_EMAIL "Let's Encrypt email (expiry notices)" "${LE_EMAIL:-}"
if [ -z "${ORIGIN_WG_PUB:-}" ]; then
  hint "On the DASHBOARD server, run this and paste the line it prints:" \
       "  apt-get install -y wireguard && umask 077 && [ -f /etc/wireguard/wgchat.key ] || wg genkey > /etc/wireguard/wgchat.key; wg pubkey < /etc/wireguard/wgchat.key" \
       "  (a new key just for the chat link; your existing wg0 to the mail servers stays as it is)" \
       "  (leave empty to finish the rest now and re-run this script later with the key)"
fi
ask ORIGIN_WG_PUB "Dashboard server WireGuard public key" "${ORIGIN_WG_PUB:-}"
ask BACKEND_URL "Backend URL over WireGuard" "${BACKEND_URL:-http://$WG_ORIGIN_IP:8088}"
if [ -z "${BRIDGE_PASS:-}" ]; then
  hint "Bridge account: register a dashboard user named 'bridge', sign in as it, open Chat in the sidebar," \
       "  tick every address, and activate chat with a long random chat password. Paste that chat password here."
  ask_secret BRIDGE_PASS "Chat password of the 'bridge' account"
fi
if [ -z "${DISCORD_TOKEN:-}" ]; then
  hint "Discord (optional): discord.com/developers/applications > New Application > Bot > Reset Token, copy it." \
       "  On that Bot page turn on 'Message Content Intent'. Invite it with OAuth2 > URL Generator, scope 'bot'," \
       "  permissions: View Channels, Send Messages, Read Message History, Manage Webhooks, Manage Messages."
fi
ask DISCORD_TOKEN "Discord bridge bot token" "${DISCORD_TOKEN:-}"
if [ -n "$DISCORD_TOKEN" ]; then
  hint "IDs: Discord Settings > Advanced > Developer Mode on, then right-click the server or channel > Copy ID." \
       "  Server ID: right-click the server icon in the left bar > Copy Server ID (not your own user ID)." \
       "  Webhook: channel settings > Integrations > Webhooks > New Webhook > Copy Webhook URL (one per channel)."
  ask DISCORD_GUILD "Discord server ID" "${DISCORD_GUILD:-}"
  ask DISCORD_GENERAL "Discord #general channel ID" "${DISCORD_GENERAL:-}"
  ask DISCORD_GENERAL_HOOK "Discord #general webhook URL" "${DISCORD_GENERAL_HOOK:-}"
  ask DISCORD_SUGGESTIONS "Discord #suggestions channel ID" "${DISCORD_SUGGESTIONS:-}"
  ask DISCORD_SUGGESTIONS_HOOK "Discord #suggestions webhook URL" "${DISCORD_SUGGESTIONS_HOOK:-}"
  hint "Premium (optional): only bridge it to a channel your premium role alone can see. Leave empty to skip."
  ask DISCORD_PREMIUM "Discord #premium channel ID" "${DISCORD_PREMIUM:-}"
  ask DISCORD_PREMIUM_HOOK "Discord #premium webhook URL" "${DISCORD_PREMIUM_HOOK:-}"
fi
if [ -z "${TELEGRAM_TOKEN:-}" ]; then
  hint "Telegram (optional): message @BotFather, /newbot, copy the token. Then /setprivacy > your bot > Disable." \
       "  Add the bot to each group as an admin with only 'Delete messages' and 'Ban users'."
fi
ask TELEGRAM_TOKEN "Telegram bot token" "${TELEGRAM_TOKEN:-}"
if [ -n "$TELEGRAM_TOKEN" ]; then
  hint "Chat IDs: send any message in each group, then run:" \
       "  curl -s https://api.telegram.org/bot<TOKEN>/getUpdates | jq '.result[].message.chat | {id, title}'" \
       "  Group IDs start with -100."
  ask TELEGRAM_GENERAL "Telegram general chat ID" "${TELEGRAM_GENERAL:-}"
  ask TELEGRAM_SUGGESTIONS "Telegram suggestions chat ID" "${TELEGRAM_SUGGESTIONS:-}"
  hint "Premium (optional): only a private group premium users alone are in. Leave empty to skip."
  ask TELEGRAM_PREMIUM "Telegram premium chat ID" "${TELEGRAM_PREMIUM:-}"
fi
CHAT_SECRET=${CHAT_SECRET:-$(gen 48)}
ERGO_API_TOKEN=${ERGO_API_TOKEN:-$(gen 48)}
TURN_SECRET=${TURN_SECRET:-$(gen 48)}
SYNC_PASS=${SYNC_PASS:-$(gen 32)}
OPER_PASS=${OPER_PASS:-$(gen 32)}
for v in CF_TOKEN LE_EMAIL ORIGIN_WG_PUB BACKEND_URL BRIDGE_PASS DISCORD_TOKEN DISCORD_GUILD DISCORD_GENERAL DISCORD_GENERAL_HOOK \
  DISCORD_SUGGESTIONS DISCORD_SUGGESTIONS_HOOK DISCORD_PREMIUM DISCORD_PREMIUM_HOOK TELEGRAM_TOKEN TELEGRAM_GENERAL TELEGRAM_SUGGESTIONS \
  TELEGRAM_PREMIUM CHAT_SECRET ERGO_API_TOKEN \
  TURN_SECRET SYNC_PASS OPER_PASS; do save "$v" "${!v:-}"; done

IP4=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -v '^10\.20\.' | head -1)
IP6=$(ip -6 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -v '^f[cd]' | head -1)
[ -n "$IP4" ] || die "No public IPv4 found, an A record is required"
[ -n "$IP6" ] || warn "No public IPv6 found, AAAA records will be skipped"

say "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq prosody lua-dbi-sqlite3 luarocks mercurial nginx libnginx-mod-stream coturn wireguard nftables certbot \
  python3-certbot-dns-cloudflare jq curl git netcat-openbsd whois ca-certificates tar
prosodyctl about 2>/dev/null | grep -q 'Prosody 13' || warn "Prosody 13 expected, check: prosodyctl about"

say "Cloudflare DNS (adds missing records only)"
cf() { curl -fsS -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" "$@"; }
add_record() {
  local zone=$1 body=$2 name=$3 type=$4 match=$5 existing
  existing=$(cf "https://api.cloudflare.com/client/v4/zones/$zone/dns_records?type=$type&name=$name&per_page=100" | jq "[.result[] | select($match)] | length")
  if [ "$existing" != 0 ]; then echo "  exists, skipped: $type $name"; return; fi
  cf -X POST "https://api.cloudflare.com/client/v4/zones/$zone/dns_records" --data "$body" > /dev/null && echo "  added: $type $name"
}
for domain in "${DOMAINS[@]}"; do
  zone=$(cf "https://api.cloudflare.com/client/v4/zones?name=$domain" | jq -r '.result[0].id // empty') || zone=""
  [ -n "$zone" ] || { warn "Zone $domain not found for this token, skipped"; continue; }
  if [ "$domain" = "$PRIMARY" ]; then
    for host in "${HOSTS_A[@]}"; do
      add_record "$zone" "$(jq -nc --arg n "$host.$domain" --arg c "$IP4" '{type:"A",name:$n,content:$c,proxied:false,ttl:1}')" "$host.$domain" A true
      [ -z "$IP6" ] || add_record "$zone" "$(jq -nc --arg n "$host.$domain" --arg c "$IP6" '{type:"AAAA",name:$n,content:$c,proxied:false,ttl:1}')" "$host.$domain" AAAA true
    done
  fi
  srv() {
    add_record "$zone" "$(jq -nc --arg n "$1.$domain" --argjson p "$2" --argjson pr "$3" '{type:"SRV",name:$n,ttl:1,data:{priority:$pr,weight:5,port:$p,target:"chat.alo.ne"}}')" \
      "$1.$domain" SRV ".data.port == $2"
  }
  srv _xmpp-client._tcp 5222 5
  srv _xmpps-client._tcp 443 0
  srv _xmpps-client._tcp 5223 10
  srv _xmpp-server._tcp 5269 5
done

say "WireGuard"
if [ ! -f /etc/wireguard/wg0.key ]; then umask 077; wg genkey > /etc/wireguard/wg0.key; fi
WG_PUB=$(wg pubkey < /etc/wireguard/wg0.key)
{
  echo "[Interface]"
  echo "Address = $WG_CHAT_IP/24"
  echo "ListenPort = 51820"
  echo "PrivateKey = $(cat /etc/wireguard/wg0.key)"
  if [ -n "$ORIGIN_WG_PUB" ]; then
    echo; echo "[Peer]"; echo "PublicKey = $ORIGIN_WG_PUB"; echo "AllowedIPs = $WG_ORIGIN_IP/32"
  fi
} > /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf
systemctl enable -q wg-quick@wg0; systemctl restart wg-quick@wg0

say "Certificate (DNS-01, one certificate for every chat name)"
install -d -m 700 /root/.secrets
printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > /root/.secrets/cloudflare.ini; chmod 600 /root/.secrets/cloudflare.ini
cat > /usr/local/sbin/alone-chat-certs <<'EOF'
#!/bin/bash
set -e
live=/etc/letsencrypt/live/alone-chat
for name in alo.ne conference.alo.ne upload.alo.ne chat.alo.ne irc.alo.ne proxy.alo.ne turn.alo.ne e.rip afra.id sexu.al deni.al; do
  install -o root -g prosody -m 640 "$live/fullchain.pem" "/etc/prosody/certs/$name.crt"
  install -o root -g prosody -m 640 "$live/privkey.pem" "/etc/prosody/certs/$name.key"
done
install -d -o ergo -g ergo -m 700 /var/lib/ergo/tls
install -o ergo -g ergo -m 600 "$live/fullchain.pem" "$live/privkey.pem" /var/lib/ergo/tls/
install -d -o turnserver -g turnserver -m 700 /etc/coturn/tls
install -o turnserver -g turnserver -m 600 "$live/fullchain.pem" "$live/privkey.pem" /etc/coturn/tls/
systemctl reload prosody nginx 2>/dev/null || true
systemctl kill -s HUP ergo 2>/dev/null || true
systemctl restart coturn 2>/dev/null || true
EOF
chmod 755 /usr/local/sbin/alone-chat-certs
id ergo >/dev/null 2>&1 || useradd --system --home /var/lib/ergo --create-home --shell /usr/sbin/nologin ergo
cert_args=(); for n in $CERT_NAMES; do cert_args+=(-d "$n"); done
certbot certonly -n --agree-tos -m "$LE_EMAIL" --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  --dns-cloudflare-propagation-seconds 30 --cert-name alone-chat --expand "${cert_args[@]}" \
  --deploy-hook /usr/local/sbin/alone-chat-certs
/usr/local/sbin/alone-chat-certs

say "Prosody modules"
[ -d /opt/prosody-modules ] && hg -R /opt/prosody-modules pull -uq || hg clone -q https://hg.prosody.im/prosody-modules/ /opt/prosody-modules
install -d /usr/local/lib/prosody/modules
for m in muc_moderation muc_rate_limit; do
  [ -d "/opt/prosody-modules/mod_$m" ] && ln -sfn "/opt/prosody-modules/mod_$m/mod_$m.lua" "/usr/local/lib/prosody/modules/mod_$m.lua"
done

cat > /usr/local/lib/prosody/modules/mod_auth_alone.lua <<'EOF'
-- Dashboard auth
local http = require "net.http";
local async = require "util.async";
local json = require "util.json";
local base64 = require "util.encodings".base64;
local new_sasl = require "util.sasl".new;

local api = module:get_option_string("alone_api");
local secret = module:get_option_string("alone_secret");
local primary = module:get_option_string("alone_primary_domain", "alo.ne");
local host = module.host;
local provider = {};

local function valid(username)
	return type(username) == "string" and username:match("^[a-z0-9]+$") ~= nil;
end

local function call(method, path, body)
	local response = async.wait_for(http.request(api .. path, {
		method = method;
		headers = { ["Content-Type"] = "application/json"; ["X-Chat-Secret"] = secret };
		body = body and json.encode(body) or nil;
	}));
	if not response then return nil; end
	return response.code, response.body;
end

function provider.test_password(username, password)
	if host ~= primary or not valid(username) then return nil, "not authorized"; end
	return call("POST", "/token", { username = username; token = password }) == 200;
end

function provider.user_exists(username)
	if not valid(username) then return nil; end
	return call("GET", "/users/" .. username .. "?domain=" .. host) == 200;
end

function provider.get_password() return nil, "Not supported"; end
function provider.set_password() return nil, "Change your chat password on the dashboard"; end
function provider.create_user() return nil, "Accounts are created on the dashboard"; end
function provider.delete_user() return nil, "Not supported"; end
function provider.users() return function() return nil; end; end

function provider.get_sasl_handler()
	return new_sasl(host, {
		plain_test = function(_, username, password)
			return provider.test_password(username, password), true;
		end;
		scram_sha_256 = function(_, username)
			if not valid(username) then return; end
			local code, body = call("GET", "/scram/" .. username .. "?domain=" .. host);
			if code ~= 200 then return; end
			local data = json.decode(body);
			if not data then return; end
			return base64.decode(data.storedKey), base64.decode(data.serverKey), data.iterations, base64.decode(data.salt), true;
		end;
	});
end

module:provides("auth", provider);

local function kick_banned()
	http.request(api .. "/roles", { headers = { ["X-Chat-Secret"] = secret } }, function(body, code)
		if code ~= 200 then return; end
		local roles = json.decode(body);
		if not roles then return; end
		local host_sessions = prosody.hosts[host] and prosody.hosts[host].sessions;
		if not host_sessions then return; end
		for _, username in ipairs(roles.banned or {}) do
			local user = host_sessions[username];
			if user then
				for _, session in pairs(user.sessions) do
					session:close({ condition = "not-authorized"; text = "Banned" });
				end
			end
		end
	end);
	return 60;
end

module:add_timer(60, kick_banned);
EOF

cat > /usr/local/lib/prosody/modules/mod_muc_alone.lua <<'EOF'
-- alo.ne room rules
local http = require "net.http";
local json = require "util.json";
local jid = require "util.jid";
local st = require "util.stanza";

local api = module:get_option_string("alone_api");
local secret = module:get_option_string("alone_secret");
local domains = module:get_option_set("alone_domains", { "alo.ne" });
local mod_muc = module:depends("muc");

local roles = { admins = {}, moderators = {}, resellers = {}, premium = {}, banned = {}, plates = {} };
local sets = {};
local bridge = module:get_option_string("alone_bridge", "bridge");
local function premium_ok(node) return node == bridge or sets.premium[node]; end

-- Public rooms
local public_rooms = {
	lobby = { name = "Lobby", description = "Public chat for anyone on any server, shared with #lobby on irc.alo.ne" };
	pl = { name = "Privacy & Legal", description = "Swap privacy approaches and ask legal questions. Not legal advice. Shared with #pl on irc.alo.ne" };
};
local function is_public(room) return public_rooms[jid.node(room.jid)] ~= nil; end

local function to_set(list)
	local set = {};
	for _, value in ipairs(list or {}) do set[value] = true; end
	return set;
end

local icons = { star = "⭐", crown = "👑", gem = "💎", shield = "🛡", flame = "🔥", bolt = "⚡", heart = "❤", skull = "💀",
	moon = "🌙", sun = "☀", leaf = "🍃", spade = "♠", club = "♣", diamond = "♦", clover = "🍀", dice = "🎲" };

local function rank_of(username)
	if sets.admins[username] then return "admin", "Admin"; end
	if sets.moderators[username] then return "moderator", "Moderator"; end
	if sets.resellers[username] then return "reseller", "Reseller"; end
	if sets.premium[username] then return "premium", "Premium"; end
end

local function ours(bare)
	local node, host = jid.split(bare);
	if node and domains:contains(host) then return node; end
end

local function deny(event, condition, text)
	event.origin.send(st.error_reply(event.stanza, "cancel", condition, text));
	return true;
end

local function apply(room, occupant)
	local node = ours(occupant.bare_jid);
	if not node then return; end
	if sets.banned[node] or (jid.node(room.jid) == "premium" and not premium_ok(node)) then
		room:set_role(true, occupant.nick, "none", "Not allowed");
		if room:get_affiliation(occupant.bare_jid) == "member" and room:get_affiliation_data(occupant.bare_jid, "alone") then
			room:set_affiliation(true, occupant.bare_jid, "none");
		end
		return;
	end
	local want = sets.admins[node] and "owner" or sets.moderators[node] and "admin" or nil;
	local have = room:get_affiliation(occupant.bare_jid);
	if want and have ~= want then
		room:set_affiliation(true, occupant.bare_jid, want, nil, { alone = true });
	elseif not want and (have == "owner" or have == "admin") and room:get_affiliation_data(occupant.bare_jid, "alone") then
		room:set_affiliation(true, occupant.bare_jid, "member");
	end
end

local function refresh()
	http.request(api .. "/roles", { headers = { ["X-Chat-Secret"] = secret } }, function(body, code)
		if code ~= 200 then return; end
		local data = json.decode(body);
		if not data then return; end
		roles = data;
		sets = { admins = to_set(data.admins), moderators = to_set(data.moderators), resellers = to_set(data.resellers),
			premium = to_set(data.premium), banned = to_set(data.banned) };
		for room in mod_muc.live_rooms() do
			for _, occupant in room:each_occupant() do apply(room, occupant); end
		end
		-- Staff roles
		for room in mod_muc.all_rooms() do
			local stale = {};
			for _, affiliation in ipairs({ "owner", "admin" }) do
				for bare in room:each_affiliation(affiliation) do
					local node = ours(bare);
					local want = node and (sets.admins[node] and "owner" or sets.moderators[node] and "admin");
					if node and want ~= affiliation then stale[#stale + 1] = bare; end
				end
			end
			for _, bare in ipairs(stale) do room:set_affiliation(true, bare, "none"); end
		end
		-- Premium members
		local premium = mod_muc.get_room_from_jid("premium@" .. module.host);
		if premium then
			local lapsed = {};
			for bare, _, data in premium:each_affiliation("member") do
				if data and data.alone and not premium_ok(jid.node(bare)) then lapsed[#lapsed + 1] = bare; end
			end
			for _, bare in ipairs(lapsed) do premium:set_affiliation(true, bare, "none"); end
			for user in pairs(sets.premium) do
				for host in domains:items() do
					local bare = user .. "@" .. host;
					if not premium:get_affiliation(bare) then premium:set_affiliation(true, bare, "member", nil, { alone = true }); end
				end
			end
			local relay = bridge .. "@" .. module:get_option_string("alone_primary_domain", "alo.ne");
			if not premium:get_affiliation(relay) then premium:set_affiliation(true, relay, "member", nil, { alone = true }); end
		end
	end);
	return 60;
end

sets = { admins = {}, moderators = {}, resellers = {}, premium = {}, banned = {} };
module:add_timer(1, refresh);

module:add_timer(2, function()
	for node, info in pairs(public_rooms) do
		local room_jid = node .. "@" .. module.host;
		local room = mod_muc.get_room_from_jid(room_jid) or mod_muc.create_room(room_jid);
		if room then
			room:set_persistent(true);
			room:set_public(true);
			room:set_whois("moderators");
			room:set_name(info.name);
			room:set_description(info.description);
		end
	end
end);

module:hook("muc-room-pre-create", function(event)
	local node = ours(jid.bare(event.stanza.attr.from));
	if not node or not (sets.admins[node] or sets.moderators[node]) then
		return deny(event, "not-allowed", "Only staff can create channels");
	end
end, 10);

module:hook("muc-room-created", function(event)
	if jid.node(event.room.jid) == "premium" then
		event.room:set_members_only(true);
		event.room:set_public(false);
	end
end);

module:hook("muc-occupant-pre-join", function(event)
	local bare = jid.bare(event.stanza.attr.from);
	local node = ours(bare);
	if is_public(event.room) then
		if node and sets.banned[node] then return deny(event, "forbidden", "Banned"); end
		return;
	end
	if not node then return deny(event, "not-allowed", "Only alo.ne accounts can join"); end
	if select(3, jid.split(event.occupant.nick)) ~= node then
		return deny(event, "not-acceptable", "Your nickname must be your username");
	end
	if sets.banned[node] then return deny(event, "forbidden", "Banned"); end
	if jid.node(event.room.jid) == "premium" and not premium_ok(node) then
		return deny(event, "registration-required", "Premium members only");
	end
	if jid.node(event.room.jid) == "premium" and not event.room:get_affiliation(bare) then
		event.room:set_affiliation(true, bare, "member", nil, { alone = true });
	end
end, 10);

module:hook("muc-occupant-joined", function(event)
	apply(event.room, event.occupant);
end);

module:hook("muc-build-occupant-presence", function(event)
	if event.room and is_public(event.room) then return; end
	local node = ours(event.occupant.bare_jid);
	if not node then return; end
	local key, title = rank_of(node);
	local plate = roles.plates and roles.plates[node];
	if not key and not plate then return; end
	local hats = event.stanza:tag("hats", { xmlns = "urn:xmpp:hats:0" });
	if key then hats:tag("hat", { uri = "https://alo.ne/rank/" .. key; title = title }):up(); end
	if plate and plate.text ~= "" then
		local prefix = icons[plate.icon] and (icons[plate.icon] .. " ") or "";
		hats:tag("hat", { uri = "https://alo.ne/plate/" .. node; title = prefix .. plate.text }):up();
	end
	hats:up();
end);
EOF

cat > /usr/local/lib/prosody/modules/mod_upload_alone.lua <<'EOF'
-- File host uploads
local http = require "net.http";
local async = require "util.async";
local json = require "util.json";
local jid = require "util.jid";
local st = require "util.stanza";
local dataform = require "util.dataforms".new;

local api = module:get_option_string("alone_api");
local secret = module:get_option_string("alone_secret");
local domains = module:get_option_set("alone_domains", { "alo.ne" });
local max_size = module:get_option_number("alone_upload_max_size", 52428800);
local namespace = "urn:xmpp:http:upload:0";

module:depends("disco");
module:add_identity("store", "file", "alo.ne uploads");
module:add_feature(namespace);
module:add_extension(dataform {
	{ name = "FORM_TYPE", type = "hidden", value = namespace };
	{ name = "max-file-size", type = "text-single" };
}:form({ ["max-file-size"] = tostring(max_size) }, "result"));

module:hook("iq-get/host/" .. namespace .. ":request", function(event)
	local stanza, origin = event.stanza, event.origin;
	local request = stanza.tags[1];
	local node, host = jid.split(stanza.attr.from);
	local filename, size = request.attr.filename, tonumber(request.attr.size);
	if origin.type ~= "c2s" or not node or not domains:contains(host) or not node:match("^[a-z0-9]+$") then
		origin.send(st.error_reply(stanza, "auth", "forbidden"));
		return true;
	end
	if not filename or filename == "" or not size or size <= 0 then
		origin.send(st.error_reply(stanza, "modify", "bad-request", "Invalid filename or size"));
		return true;
	end
	if size > max_size then
		origin.send(st.error_reply(stanza, "modify", "not-acceptable", "File too large")
			:tag("file-too-large", { xmlns = namespace }):tag("max-file-size"):text(tostring(max_size)));
		return true;
	end

	local response = async.wait_for(http.request(api .. "/upload-slot", {
		method = "POST";
		headers = { ["Content-Type"] = "application/json"; ["X-Chat-Secret"] = secret };
		body = json.encode({ username = node; filename = filename; size = size });
	}));
	local slot = response and response.code == 200 and json.decode(response.body);
	if not slot then
		local code = response and response.code;
		if code == 507 then
			origin.send(st.error_reply(stanza, "wait", "resource-constraint", "Not enough storage space"));
		elseif code == 413 then
			origin.send(st.error_reply(stanza, "modify", "not-acceptable", "File too large"));
		else
			origin.send(st.error_reply(stanza, "cancel", "internal-server-error"));
		end
		return true;
	end

	origin.send(st.reply(stanza):tag("slot", { xmlns = namespace })
		:tag("put", { url = slot.put }):up()
		:tag("get", { url = slot.get }):up());
	return true;
end);
EOF

say "Prosody config"
DOMAINS_LUA=$(printf '"%s"; ' "${DOMAINS[@]}")
{
cat <<EOF
-- Managed by alone-chat.sh
admins = { }
plugin_paths = { "/usr/local/lib/prosody/modules" }
modules_enabled = {
  "roster"; "saslauth"; "tls"; "disco"; "carbons"; "pep"; "private"; "blocklist"; "vcard4"; "vcard_legacy";
  "mam"; "smacks"; "cloud_notify"; "csi_simple"; "ping"; "websocket"; "limits"; "admin_shell"; "turn_external"; "server_contact_info";
  "anti_spam";
}
anti_spam_services = { "xmppbl.org" }
modules_disabled = { "lastactivity"; "watchregistrations" }
-- Federation
s2s_require_encryption = true
s2s_secure_auth = true
limits = { s2sin = { rate = "30kb/s"; burst = "2s" } }
log = { warn = "*syslog" }
hide_os_type = true
pidfile = "/run/prosody/prosody.pid"
storage = "sql"
sql = { driver = "SQLite3"; database = "prosody.sqlite" }
c2s_require_encryption = true
allow_registration = false
c2s_direct_tls_ports = { 5223 }
http_ports = { 5280 }
http_interfaces = { "127.0.0.1" }
https_ports = { }
consider_websocket_secure = true
cross_domain_websocket = { "https://chat.alo.ne" }
archive_expires_after = "1d"
default_archive_policy = "roster"
muc_log_expires_after = "30d"
alone_api = "$BACKEND_URL/internal/chat"
alone_secret = "$CHAT_SECRET"
alone_primary_domain = "$PRIMARY"
alone_domains = { $DOMAINS_LUA}
turn_external_host = "turn.alo.ne"
turn_external_secret = "$TURN_SECRET"
turn_external_tcp = true
turn_external_tls_port = 5349
contact_info = {
  abuse = { "mailto:$LEGAL_EMAIL" };
  admin = { "mailto:$LEGAL_EMAIL" };
  security = { "mailto:$LEGAL_EMAIL" };
  feedback = { "$LEGAL_URL" };
}
certificates = "certs"

EOF
for d in "${DOMAINS[@]}"; do printf 'VirtualHost "%s"\n  authentication = "alone"\n\n' "$d"; done
cat <<'EOF'
Component "conference.alo.ne" "muc"
  modules_enabled = { "muc_mam"; "muc_moderation"; "vcard_muc"; "muc_alone"; "muc_rate_limit" }
  restrict_room_creation = false
  muc_room_default_public = true
  muc_room_default_persistent = true
  muc_room_default_public_jids = true
  muc_room_default_history_length = 50

Component "upload.alo.ne" "upload_alone"

Component "proxy.alo.ne" "proxy65"
  proxy65_address = "proxy.alo.ne"
EOF
printf '  proxy65_acl = { %s}\n' "$DOMAINS_LUA"
} > /etc/prosody/prosody.cfg.lua
chown root:prosody /etc/prosody/prosody.cfg.lua; chmod 640 /etc/prosody/prosody.cfg.lua
for m in mod_anti_spam mod_vcard_muc mod_muc_rate_limit; do
  prosodyctl install --server=https://modules.prosody.im/rocks/ "$m" >/dev/null 2>&1 || warn "Could not install $m, prosodyctl install $m by hand"
done
systemctl enable -q prosody; systemctl restart prosody

say "Ergo"
ERGO_ARCH=$([ "$(dpkg --print-architecture)" = arm64 ] && echo arm64 || echo x86_64)
ERGO_URL=$(curl -fsS https://api.github.com/repos/ergochat/ergo/releases/latest | jq -r --arg a "linux-$ERGO_ARCH.tar.gz$" '.assets[] | select(.name | test($a)) | .browser_download_url' | head -1)
[ -n "$ERGO_URL" ] || die "Could not find the latest Ergo release"
tmp=$(mktemp -d); curl -fsSL "$ERGO_URL" -o "$tmp/ergo.tgz"; tar -xzf "$tmp/ergo.tgz" -C "$tmp"
install -m 755 "$(find "$tmp" -type f -name ergo | head -1)" /usr/local/bin/ergo
install -d -o ergo -g ergo /var/lib/ergo /etc/ergo
[ -f /var/lib/ergo/default.yaml ] || cp "$(find "$tmp" -name default.yaml | head -1)" /var/lib/ergo/default.yaml
rm -rf "$tmp"
OPER_HASH=$(mkpasswd -m bcrypt "$OPER_PASS")
cat > /etc/ergo/ircd.motd <<'EOF'

$c[magenta] █████╗ ██╗      ██████╗    ███╗   ██╗███████╗$c[pink]  ██╗██████╗  ██████╗$r
$c[magenta]██╔══██╗██║     ██╔═══██╗   ████╗  ██║██╔════╝$c[pink]  ██║██╔══██╗██╔════╝$r
$c[magenta]███████║██║     ██║   ██║   ██╔██╗ ██║█████╗  $c[pink]  ██║██████╔╝██║     $r
$c[magenta]██╔══██║██║     ██║   ██║   ██║╚██╗██║██╔══╝  $c[pink]  ██║██╔══██╗██║     $r
$c[magenta]██║  ██║███████╗╚██████╔╝██╗██║ ╚████║███████╗$c[pink]  ██║██║  ██║╚██████╗$r
$c[magenta]╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝╚═╝  ╚═══╝╚══════╝$c[pink]  ╚═╝╚═╝  ╚═╝ ╚═════╝$r

$b$c[pink]Public rooms$r  $c[grey]anyone can join, no account needed$r
  $b#lobby$r         $c[grey]open chat, shared with lobby@conference.alo.ne on XMPP$r
  $b#pl$r            $c[grey]privacy and legal, swap approaches and ask questions, not legal advice$r
  $c[grey]For better privacy connect without logging in and use a nick that isnt your username$r

$b$c[pink]Member rooms$r  $c[grey]log in with your alo.ne account$r
  $b#general$r       $c[grey]everyone, bridged to Discord, Telegram and XMPP$r
  $b#suggestions$r   $c[grey]ideas and feedback, bridged too$r
  $b#premium$r       $c[grey]premium members only, bridged to the premium channels$r

$b$c[pink]Connecting with your alo.ne account$r
  $c[light grey]Server$r      irc.alo.ne  port 6697  SSL on
  $c[light grey]Login$r       SASL with your alo.ne username
  $c[light grey]Password$r    your chat password from alo.ne/dashboard/chat
              $c[grey]not your dashboard password$r
  $c[light grey]Nick$r        your alo.ne username, others are refused
  $c[light grey]User name$r   your alo.ne username too
  $c[grey]Halloy on Windows and Irssi on Linux, ready made configs at alo.ne/dashboard/chat$r

$b$c[pink]If something goes wrong$r
  $c[light grey]Malformed username$r   set your client's user name to your alo.ne username
  $c[light grey]SASL failed$r          activate chat or set a new chat password on the dashboard
  $c[light grey]Cannot join #premium$r premium only, alo.ne/dashboard/order
  $c[light grey]Cannot join (+R)$r     member rooms need you logged in with SASL
  $c[light grey]Nobody gets my DMs$r   guests cant DM members, a member can /accept nick to allow you

$c[grey]IRC is plain text to the server. For private DMs use an XMPP app with OMEMO$r
$c[grey]Privacy and what we keep  legal.alo.ne$r

EOF
chown root:ergo /etc/ergo/ircd.motd; chmod 644 /etc/ergo/ircd.motd
cat > /etc/ergo/ircd.yaml <<EOF
# Managed by alone-chat.sh
network:
  name: alo.ne
server:
  name: irc.alo.ne
  motd: /etc/ergo/ircd.motd
  motd-formatting: true
  listeners:
    ":6697":
      tls:
        cert: /var/lib/ergo/tls/fullchain.pem
        key: /var/lib/ergo/tls/privkey.pem
    "127.0.0.1:6667": {}
  sts:
    enabled: true
    duration: 1mo
    port: 6697
  lookup-hostnames: false
  forward-confirm-hostnames: false
  check-ident: false
  casemapping: ascii
  enforce-utf8: true
  max-sendq: 96k
  ip-cloaking:
    enabled: true
    enabled-for-always-on: true
    netname: "alo"
    cidr-len-ipv4: 32
    cidr-len-ipv6: 64
    num-bits: 64
  ip-check-script:
    enabled: false
  connection-limits:
    enabled: true
    cidr-len-ipv4: 32
    cidr-len-ipv6: 64
    connections-per-subnet: 8
    exempted: ["localhost"]
  connection-throttling:
    enabled: true
    cidr-len-ipv4: 32
    cidr-len-ipv6: 64
    connection-window: 1m
    max-connections: 32
    ban-duration: 10m
    exempted: ["localhost"]
accounts:
  authentication-enabled: true
  registration:
    enabled: false
  require-sasl:
    enabled: false
    exempted: []
  default-user-modes: +iR
  login-throttling:
    enabled: true
    duration: 1m
    max-attempts: 3
  nick-reservation:
    enabled: true
    method: strict
    force-nick-equals-account: true
    forbid-anonymous-nick-changes: true
  vhosts:
    enabled: true
    max-length: 64
    valid-regexp: '^[0-9A-Za-z.\-_/]+$'
  multiclient:
    enabled: true
    allowed-by-default: true
    always-on: disabled
channels:
  default-modes: +ntCR
  max-channels-per-client: 100
  registration:
    enabled: true
    operator-only: true
    max-channels-per-account: 15
oper-classes:
  "sync":
    title: Sync
    capabilities: ["vhosts", "accreg", "chanreg", "samode", "local_kill", "kill"]
opers:
  chatsync:
    class: "sync"
    hidden: true
    password: "$OPER_HASH"
logging:
  - method: stderr
    type: "* -userinput -useroutput -connect-ip"
    level: warn
datastore:
  path: /var/lib/ergo/ircd.db
  autoupgrade: true
limits:
  nicklen: 32
  identlen: 20
  channellen: 64
  awaylen: 390
  kicklen: 390
  topiclen: 390
  monitor-entries: 100
  whowas-entries: 100
  chan-list-modes: 100
  registration-messages: 1024
  multiline:
    max-bytes: 4096
    max-lines: 100
fakelag:
  enabled: true
  window: 1s
  burst-limit: 5
  messages-per-window: 2
  cooldown: 2s
history:
  enabled: false
  persistent:
    enabled: false
api:
  enabled: true
  listener: "$WG_CHAT_IP:8089"
  bearer-tokens: ["$ERGO_API_TOKEN"]
EOF
chown root:ergo /etc/ergo/ircd.yaml; chmod 640 /etc/ergo/ircd.yaml
[ -f /var/lib/ergo/ircd.db ] || runuser -u ergo -- /usr/local/bin/ergo initdb --conf /etc/ergo/ircd.yaml --quiet
cat > /etc/systemd/system/ergo.service <<'EOF'
[Unit]
Description=Ergo IRC server
After=network-online.target wg-quick@wg0.service
Wants=network-online.target

[Service]
User=ergo
ExecStart=/usr/local/bin/ergo run --conf /etc/ergo/ircd.yaml
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/ergo
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable -q ergo; systemctl restart ergo
sleep 2
curl -fsS -H "Authorization: Bearer $ERGO_API_TOKEN" -X POST "http://$WG_CHAT_IP:8089/v1/ns/saregister" \
  --data "$(jq -nc --arg p "$SYNC_PASS" '{accountName:"chatsync",passphrase:$p}')" > /dev/null || warn "chatsync IRC account not created, check: journalctl -u ergo"

say "coturn"
cat > /etc/turnserver.conf <<EOF
listening-port=3478
tls-listening-port=5349
min-port=49160
max-port=49200
use-auth-secret
static-auth-secret=$TURN_SECRET
realm=turn.alo.ne
cert=/etc/coturn/tls/fullchain.pem
pkey=/etc/coturn/tls/privkey.pem
no-cli
no-multicast-peers
no-stdout-log
log-file=/dev/null
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=::1
denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff
EOF
systemctl enable -q coturn; systemctl restart coturn

say "nginx"
install -d -m 755 /srv/mb-media
BACKEND_HOSTPORT=${BACKEND_URL#http://}
cat > /etc/nginx/nginx.conf <<EOF
# Managed by alone-chat.sh
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 2048; }

stream {
  map \$ssl_preread_alpn_protocols \$upstream {
    ~\bxmpp-client\b 127.0.0.1:5223;
    default 127.0.0.1:8443;
  }
  server {
    listen 443;
    listen [::]:443;
    ssl_preread on;
    proxy_pass \$upstream;
  }
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  access_log off;
  error_log /var/log/nginx/error.log crit;
  server_tokens off;
  sendfile on;
  map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }

  server {
    listen 127.0.0.1:8443 ssl;
    http2 on;
    server_name chat.alo.ne upload.alo.ne;
    ssl_certificate /etc/letsencrypt/live/alone-chat/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/alone-chat/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 51m;
    add_header Strict-Transport-Security "max-age=31536000" always;

    location = /xmpp-websocket {
      proxy_pass http://127.0.0.1:5280/xmpp-websocket;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_read_timeout 900s;
    }
    location /web/ {
      proxy_pass http://127.0.0.1:8087;
      proxy_set_header Host \$host;
    }
    location = /web { return 301 /web/; }
    location ~ ^/u/([a-z0-9]+)\$ {
      if (\$request_method = OPTIONS) {
        add_header Access-Control-Allow-Origin "https://chat.alo.ne";
        add_header Access-Control-Allow-Methods "PUT";
        add_header Access-Control-Allow-Headers "Content-Type";
        add_header Access-Control-Max-Age 600;
        return 204;
      }
      limit_except PUT { deny all; }
      add_header Access-Control-Allow-Origin "https://chat.alo.ne" always;
      proxy_pass http://$BACKEND_HOSTPORT/internal/chat/upload/\$1\$is_args\$args;
      proxy_set_header X-Chat-Secret "$CHAT_SECRET";
      proxy_set_header Cookie "";
      proxy_request_buffering off;
      proxy_read_timeout 300s;
    }
    location ~ ^/f/([a-z0-9]+)(/.*)?\$ {
      limit_except GET { deny all; }
      add_header Access-Control-Allow-Origin "https://chat.alo.ne" always;
      proxy_pass http://$BACKEND_HOSTPORT/internal/chat/file/\$1;
      proxy_set_header X-Chat-Secret "$CHAT_SECRET";
      proxy_set_header Cookie "";
    }
    location /mb/ {
      alias /srv/mb-media/;
      add_header Content-Security-Policy "default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'; sandbox" always;
      add_header X-Content-Type-Options nosniff always;
    }
    location = / { proxy_pass http://127.0.0.1:8087/public/; proxy_set_header Host \$host; }
    location /public/ { proxy_pass http://127.0.0.1:8087; proxy_set_header Host \$host; }
    location / { return 404; }
  }

  server {
    listen 127.0.0.1:8443 ssl;
    http2 on;
    server_name legal.alo.ne;
    ssl_certificate /etc/letsencrypt/live/alone-chat/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/alone-chat/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=31536000" always;
    location / { proxy_pass http://127.0.0.1:8087/legal/; }
  }

  server {
    listen 127.0.0.1:8443 ssl;
    http2 on;
    server_name check.alo.ne;
    ssl_certificate /etc/letsencrypt/live/alone-chat/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/alone-chat/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=31536000" always;
    location / { proxy_pass http://127.0.0.1:8087/check/; }
  }
}
EOF
rm -f /etc/nginx/sites-enabled/default
nginx -t -q && systemctl enable -q nginx && systemctl restart nginx

say "chatsync (ranks, bans, vhosts and bridge labels every minute)"
install -d -m 755 /var/lib/alone
cat > /usr/local/sbin/chatsync <<'EOF'
#!/bin/bash
# Ranks and bans
set -euo pipefail
. /root/alone-chat.env
dir=/var/lib/alone
roles=$(curl -fsS --max-time 20 -H "X-Chat-Secret: $CHAT_SECRET" "$BACKEND_URL/internal/chat/roles")
valid() { [[ $1 =~ ^[a-z0-9]+$ ]]; }

echo "$roles" | jq '
  def icon: {star:"⭐",crown:"👑",gem:"💎",shield:"🛡",flame:"🔥",bolt:"⚡",heart:"❤",skull:"💀",moon:"🌙",sun:"☀",leaf:"🍃",spade:"♠",club:"♣",diamond:"♦",clover:"🍀",dice:"🎲"}[.] // "";
  (reduce (.premium[]) as $u ({}; .[$u] = "Premium")) as $p |
  (reduce (.resellers[]) as $u ($p; .[$u] = "Reseller")) as $r |
  (reduce (.moderators[]) as $u ($r; .[$u] = "Moderator")) as $m |
  (reduce (.admins[]) as $u ($m; .[$u] = "Admin")) as $rank |
  .plates as $plates |
  def entry($u): {rank: ($rank[$u] // ""), name: $u, plate: (if $plates[$u] then (($plates[$u].icon // "" | icon) + " " + $plates[$u].text | ltrimstr(" ")) else "" end)};
  ([$rank | keys[]] + [$plates | keys[]] | unique) as $users |
  (reduce $users[] as $u ({}; .["xmpp:" + $u] = entry($u) | .["irc:" + $u] = entry($u))) +
  (reduce (.discord | to_entries[]) as $d ({}; .["discord:" + $d.key] = entry($d.value)))
' > "$dir/ranks.json.tmp" && mv "$dir/ranks.json.tmp" "$dir/ranks.json"
echo "$roles" | jq '{users: .banned, discord: .bannedDiscord}' > "$dir/denylist.json.tmp" && mv "$dir/denylist.json.tmp" "$dir/denylist.json"

desired=$(echo "$roles" | jq -r '
  . as $r |
  def rank($u): if ($r.admins | index($u)) then "admin" elif ($r.moderators | index($u)) then "mod"
    elif ($r.resellers | index($u)) then "reseller" elif ($r.premium | index($u)) then "premium" else empty end;
  ([.chatUsers[] | select(. as $u | $r.banned | index($u) | not)][] | "active \(.)"),
  (.banned[] | "banned \(.)"),
  (([.admins[], .moderators[], .resellers[], .premium[]] | unique)[] as $u | "vhost \($u) \(rank($u)).alo.ne"),
  (.admins[] | "amode \(.) +q"), (.moderators[] | "amode \(.) +o"),
  (.premium[] | "premium \(.)"), "premium bridge"' | sort -u)
[ -f "$dir/rooms-v2" ] || rm -f "$dir/applied"
touch "$dir/applied"
cmds=()
while read -r kind user value; do
  valid "$user" || continue
  case $kind in
    vhost) cmds+=("HS SET $user $value") ;;
    amode) for chan in "#general" "#suggestions" "#premium" "#lobby" "#pl"; do cmds+=("CS AMODE $chan $value $user"); done ;;
    premium) cmds+=("SAMODE #premium +I $user!*@*") ;;
    active) cmds+=("NS SUSPEND DEL $user") ;;
    banned) cmds+=("NS SUSPEND ADD $user") ;;
  esac
done < <(comm -13 "$dir/applied" <(echo "$desired"))
while read -r kind user value; do
  valid "$user" || continue
  case $kind in
    vhost) echo "$desired" | grep -q "^vhost $user " || cmds+=("HS DEL $user") ;;
    amode) for chan in "#general" "#suggestions" "#premium" "#lobby" "#pl"; do cmds+=("CS AMODE $chan -${value#+} $user"); done ;;
    premium) cmds+=("SAMODE #premium -I $user!*@*") ;;
    active) cmds+=("NS SUSPEND ADD $user") ;;
  esac
done < <(comm -23 "$dir/applied" <(echo "$desired"))
[ -f "$dir/channels-registered" ] || cmds=("CS REGISTER #general" "CS REGISTER #suggestions" "${cmds[@]}")
if [ ! -f "$dir/rooms-v2" ]; then
  setup=()
  # Premium gate
  setup+=("JOIN #premium" "SAMODE #premium +o chatsync" "CS REGISTER #premium" "SAMODE #premium +iR" "PART #premium")
  # Member rooms
  setup+=("SAMODE #general +R" "SAMODE #suggestions +R")
  setup+=("JOIN #lobby" "SAMODE #lobby +o chatsync" "CS REGISTER #lobby"
    "TOPIC #lobby :Public chat for anyone, shared with lobby@conference.alo.ne on XMPP | Be decent | Abuse legal@alo.ne" "PART #lobby")
  setup+=("JOIN #pl" "SAMODE #pl +o chatsync" "CS REGISTER #pl"
    "TOPIC #pl :Privacy and legal, swap approaches and ask questions | Not legal advice | Shared with pl@conference.alo.ne | Abuse legal@alo.ne" "PART #pl")
  cmds=("${setup[@]}" "${cmds[@]}")
fi

if [ ${#cmds[@]} -gt 0 ]; then
  auth=$(printf 'chatsync\0chatsync\0%s' "$SYNC_PASS" | base64 -w0)
  {
    printf 'CAP REQ :sasl\r\nNICK chatsync\r\nUSER chatsync 0 * :chatsync\r\nAUTHENTICATE PLAIN\r\n'; sleep 1
    printf 'AUTHENTICATE %s\r\nCAP END\r\n' "$auth"; sleep 2
    printf 'OPER chatsync %s\r\nMODE chatsync +B\r\n' "$OPER_PASS"; sleep 1
    for c in "${cmds[@]}"; do printf '%s\r\n' "$c"; sleep 0.3; done
    sleep 1; printf 'QUIT\r\n'
  } | nc -q 3 127.0.0.1 6667 > /dev/null
  touch "$dir/channels-registered" "$dir/rooms-v2"
fi
echo "$desired" > "$dir/applied"
EOF
chmod 700 /usr/local/sbin/chatsync
cat > /etc/systemd/system/chatsync.service <<'EOF'
[Unit]
Description=alo.ne chat rank and ban sync
After=ergo.service wg-quick@wg0.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/chatsync
EOF
cat > /etc/systemd/system/chatsync.timer <<'EOF'
[Unit]
Description=Run chatsync every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s

[Install]
WantedBy=timers.target
EOF
cat > /etc/cron.daily/alone-mb-media <<'EOF'
#!/bin/sh
find /srv/mb-media -type f -mtime +30 -delete
find /srv/mb-media -mindepth 1 -type d -empty -delete
EOF
chmod 755 /etc/cron.daily/alone-mb-media
systemctl daemon-reload; systemctl enable -q --now chatsync.timer

say "Matterbridge (maintained fork, built from source)"
id matterbridge >/dev/null 2>&1 || useradd --system --home /var/lib/matterbridge --create-home --shell /usr/sbin/nologin matterbridge
chown matterbridge:matterbridge /srv/mb-media
GO_RELEASE=$(curl -fsS 'https://go.dev/dl/?mode=json' | jq -c --arg a "$(dpkg --print-architecture)" \
  '[.[] | select(.stable)][0].files[] | select(.os == "linux" and .arch == $a and .kind == "archive")')
GO_FILE=$(echo "$GO_RELEASE" | jq -r .filename)
GO_VERSION=$(echo "$GO_RELEASE" | jq -r .version)
[ -n "$GO_FILE" ] && [ "$GO_FILE" != null ] || die "Could not find the latest Go release"
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "$GO_VERSION "; then
  echo "  downloading $GO_FILE"
  if curl -4 -fsSL "https://dl.google.com/go/$GO_FILE" -o /tmp/go.tgz || curl -fsSL "https://dl.google.com/go/$GO_FILE" -o /tmp/go.tgz; then
    echo "$(echo "$GO_RELEASE" | jq -r .sha256)  /tmp/go.tgz" | sha256sum -c --quiet || die "Go download checksum mismatch"
    rm -rf /usr/local/go; tar -C /usr/local -xzf /tmp/go.tgz; rm -f /tmp/go.tgz
  else
    warn "dl.google.com failed, using the Go module proxy instead"
    apt-get install -yq unzip >/dev/null
    GO_ZIP="v0.0.1-$GO_VERSION.linux-$(dpkg --print-architecture)"
    curl -fsSL "https://proxy.golang.org/golang.org/toolchain/@v/$GO_ZIP.zip" -o /tmp/go.zip || die "Could not download Go"
    rm -rf /tmp/go-unzip /usr/local/go; unzip -q /tmp/go.zip -d /tmp/go-unzip
    mv "/tmp/go-unzip/golang.org/toolchain@$GO_ZIP" /usr/local/go
    chmod +x /usr/local/go/bin/* /usr/local/go/pkg/tool/*/* 2>/dev/null || true
    rm -rf /tmp/go.zip /tmp/go-unzip
  fi
  /usr/local/go/bin/go version || die "Go install failed"
fi
[ -d /opt/matterbridge ] || git clone -q "$MB_REPO" /opt/matterbridge
git -C /opt/matterbridge fetch -q origin
git -C /opt/matterbridge checkout -q -f "${MB_COMMIT:-origin/master}"
MB_COMMIT=$(git -C /opt/matterbridge rev-parse HEAD); save MB_COMMIT "$MB_COMMIT"
sed -i 's|UserID: "@" + m.Author.Username|UserID: m.Author.ID|' /opt/matterbridge/bridge/discord/handlers.go
MB_TAGS="nomatrix goolm nomattermost noslack nomsteams nowhatsapp nozulip nonctalk nosshchat notwitch novk nokeybase norocketchat nogitter nomumble nosoulseek"
(cd /opt/matterbridge && /usr/local/go/bin/go build -trimpath -tags "$MB_TAGS" -o /usr/local/bin/matterbridge .)
install -d -o matterbridge -g matterbridge -m 750 /etc/matterbridge

cat > /etc/matterbridge/nick.tengo <<'EOF'
os := import("os")
json := import("json")
text := import("text")

ranks := {}
raw := os.read_file("/var/lib/alone/ranks.json")
if !is_error(raw) {
  decoded := json.decode(raw)
  if !is_error(decoded) { ranks = decoded }
}

name := text.to_lower(msgUsername)
if msgProtocol == "discord" || msgProtocol == "telegram" {
  name = text.re_replace("[^a-z0-9_.]", name, "")
  if len(name) > 20 { name = name[:20] }
  if name == "" { name = "user" }
}
key := msgProtocol == "discord" ? "discord:" + msgUserID : msgProtocol + ":" + name
entry := (gateway == "lobby" || gateway == "pl") ? undefined : ranks[key]

out := name
if entry != undefined {
  if msgProtocol == "discord" { out = entry.name }
  if entry.rank != "" { out = out + " [" + entry.rank + "]" }
}
out = out + " · " + msgProtocol
if entry == undefined && (msgProtocol == "discord" || msgProtocol == "telegram") { out = out + " · guest" }
if entry != undefined && entry.plate != "" { out = out + " " + entry.plate }
result = out
EOF

cat > /etc/matterbridge/filter.tengo <<'EOF'
os := import("os")
json := import("json")
text := import("text")

deny := {users: [], discord: []}
raw := os.read_file("/var/lib/alone/denylist.json")
if !is_error(raw) {
  decoded := json.decode(raw)
  if !is_error(decoded) { deny = decoded }
}

contains := func(list, value) {
  for item in list { if item == value { return true } }
  return false
}

if inProtocol == "discord" && contains(deny.discord, msgUserID) { msgDrop = true }
if (inProtocol == "xmpp" || inProtocol == "irc") && contains(deny.users, text.to_lower(msgUsername)) { msgDrop = true }

// Telegram replies
if inProtocol == "telegram" && text.has_prefix(msgText, "⤷") {
  parts := text.split(msgText, "⁣")
  if len(parts) == 3 {
    nick := text.trim_prefix(parts[0], "⤷")
    quote := parts[1]
    found := text.re_find(`^(.+?) · (?:xmpp|irc|discord|telegram)[^:\n]*: ([\s\S]*)$`, quote)
    if found != undefined {
      nick = found[0][1].text
      quote = found[0][2].text
    }
    msgText = "↪ " + nick + ": " + text.replace(quote, "\n", " ", -1) + "\n" + parts[2]
  }
}

msgText = text.re_replace(`\[([^\]]*)\]\((https?://[^)\s]*)\)`, msgText, "$1 ($2)")
msgText = text.re_replace("[\x02\x03\x0f\x16\x1d\x1f]", msgText, "")
msgText = text.replace(msgText, "@everyone", "@ everyone", -1)
msgText = text.replace(msgText, "@here", "@ here", -1)
EOF

{
cat <<EOF
[general]
RemoteNickFormat="{TENGO}: "
MediaServerPath="/srv/mb-media"
MediaServerDownload="https://upload.alo.ne/mb"
MediaDownloadSize=10000000

[tengo]
RemoteNickFormat="/etc/matterbridge/nick.tengo"
OutMessage="/etc/matterbridge/filter.tengo"

[xmpp.alone]
Server="chat.alo.ne:5222"
Jid="bridge@alo.ne"
Password="$BRIDGE_PASS"
Muc="conference.alo.ne"
Nick="bridge"
NoSendJoinPart=true

[irc.alone]
Server="irc.alo.ne:6697"
UseTLS=true
Nick="bridge"
UseSASL=true
NickServNick="bridge"
NickServPassword="$BRIDGE_PASS"
MessageDelay=1300
MessageSplit=true
NoSendJoinPart=true
EOF
if [ -n "$DISCORD_TOKEN" ]; then cat <<EOF

[discord.alone]
Token="$DISCORD_TOKEN"
Server="ID:$DISCORD_GUILD"
RemoteNickFormat="{TENGO}"
AllowMention=["users"]
MessageLength=2000
MessageSplit=true
EOF
fi
if [ -n "$TELEGRAM_TOKEN" ]; then cat <<EOF

[telegram.alone]
Token="$TELEGRAM_TOKEN"
MessageFormat="HTMLNick"
QuoteFormat="⤷{QUOTENICK}⁣{QUOTEMESSAGE}⁣{MESSAGE}"
QuoteLengthLimit=120
MessageLength=4096
EOF
fi
for room in general suggestions premium; do
  up=$(echo "$room" | tr a-z A-Z); chan_var=DISCORD_$up; hook_var=DISCORD_${up}_HOOK; tg_var=TELEGRAM_$up
  cat <<EOF

[[gateway]]
name="$room"
enable=true
  [[gateway.inout]]
  account="xmpp.alone"
  channel="$room"
  [[gateway.inout]]
  account="irc.alone"
  channel="#$room"
EOF
  if [ -n "$DISCORD_TOKEN" ] && [ -n "${!chan_var:-}" ]; then cat <<EOF
  [[gateway.inout]]
  account="discord.alone"
  channel="ID:${!chan_var}"
    [gateway.inout.options]
    WebhookURL="${!hook_var:-}"
EOF
  fi
  if [ -n "$TELEGRAM_TOKEN" ] && [ -n "${!tg_var:-}" ]; then cat <<EOF
  [[gateway.inout]]
  account="telegram.alone"
  channel="${!tg_var}"
EOF
  fi
done
# Public rooms
for room in lobby pl; do cat <<EOF

[[gateway]]
name="$room"
enable=true
  [[gateway.inout]]
  account="xmpp.alone"
  channel="$room"
  [[gateway.inout]]
  account="irc.alone"
  channel="#$room"
EOF
done
} > /etc/matterbridge/matterbridge.toml
chown -R matterbridge:matterbridge /etc/matterbridge; chmod 600 /etc/matterbridge/matterbridge.toml

cat > /etc/systemd/system/matterbridge.service <<'EOF'
[Unit]
Description=Matterbridge relay
After=network-online.target prosody.service ergo.service
Wants=network-online.target

[Service]
User=matterbridge
ExecStart=/usr/local/bin/matterbridge -conf /etc/matterbridge/matterbridge.toml
Restart=on-failure
RestartSec=10
StandardOutput=null
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ReadWritePaths=/srv/mb-media
ReadOnlyPaths=/var/lib/alone /etc/matterbridge
IPAddressDeny=10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 fc00::/7

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable -q matterbridge; systemctl restart matterbridge

say "Firewall"
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}'); SSH_PORT=${SSH_PORT:-22}
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif lo accept
    meta l4proto { icmp, ipv6-icmp } accept
    tcp dport { $SSH_PORT, 443, 5222, 5223, 5269, 6697, 3478, 5349 } accept
    udp dport { 3478, 49160-49200, 51820 } accept
    iifname "wg0" ip saddr $WG_ORIGIN_IP tcp dport 8089 accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname { "docker0", "br-*" } accept
  }
  chain output { type filter hook output priority 0; policy accept; }
}
EOF
systemctl enable -q nftables; nft -f /etc/nftables.conf
if systemctl is-active -q docker; then systemctl restart docker; fi

say "Done"
cat <<EOF

Chat server public IPs: $IP4 ${IP6:-}
Saved secrets: $STATE (root only)
Matterbridge commit: $MB_COMMIT

1) On the DASHBOARD server, paste this whole block. It creates a separate interface (wgchat) for the chat link
   and doesn't touch your existing wg0 to the mail servers:

cat > /etc/wireguard/wgchat.conf <<WG
[Interface]
Address = $WG_ORIGIN_IP/24
PrivateKey = \$(cat /etc/wireguard/wgchat.key)

[Peer]
PublicKey = $WG_PUB
Endpoint = $IP4:51820
AllowedIPs = $WG_CHAT_IP/32
PersistentKeepalive = 25
WG
chmod 600 /etc/wireguard/wgchat.conf && systemctl enable --now wg-quick@wgchat && ping -c 2 $WG_CHAT_IP

$( [ -n "$ORIGIN_WG_PUB" ] || echo "   You skipped the dashboard key: run this script again on the chat server and paste it." )

2) Make the backend listen on the WireGuard address. In the dashboard's docker-compose.yml, under the dashboard service add:
     ports:
       - "$WG_ORIGIN_IP:8088:8080"
   Add these to the dashboard env, then redeploy:
     CHAT_SECRET=$CHAT_SECRET
     CHAT_UPLOAD_URL=https://upload.alo.ne
     ERGO_API_URL=http://$WG_CHAT_IP:8089
     ERGO_API_TOKEN=$ERGO_API_TOKEN

3) In Traefik, block /internal/ on the public entrypoint. Check from any outside machine, it must NOT say 200:
     curl -s -o /dev/null -w '%{http_code}\n' https://api.alo.ne/internal/chat/roles

4) Back on THIS chat server, check the link to the backend, it must say 200:
     curl -s -o /dev/null -w '%{http_code}\n' -H "X-Chat-Secret: \$(. $STATE; echo \$CHAT_SECRET)" $BACKEND_URL/internal/chat/roles
   Then: systemctl restart prosody matterbridge && systemctl start chatsync

5) From an admin account in an XMPP app, join general, suggestions and premium on conference.alo.ne once to create them.

6) Deploy the webchat with Coolify (see README.md, "Deploying the webchat"). nginx here already sends
   https://chat.alo.ne/web/ to 127.0.0.1:8087, where the Coolify container must listen.

Check services: systemctl status prosody ergo nginx coturn matterbridge chatsync.timer
Logs if something fails: journalctl -u <service> -n 50
EOF
