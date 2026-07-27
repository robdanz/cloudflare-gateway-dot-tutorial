# Testing Cloudflare Gateway DNS Policies with DNS-over-TLS (DoT)

This is a tutorial (plus a ready-to-run Docker option) for standing up a
local DNS-over-TLS (DoT) stub resolver — [`stubby`](https://github.com/getdnsapi/stubby)
— pointed at a Cloudflare Gateway DoT endpoint. Once it's running, every
normal `dig`/`curl`/etc. lookup on the machine goes out encrypted over
DoT to Gateway, which means Gateway's DNS policies (block categories,
block specific domains, etc.) apply to that traffic. It's the fastest way
to prove out Gateway DNS policy behavior from a shell, without touching a
device's full WARP/Cloudflare One Client configuration.

Two ways to follow along:

- **Docker** — one command, works identically on macOS/Linux/Windows,
  no changes to your host's DNS config. Good default.
- **Native install** — installs `stubby` directly on Debian/Ubuntu or
  RHEL/Fedora and points the whole host at it. Useful when you want to
  test how a real endpoint (not a container) behaves under a Gateway DoT
  policy, or when Docker isn't available.

## How this works

A DoT hostname like `abc123.cloudflare-gateway.com` can't be reached over
TLS until something resolves it to an IP — and that resolution can't
happen over DoT itself, since DoT is what we're setting up. So there's
one, and only one, plain DNS query involved anywhere in this setup: a
one-time **bootstrap lookup** (over plain UDP/53, against a resolver like
`8.8.8.8`) that resolves the DoT hostname to an IP.

That IP — plus the hostname itself — gets fed into `stubby`'s config as
its **only** upstream, using TLS as its **only** transport, with
`tls_auth_name` set to the hostname so `stubby` validates the upstream's
TLS certificate against it (not just trusting whatever answers on that
IP). `stubby` then listens locally on `127.0.0.1:53`. Once the system's
resolver config points there instead of anywhere else, every subsequent
DNS lookup a tool makes — `dig`, `curl`, anything using the standard
resolver — goes exclusively through `stubby` and, from there, exclusively
over encrypted DoT to Cloudflare Gateway.

## 1. Create a DoT-enabled DNS location in Cloudflare Gateway

You need a Gateway **DNS location** with a DoT endpoint before any of
this works — that's what generates the hostname you'll test against.

1. In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/),
   go to **Networks** > **Resolvers & Proxies** > **DNS locations**.
2. Select **Add a location**, give it a name (e.g. `dot-test`).
3. Choose the endpoint type(s) you want. Make sure **DNS over TLS (DoT)**
   is enabled for this location — it's one of the endpoint type options
   in the location wizard alongside IPv4/IPv6 and DNS-over-HTTPS (DoH).
4. Configure source IP filtering if you want to restrict who can query
   this location (optional for a quick test).
5. Save the location.
6. Open the location's detail page and look for the **DoT endpoint**
   section — copy the value under **DoT addresses**. That's your DoT
   hostname, in the form `<location-id>.cloudflare-gateway.com`.

> Cloudflare dashboards get reorganized from time to time — if the menu
> names above don't match exactly what you see, search the Zero Trust
> sidebar for "DNS locations."

## 2. (Optional) Create a DNS policy to test against

To actually see enforcement happen, add at least one DNS policy scoped to
this location:

1. In the Zero Trust dashboard, find **DNS policies** under Gateway /
   traffic policies.
2. Add a policy with, for example:

   | Selector | Operator | Value | Action |
   |---|---|---|---|
   | Content Categories | in | Adult Themes | Block |

   (Or scope it further with a `Location` selector so it only applies to
   the DNS location you just created.)
3. Deploy the policy.

Now you have something concrete to verify once DoT is wired up: queries
for domains in that category should come back blocked/sinkholed, while
everything else resolves normally.

## 3a. Docker (recommended default)

This repo includes a small Alpine image that runs `stubby` and drops you
into a shell with DoT already configured.

**Build:**

```
docker compose build
```

**Run**, passing the DoT hostname from step 1:

```
DOT_HOSTNAME=your-location-id.cloudflare-gateway.com docker compose run --rm dot-test
```

Or copy `.env.example` to `.env`, fill in `DOT_HOSTNAME`, and just run
`docker compose run --rm dot-test`.

You'll land in a shell where `dig`/`curl` already go through DoT — skip
to [Step 4: Verify](#4-verify-its-working).

Config knobs (env vars): `DOT_HOSTNAME` (required), `DOT_PORT` (default
`853`), `BOOTSTRAP_RESOLVER` (default `8.8.8.8`, used only for the
one-time bootstrap lookup).

See `Dockerfile`, `entrypoint.sh`, and `stubby.yml.tpl` in this repo for
exactly how it's wired — the entrypoint script does the bootstrap lookup,
renders `stubby`'s config, and redirects `/etc/resolv.conf`, mirroring
the steps below for native installs.

## 3b. Native install — Debian / Ubuntu

```
sudo apt update
sudo apt install -y stubby dnsutils curl
```

**Bootstrap-resolve your DoT hostname** (replace with the hostname from
step 1):

```
dig +short @8.8.8.8 A your-location-id.cloudflare-gateway.com
```

Note the IP it returns.

**Back up and edit the stubby config** at `/etc/stubby/stubby.yml`:

```
sudo cp /etc/stubby/stubby.yml /etc/stubby/stubby.yml.orig
sudo tee /etc/stubby/stubby.yml > /dev/null <<'EOF'
resolution_type: GETDNS_RESOLUTION_STUB
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
idle_timeout: 10000
listen_addresses:
  - 127.0.0.1@53
round_robin_upstreams: 1
upstream_recursive_servers:
  - address_data: PASTE_BOOTSTRAP_IP_HERE
    tls_auth_name: "your-location-id.cloudflare-gateway.com"
    tls_port: 853
EOF
```

**Free up port 53.** Modern Ubuntu runs `systemd-resolved`, which owns
port 53 via a stub listener on `127.0.0.53` and manages
`/etc/resolv.conf` (usually a symlink). `stubby` can't bind `127.0.0.1:53`
until that's out of the way:

```
sudo systemctl disable --now systemd-resolved
sudo rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf
```

**Start stubby:**

```
sudo systemctl enable --now stubby
sudo systemctl restart stubby
```

Skip to [Step 4: Verify](#4-verify-its-working).

## 3c. Native install — RHEL / Fedora

On RHEL/CentOS, enable EPEL first (Fedora already has `stubby` in its
official repos):

```
sudo dnf install -y epel-release   # RHEL/CentOS only, skip on Fedora
sudo dnf install -y stubby bind-utils curl
```

**Bootstrap-resolve your DoT hostname:**

```
dig +short @8.8.8.8 A your-location-id.cloudflare-gateway.com
```

**Back up and edit `/etc/stubby/stubby.yml`** — same file contents as the
Debian/Ubuntu section above, with your bootstrap-resolved IP and hostname
filled in.

**Free up port 53.** RHEL/Fedora typically let `NetworkManager` write
`/etc/resolv.conf` from DHCP, which will fight with a static config.
Tell it to stop managing DNS:

```
sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null <<'EOF'
[main]
dns=none
EOF
sudo systemctl restart NetworkManager
sudo rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf
```

**Start stubby:**

```
sudo systemctl enable --now stubby
sudo systemctl restart stubby
```

## 4. Verify it's working

From a shell with `stubby` running and `/etc/resolv.conf` pointed at
`127.0.0.1` (this is automatic in the Docker container; done manually in
the native steps above):

```
cat /etc/resolv.conf              # should show only "nameserver 127.0.0.1"

dig example.com                   # look at the SERVER line in the output —
                                   # it should say 127.0.0.1#53(127.0.0.1),
                                   # confirming the query went through stubby

curl -v https://example.com       # should succeed, resolved via the same path
```

To confirm Gateway's policy is actually being enforced, look up a
hostname that falls under the block policy you created in step 2 —
you should see it fail to resolve, get an `NXDOMAIN`, or come back
sinkholed, depending on how the policy is configured. A normal, unrelated
hostname should resolve fine.

## Troubleshooting

- **`stubby` won't start / "address already in use"** — something else
  is still bound to port 53. On Ubuntu that's almost always
  `systemd-resolved`; on RHEL/Fedora it can be `dnsmasq` or
  `NetworkManager`'s own resolver. Check with
  `sudo lsof -i :53` and stop whatever's holding it.
- **TLS/certificate errors from `stubby`** — double check `tls_auth_name`
  in the config matches the DoT hostname exactly (not the resolved IP),
  and that the bootstrap-resolved IP is current (Gateway DoT IPs can
  change; re-run the bootstrap `dig` and update the config if it's been
  a while).
- **Queries aren't going through `stubby` at all** — confirm
  `/etc/resolv.conf` really has only `127.0.0.1` in it, and that nothing
  (systemd-resolved, NetworkManager, a VPN client) is rewriting it back.
- **Policy doesn't seem to be enforced** — confirm the DNS policy from
  step 2 is deployed and, if scoped with a `Location` selector, that it's
  scoped to the same DNS location whose DoT hostname you're using.

## Notes / limitations

- The bootstrap IP is resolved once, at startup. If the DoT endpoint's
  IP changes mid-session, restart `stubby` (or the container).
- No firewall-level enforcement (no `iptables`) in the Docker path —
  `/etc/resolv.conf` points everything at the local `stubby` resolver,
  which only speaks DoT upstream. This is a test client for Gateway's
  policy, not a sandbox against itself.
