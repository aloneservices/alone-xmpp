# Alone-XMPP

The alo.ne chat server and webchat.

| Folder | What it is | How it's deployed |
| --- | --- | --- |
| `server/alone-chat.sh` | Config files made into a shell script setup: Prosody, Ergo, nginx, coturn, Matterbridge, `chatsync`, WireGuard, certificates, firewall, Cloudflare DNS | Run once as root, and re-run to change settings |
| `webchat/` | The browser chat that replaces the shoutbox. A static Vite + React app with XMPP and OMEMO, served at `https://chat.alo.ne/web/` | Coolify, as a Docker app on the chat VPS |
| `legal/` | The legal and privacy page, served at `https://legal.alo.ne` | Same Coolify app (same container) |
| `check/` | The code checker, served at `https://check.alo.ne`. It compares the live webchat and dashboard files with the signed lists on GitHub | Same Coolify app |

All three are served by one container. They're on DNS-only subdomains, so none of them pass through Cloudflare.

The dashboard embeds the webchat in a frame on the overview page. The frame runs on `chat.alo.ne`, a different origin
from `alo.ne`, so dashboard scripts, npm packages and biolink pages can never read the OMEMO keys or messages. The
dashboard only hands the frame a 5-minute chat token and fills in name colours and badges, using `postMessage`, and
both sides check the other's origin. `chat.alo.ne` is DNS-only, so the webchat code never passes through Cloudflare.

## 1. Set up the chat server

```bash
scp server/alone-chat.sh root@<chat-vps-ip>:/root/
ssh root@<chat-vps-ip> bash /root/alone-chat.sh
```

The script explains how to get each value it asks for. At the end it prints:
- the WireGuard block to paste on the dashboard server
- the dashboard env vars to add
- the Traefik rule that blocks `/internal/`
- the checks to run

## 2. Add the chat server to Coolify

1. Coolify > **Servers** > **Add**. Use the chat VPS IP, user `root`, port 22, and let Coolify add its SSH key. Validate the server, and Coolify installs Docker.
2. Open the new server > **Proxy** and choose **None**. Our nginx already owns ports 80 and 443 on this machine, so Coolify's Traefik must not start.
3. If Docker was installed after the setup script ran, run `systemctl restart docker` once. The setup script's firewall reload clears Docker's rules, and a restart rebuilds them.

## 3. Deploy the webchat

1. Coolify > **Projects** > your project > **New resource** > **Public or private repository** (this repo).
2. **Build pack:** Dockerfile. **Base directory:** `/` (the repo root, because the image also copies `legal/` and `check/`). **Dockerfile:** `/webchat/Dockerfile`.
3. **Server:** the chat VPS. **Domains:** leave empty, because nginx on the host handles TLS and the domain.
4. **Ports:**
   - Ports Exposes: `8087`
   - Ports Mappings: `127.0.0.1:8087:8087`

   Bind to 127.0.0.1 only, so the container is never reachable from outside except through the host nginx.
5. **Build variables (optional):** `VITE_PARENT_ORIGINS=https://alo.ne` (comma-separated if the dashboard is reachable on more than one origin) and `VITE_DASHBOARD_URL=https://alo.ne`.
6. Deploy. Check with:
   ```bash
   curl -sI https://chat.alo.ne/web/ | grep -i -E 'HTTP|content-security-policy'
   ```
   It should return 200 with the CSP header.

On the dashboard, `NEXT_PUBLIC_WEBCHAT_URL` defaults to `https://chat.alo.ne/web/`. Only set it to point the frame somewhere else.

Updates: push to git, then **Deploy** in Coolify (or turn on auto-deploy). No SSH needed.

## 4. Publish signed hashes for each release

Users can check that `chat.alo.ne` serves exactly the code you released. After Coolify has deployed a commit:

```bash
cd webchat
git checkout <deployed commit>
bun install --frozen-lockfile
bun run build
bun run hashes          # writes hashes.txt (index.html + the JS and CSS files)
```

Run the verify commands from `hashes.txt` against the live site. Every line must say OK. If anything fails, don't sign it:
it means the live files differ from your build.

Then sign on your own machine. The key never goes on any server:

```bash
gpg --clearsign hashes.txt
```

Publish your key fingerprint on keys.openpgp.org, GitHub and Discord.

### The public hashes repo (what check.alo.ne reads)

Create a public GitHub repo, for example `alone-hashes`, and set its raw URL in `check/check.js` (`HASHES`). For each release:
- Commit the signed webchat list as `webchat.txt.asc`, overwriting the old one. Git history keeps every release.
- Commit the signed dashboard list as `dashboard.txt.asc`.
- Post the same `.asc` files in Discord and the Telegram channel.

### Dashboard release list

The dashboard repo has `npm run release-hashes`. After `next build` it writes `dashboard.txt` with every
`/_next/static` file. For your local build to match Coolify's, build with the same commit as the build id:

```bash
cd frontend
SOURCE_COMMIT=<deployed commit> NEXT_PUBLIC_API_ROOT=https://api.alo.ne NEXT_PUBLIC_PASSWORD_PUBLIC_KEY=<same key as Coolify> bun run build
bun run release-hashes
gpg --clearsign dashboard.txt
```

In Coolify, turn on passing the source commit to the build (`SOURCE_COMMIT`) for the dashboard app. If the hashes still
differ from the live site, build locally inside the same Docker image (`docker build --target frontend-builder .`) so
the toolchain matches exactly.

## Local development

```bash
cd webchat
bun install
bun run dev                # http://127.0.0.1:5173/web/
```

- Set `NEXT_PUBLIC_WEBCHAT_URL=http://127.0.0.1:5173/web/` in the dashboard's `.env.local` and open the dashboard on `http://127.0.0.1:3000`. `.env.development` here already trusts that origin.
- The webchat connects to `wss://chat.alo.ne/xmpp-websocket` by default. Set `VITE_XMPP_WS` to point it elsewhere.
- Use the SSH tunnel from the setup notes so the chat server reaches your local backend.

## Security notes

- **CSP:** the webchat is served with `script-src 'self'` and `frame-ancestors https://alo.ne`, with no inline or third-party scripts. Keep it that way.
- **Dependencies are pinned** in `bun.lock`. Review dependency updates before deploying, because they run next to the OMEMO keys.
- **Coolify has root SSH to the chat VPS.** Protect the Coolify panel with 2FA and keep Coolify updated.
- **The webchat is still a web page.** For the strongest protection, people should use an app such as Conversations, Monal or Gajim. The XMPP & IRC page on the dashboard says so.
