# ProfitView on your own server (browser edition)

ProfitView runs 24/7 on a rented Linux server (VPS) inside a Chromium browser that you open in your normal browser over a secure, password-protected link.

## What you need

- A VPS running **Debian 12** or **Ubuntu 24.04**, with at least **2 GB RAM** (4 GB recommended). Hetzner, DigitalOcean and Vultr all work.
- Your ProfitView **email address and license code** (from your purchase email).
- Your exported ProfitView **configuration** (options page on your current PC → **Copy Conf** at the top right).

## Installation

### Option A: no SSH needed (cloud-init)

When you create the server, most providers have a field called **"Cloud config"**, **"User data"** or **"cloud-init"**. Paste this into it, using your own password (at least 12 characters):

```bash
#!/bin/bash
curl -fsSL https://profitview.app/install.sh | bash -s -- 'YOUR-PASSWORD-HERE'
```

Create the server and wait about 5 minutes. Then open `https://<server-ip-with-dashes>.sslip.io`. For a server at `203.0.113.7`, that's `https://203-0-113-7.sslip.io`.

### Option B: via SSH

```bash
curl -fsSL https://profitview.app/install.sh | sudo bash -s -- 'YOUR-PASSWORD-HERE'
```

At the end, the script prints the link and the login name (`profitview`).

## First start

1. Open the link and log in with `profitview` and your password.
2. The **ProfitView** options page opens automatically on **Getting Started**. Click **Paste Conf** at the top right and paste your configuration.
3. Open **Setup: Unlock PRO** in the menu on the left, enter your **email address and license code** and click **Log in**.
4. Switch to the **TradingView** tab and log in to TradingView once.

That's it. You can close the browser tab on your PC; ProfitView keeps running on the server.

## Security (important)

- **Exchange API keys:** disable **withdrawals** and restrict the keys to your **server's IP address**, which the install script prints. Then even a stolen login can't move funds out.
- **Password:** use a strong, unique password for the web UI.
- **What's open:** the server only accepts SSH plus the web ports (80/443). The browser desktop itself is never reachable directly.

## Updating

```bash
sudo bash /opt/profitview/install.sh update
```

Your configuration, logins and TradingView session are kept.

## Options

Run `install.sh --help` for all options. The most useful ones:

| Option | Purpose |
|---|---|
| `--domain pv.example.com` | Use your own domain instead of `…sslip.io`. Its DNS record must point to the server. |
| `--start-url URL` | Open another chart or website instead of `https://www.tradingview.com/chart/`. |
| `--user NAME` | Use a different login name. |
| `--local` | No web address at all, reach ProfitView through an SSH tunnel (see below). |
| `--tailscale` | Like `--local`, plus access from your Tailscale network (see below). |
| `--no-password` | Only with `--local`/`--tailscale`: no login prompt. |
| `--dark` | Dark theme for the browser and ProfitView (ProfitView follows the browser's theme, switch with the theme button). |
| `--no-firewall` | Leave the firewall (ufw) untouched. |

Re-running the install command with a new password or other options changes them and keeps all data.

## Servers that already run a website (ports 80/443 in use)

`…sslip.io` is just a name for your server's IP, so it reaches the same ports as everything else on the server. SSH stays your server's own SSH, and if another web server already uses 80/443, ProfitView can't use them too. You have three choices:

1. **Your existing web server forwards to ProfitView (recommended).** Use `--no-proxy`, which makes ProfitView listen only on `127.0.0.1:3000`. The script prints a ready-to-use snippet for **Apache, nginx or Caddy** that you add to your web server, for example for `pv.yourdomain.com`, plus a password file.
2. **Other ports with your existing certificate.** For example:
   ```
   --domain yourdomain.com --https-port 8443 --http-port 8080 \
   --cert /etc/letsencrypt/live/yourdomain.com/fullchain.pem \
   --key /etc/letsencrypt/live/yourdomain.com/privkey.pem
   ```
   ProfitView is then at `https://yourdomain.com:8443`. With certbot, the script also installs a renewal hook so the certificate stays current.
3. **Other ports without a certificate.** Same as option 2 but without `--cert` and `--key`. A self-signed certificate is used, so your browser shows a warning on the first visit.

Remember to allow any custom ports in your provider's firewall.

## Private access without a web address (SSH tunnel or Tailscale)

If you'd rather not make ProfitView reachable from the internet at all, it can listen only on the server itself. No domain and no open web ports are needed, and the firewall only allows SSH.

### SSH tunnel

Install with `--local`:

```bash
curl -fsSL https://profitview.app/install.sh | sudo bash -s -- 'YOUR-PASSWORD-HERE' --local
```

Then, on your PC, open the tunnel and leave it running:

```bash
ssh -N -L 3000:127.0.0.1:3000 you@your-server
```

Open `http://localhost:3000` and log in with `profitview` and your password.

- If port 3000 is already used on your PC, pick another local port, e.g. `-L 8080:127.0.0.1:3000` and `http://localhost:8080`.
- **PuTTY:** Connection → SSH → Tunnels, source port `3000`, destination `127.0.0.1:3000`, click **Add**, then connect.
- A SOCKS tunnel (`ssh -D`) doesn't work for this, because browsers never send `localhost` through a proxy.

### Tailscale

Install with `--tailscale`:

```bash
curl -fsSL https://profitview.app/install.sh | sudo bash -s -- 'YOUR-PASSWORD-HERE' --tailscale
```

- If Tailscale isn't installed on the server yet, the script installs it and shows a link to log the server in to your tailnet. For unattended installs (cloud-init), pass an auth key instead: `TS_AUTHKEY=tskey-... bash -s -- ...`.
- In the Tailscale admin console, enable **MagicDNS** and **HTTPS Certificates** once (DNS page). The script tells you if they're missing.
- Then open `https://<server-name>.<your-tailnet>.ts.net` from any device in your tailnet. The script prints the exact address. Nobody outside your tailnet can reach it.

The SSH tunnel also works with this setup, as a fallback.

### Without a password

With `--no-password`, ProfitView doesn't ask for a login; SSH or Tailscale is then the only protection. Only use it on a server only you can log in to, and a tailnet you fully control, because the browser holds your exchange API keys.

Re-running the install command without `--tailscale` (or with other options) switches the access mode and keeps all data.

## Known limitations

- **Email notifications** aren't available in this browser edition, because they need a Chrome browser signed in to Google. Use Telegram or Discord notifications instead. We're working on an alternative.
- **Saved passwords:** passwords you let Chromium save (e.g. for TradingView) are stored on the server without extra encryption, just like your API keys. Only save them if you're comfortable with that.
