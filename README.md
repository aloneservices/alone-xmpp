# Alone-XMPP

The alo.ne chat server and webchat.

| Folder | What it is | How it's deployed |
| --- | --- | --- |
| `server/alone-chat.sh` | Config files made into a shell script setup: Prosody, Ergo, nginx, coturn, Matterbridge, `chatsync`, WireGuard, certificates, firewall, Cloudflare DNS | Run once as root, and re-run to change settings |
| `webchat/` | The browser chat that replaces the shoutbox. A static Vite + React app with XMPP and OMEMO, served at `https://chat.alo.ne/web/` | Coolify, as a Docker app on the chat VPS |
| `legal/` | The legal and privacy page, served at `https://legal.alo.ne` | Same Coolify app (same container) |
| `check/` | The code checker, served at `https://check.alo.ne`. It compares the live webchat and dashboard files with the signed lists on GitHub | Same Coolify app |
| `suggestbridge/` | Numbers #suggestions and links each one to its own Discord forum post, so replies from XMPP, IRC and Discord land in the right thread | Built by `alone-chat.sh` from a pinned commit of this repo, runs as a systemd service |

All three are served by one container. They're on DNS-only subdomains, so none of them pass through Cloudflare.

The dashboard embeds the webchat in a frame on the overview page. The frame runs on `chat.alo.ne`, a different origin
from `alo.ne`, so dashboard scripts, npm packages and biolink pages can never read the OMEMO keys or messages. The
dashboard only hands the frame a 5-minute chat token and fills in name colours and badges, using `postMessage`, and
both sides check the other's origin. `chat.alo.ne` is DNS-only, so the webchat code never passes through Cloudflare.




