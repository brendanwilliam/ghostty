# Reaching your Mac from anywhere with Headscale

Ghostty on iOS connects to your Mac over SSH. At home that works over
Wi-Fi; away from home (cellular, another Wi-Fi network) the Mac is behind
your router and can't be reached directly. These files set up
[Headscale](https://github.com/juanfont/headscale), the open-source
(BSD-3) Tailscale coordination server, so your Mac and iPhone join a
private network (a tailnet) and can always reach each other:

- Traffic between them is end-to-end WireGuard: direct when possible,
  through your server's relay otherwise (e.g. when your home internet is
  behind CGNAT). The server never sees what you type.
- Each device keeps the same tailnet address on every network, so an SSH
  session over the tailnet usually survives the phone moving between Wi-Fi
  and cellular without reconnecting.
- The Mac and iPhone run the official Tailscale clients, pointed at your
  server instead of Tailscale's. Your server, not Tailscale, keeps the list
  of devices and their addresses.

You need a small server with a public IPv4 address (any VPS works) and a
DNS name for it.

## 1. The server

1. Point a DNS A record (for example `hs.example.com`) at the server.
2. Open these ports in its firewall: `80/tcp` (certificates), `443/tcp`
   (Headscale and its relay), `3478/udp` (STUN).
3. Install Docker, then copy this directory to the server and fill in the
   config:

   ```sh
   mkdir -p config lib
   cp config.example.yaml config/config.yaml
   cp policy.hujson config/policy.hujson
   ```

   In `config/config.yaml`, replace `hs.example.com` (twice),
   `tail.example.com` and `203.0.113.10`. In `config/policy.hujson`,
   replace `you@` with the user you'll create below, keeping the `@`.
4. Start it and create your user:

   ```sh
   docker compose up -d
   docker exec headscale headscale users create you
   ```

5. From your Mac, check it: `./check.sh hs.example.com`.

## 2. The Mac

1. Turn on **System Settings → General → Sharing → Remote Login** if it
   isn't already.
2. Install Homebrew's build of Tailscale (the open-source client and
   daemon) and start it with logging to Tailscale turned off:

   ```sh
   brew install tailscale
   sudo cp com.tailscale.tailscaled.plist /Library/LaunchDaemons/
   sudo launchctl bootstrap system /Library/LaunchDaemons/com.tailscale.tailscaled.plist
   ```

3. Join your tailnet as `tag:mac`:

   ```sh
   tailscale up --login-server https://hs.example.com --advertise-tags tag:mac
   ```

   It prints a URL with an auth ID. On the server, approve it:

   ```sh
   docker exec headscale headscale auth register --user you --auth-id <AUTH_ID>
   ```

4. Keep the Mac awake while it's on power, so sessions keep running and
   the phone can reach it:

   ```sh
   sudo pmset -c sleep 0
   ```

   Ghostty also keeps the Mac awake while a phone is attached.

## 3. The iPhone

1. Install [Tailscale](https://apps.apple.com/app/tailscale/id1470499037).
2. Tap the account icon → **Log in…**, then the options menu (top right)
   → **Use custom coordination server**, and enter
   `https://hs.example.com`.
3. Approve it on the server with `headscale auth register` as above.
4. In Tailscale's settings, turn on **VPN On Demand** if it's offered, so
   the tunnel comes back on its own.

In Ghostty, connect to the Mac once (over Wi-Fi at home is fine). Ghostty
learns the Mac's tailnet address from it and uses that from then on, at
home and away.

## Checking it works

- `docker exec headscale headscale nodes list`: both devices online.
- On the Mac, `tailscale status` and `tailscale ping <phone>`: "via DERP"
  means relayed through your server, an IP address means direct.
- `tailscale debug derp headscale` on the Mac checks the relay.

## Upkeep

- **Back up** `lib/db.sqlite` (and the keys beside it) now and then.
- **Upgrade:** read Headscale's release notes, change the version and
  digest in `docker-compose.yml`, then `docker compose pull && docker
  compose up -d`.
- **Policy changes:** edit `config/policy.hujson`, then
  `docker kill --signal=HUP headscale`.
- If the server is down, devices that are already connected keep working
  for a while; new sign-ins and network changes wait until it's back.
