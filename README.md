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

On the first installation, the script generates random Neko user/admin passwords if none are supplied. They are stored in `/opt/neko/.env` (permissions `600`) and **are not printed to the terminal**. To view deliberately:

```bash
sudo grep '^NEKO_.*_PASSWORD=' /opt/neko/.env
```

Re-running the installer **preserves existing `.env` credentials**, even if new domain/IP/password values are passed. To change them, use `sudoedit /opt/neko/.env` and recreate the containers. Command-line password arguments are rejected because they may be exposed in process listings or shell history.

Optional UFW rules:

```bash
sudo ./install.sh \
  --domain subdomain.example.com \
  --public-ip 203.0.113.10 \
  --ufw
```

You can also supply domain and IP using environment variables:

```bash
sudo DOMAIN=subdomain.example.com PUBLIC_IP=203.0.113.10 ./install.sh
```

Password environment variables are still supported for automated first installs, but do not type secret assignments directly into shell history. Prefer generated passwords, or edit the protected `.env` with `sudoedit`.

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

Encrypted backup:

```bash
sudo BACKUP_AGE_RECIPIENT='age1YOUR_REAL_PUBLIC_RECIPIENT' ./backup.sh
```

## Encrypted backups and restore

Backup archives contain **Neko passwords and the complete Firefox profile**, including cookies and sessions. `backup.sh` now **fails closed** if encryption is not configured. It streams `tar` directly into `age` without creating an unencrypted temporary archive and sets output permissions to `600`.

1. Install `age` on the VPS:

   ```bash
   sudo apt-get install age
   ```

2. Generate an age key pair on a **trusted local machine**, ideally not on the VPS:

   ```bash
   umask 077
   age-keygen -o neko-backup-key.txt
   age-keygen -y neko-backup-key.txt
   ```

   Securely store the **private** `neko-backup-key.txt` outside of the repository and preferably off the VPS. The last command prints the **public recipient** (`age1...`), which is safe to copy to the VPS.

3. Back up on the VPS with the real public recipient:

   ```bash
   sudo BACKUP_AGE_RECIPIENT='age1YOUR_REAL_PUBLIC_RECIPIENT' ./backup.sh
   ```

   The resulting `/root/neko-backup-*.tar.gz.age` is encrypted. Transfer it to secure storage.
4. Inspect and restore on a trusted machine with the matching private identity:

   ```bash
   age -d -i neko-backup-key.txt -o restored.tar.gz /path/to/neko-backup.tar.gz.age
   tar -tzf restored.tar.gz
   # After checking the contents, restore to your chosen directory:
   # tar -xzf restored.tar.gz -C /your/restore/directory
   ```

   Decrypted archives contain live credentials; delete them securely afterward.

**Explicit plaintext opt-out:** `sudo ./backup.sh --plaintext` allows legacy plaintext backups but is **not recommended**. A plain `sudo ./backup.sh` without `BACKUP_AGE_RECIPIENT` now exits with an error.

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
- Keep `.env` private (`chmod 600`) and out of source control.
- Installer preserves credentials and never prints them by default.
- Encrypt backups with `age` and keep the private identity off the VPS.
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
