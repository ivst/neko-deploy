# neko-deploy

Deploy [Neko](https://github.com/m1k1o/neko) v3 with Firefox, Caddy HTTPS and an RTMP broadcast pipeline on a clean Ubuntu VPS.

The configuration is intended for a simple disposable or permanent VPS setup such as DigitalOcean:

```text
Internet
   |
   +--> HTTPS :443 --> Caddy --> Neko :8080
   |
   +--> WebRTC UDP 52000-52100 --> Neko

Firefox / VPN browser extension
   |
   v
desktop 1920x1080@30
   |
   +--> WebRTC VP8 --> Neko viewer
   |
   +--> x264 H.264 / AAC --> RTMP --> streaming service
```

## What is included

- Neko v3 Firefox image (`ghcr.io/m1k1o/neko/firefox:3`)
- 1920×1080 @ 30 fps desktop
- Caddy reverse proxy and automatic HTTPS
- persistent Firefox profile
- Firefox policy that allows browser extensions
- WebRTC UDP ports `52000-52100`
- custom H.264 RTMP pipeline:
  - 7000 kbps video
  - AAC 160 kbps
  - `veryfast`
  - B-frames disabled
  - GOP 60 (~2 seconds at 30 fps)
- installation, update and backup scripts

## Requirements

Recommended for comfortable 1080p30 software encoding:

- Ubuntu 24.04
- x86_64
- 4+ dedicated vCPU
- 8+ GB RAM
- public IPv4
- a domain with an A record pointing to the VPS

For simultaneous browser playback, Neko capture and RTMP encoding, 8 vCPU gives additional headroom.

## Quick install

Clone the repository:

```bash
git clone https://github.com/ivst/neko-deploy.git
cd neko-deploy
```

Run:

```bash
sudo ./install.sh \
  --domain subdomain.example.com \
  --public-ip 203.0.113.10
```

The script generates random Neko user/admin passwords if they are not supplied.

Optional UFW rules:

```bash
sudo ./install.sh \
  --domain subdomain.example.com \
  --public-ip 203.0.113.10 \
  --ufw
```

You can also provide values through environment variables:

```bash
sudo DOMAIN=subdomain.example.com \
  PUBLIC_IP=203.0.113.10 \
  NEKO_USER_PASSWORD='...' \
  NEKO_ADMIN_PASSWORD='...' \
  ./install.sh
```

## DNS and firewall

Point the domain to the VPS:

```text
subdomain.example.com A 203.0.113.10
```

Allow inbound:

```text
22/tcp              trusted IP only
80/tcp              public
443/tcp             public
52000-52100/udp     public
```

Outbound TCP/UDP should be allowed.

You do **not** need inbound TCP 1935 for RTMP publishing. Neko initiates the RTMP connection outbound.

## Files installed to the server

```text
/opt/neko/
├── docker-compose.yml
├── .env
├── Caddyfile
├── firefox-profile/
└── firefox-policies/
    └── policies.json
```

`.env` and `firefox-profile/` are intentionally ignored by Git.

## Firefox profile

The host directory:

```text
/opt/neko/firefox-profile
```

is mounted to:

```text
/home/neko/.mozilla/firefox/profile.default
```

This preserves extensions, cookies and browser settings when the container is recreated.

After first launch:

```bash
ls -la /opt/neko/firefox-profile
```

You should see files such as:

```text
prefs.js
cookies.sqlite
places.sqlite
extensions.json
```

## Browser extensions

`firefox-policies/policies.json` permits extension installation, so VPN/proxy browser extensions such as NordVPN or Surfshark can be installed inside Firefox.

Check active Firefox policies using:

```text
about:policies
```

## RTMP settings

The default custom pipeline is configured for:

```text
1920×1080 @ 30 fps
H.264 / x264
7000 kbps video
AAC 160 kbps
GOP 60
B-frames 0
veryfast preset
zerolatency
```

The RTMP URL / stream key should be entered through Neko's admin UI when starting the broadcast.

Do not commit stream keys to Git.

To change video bitrate, edit:

```yaml
bitrate=7000
```

inside `NEKO_CAPTURE_BROADCAST_PIPELINE`.

Then apply:

```bash
cd /opt/neko
sudo docker compose up -d --force-recreate
```

If Compose needs to recreate the shared network:

```bash
sudo docker compose down
sudo docker compose up -d
```

Do not use `down -v` unless you intentionally want to remove Caddy volumes.

## Operations

Status:

```bash
cd /opt/neko
docker compose ps
```

Logs:

```bash
docker logs -f neko
docker logs -f neko-caddy
```

Resource usage:

```bash
docker stats
```

Stop:

```bash
cd /opt/neko
docker compose down
```

Start:

```bash
cd /opt/neko
docker compose up -d
```

Update:

```bash
sudo ./update.sh
```

Backup:

```bash
sudo ./backup.sh
```

## RTMP diagnostics

Because RTMP runs inside the Neko container network namespace, host `ss -ti` may not show it.

```bash
PID=$(docker inspect -f '{{.State.Pid}}' neko)
sudo nsenter -t "$PID" -n ss -tinp
```

Only port 1935:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' neko)
sudo nsenter -t "$PID" -n ss -tinp | grep ':1935'
```

Useful values:

```text
Send-Q
bytes_retrans
retrans
rtt
cwnd
delivery_rate
```

## Security

- Restrict SSH to trusted IPs.
- Keep `.env` private (`chmod 600`).
- Never commit RTMP stream keys.
- Rotate any stream key that has been pasted into public logs or chats.
- Consider a cloud firewall in addition to UFW.
- The Caddy volume contains TLS state and should not normally be deleted.

## Upstream documentation

- Neko v3 installation: https://neko.m1k1o.net/docs/v3/installation
- Browser persistence/policies: https://neko.m1k1o.net/docs/v3/customization/browsers
- Capture and broadcast: https://neko.m1k1o.net/docs/v3/configuration/capture
- Reverse proxy setup: https://neko.m1k1o.net/docs/v3/reverse-proxy-setup

## License

MIT
