# Testing Cloudflare Gateway DNS Policies with DNS-over-TLS (DoT)

This is a tutorial (plus a ready-to-run Docker option) for standing up a
local DNS-over-TLS (DoT) stub resolver — [`stubby`](https://github.com/getdnsapi/stubby)
— pointed at a Cloudflare Gateway DoT endpoint. Once it's running, every
normal `dig`/`curl`/etc. lookup on the machine goes out encrypted over
DoT to Gateway, which means Gateway's DNS policies (block categories,
block specific domains, etc.) apply to that traffic. It's the fastest way
to prove out Gateway DNS policy behavior from a shell, without touching a
device's full WARP/Cloudflare One Client configuration.

A few ways to follow along:

- **Docker** — one command, works identically on macOS/Linux/Windows,
  no changes to your host's DNS config. Good default.
- **Native install with `stubby`** — installs `stubby` directly on
  Debian/Ubuntu or RHEL/Fedora and points the whole host at it. Useful
  when you want to test how a real endpoint (not a container) behaves
  under a Gateway DoT policy, or when Docker isn't available.
- **Native, systemd-resolved only (no `stubby`)** — if `stubby` genuinely
  isn't an option (locked-down package policy, whatever), systemd v243+
  has DoT support built in. No extra daemon, no port-53 fight — you're
  reconfiguring the resolver that's already running instead of replacing
  it. Slightly weaker enforcement guarantee than `stubby` (see the note
  in that section), but workable.

## How this works: bootstrapping the DoT endpoint

A DoT hostname like `abc123.cloudflare-gateway.com` is just a hostname —
before anything can open a TLS connection to it, something has to
resolve it to an IP address first. That resolution can't happen over DoT
itself, since DoT is the thing being set up; you'd need a working DoT
connection to resolve the name of the DoT server, which is circular. So
every path in this tutorial (Docker and all three native installs) does
exactly **one** plain DNS query, exactly once, before DoT exists at all:
the **bootstrap lookup**.

Concretely, that's a single `dig` against an ordinary plain-DNS resolver
(`8.8.8.8` by default in this repo — any working resolver works):

```
dig +short @8.8.8.8 A your-location-id.cloudflare-gateway.com
# → 162.159.36.5   (an example IP — yours will differ, and Gateway may
#                    return more than one)
```

That's the only UDP/53 query this setup is designed to make, anywhere,
ever. Everything downstream depends on its result:

1. **The resolved IP** becomes the sole upstream address the DoT
   resolver (`stubby` or systemd-resolved) is configured to talk to.
2. **The hostname itself** — not the IP — gets pinned as the identity
   the upstream's TLS certificate must match (`tls_auth_name` in
   `stubby`, the `#hostname` suffix in systemd-resolved's `DNS=`). This
   is what stops the setup from just trusting whatever happens to answer
   on that IP.
3. **TLS is configured as the only transport** the resolver will use for
   that upstream (`stubby`'s `dns_transport_list: [GETDNS_TRANSPORT_TLS]`,
   systemd-resolved's `DNSOverTLS=yes`).
4. The resolver then listens locally (`127.0.0.1:53` for `stubby`; the
   existing systemd-resolved stub for that path), and the system's
   resolver config is pointed at it. From that moment on, every
   subsequent DNS lookup any tool makes — `dig`, `curl`, anything using
   the standard resolver — goes exclusively through that local resolver
   and, from there, exclusively over encrypted DoT to Cloudflare Gateway.

Because the bootstrap IP is captured once and hardcoded into the config,
if Gateway's DoT endpoint IP changes later, the DoT connection will start
failing and needs a fresh bootstrap lookup + restart to pick up the new
IP (see [Notes / limitations](#notes--limitations)).

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
to [Step 4: Verify](#4-verify-its-working-docker--native-stubby-paths).

Config knobs (env vars): `DOT_HOSTNAME` (required), `DOT_PORT` (default
`853`), `BOOTSTRAP_RESOLVER` (default `8.8.8.8`, used only for the
one-time bootstrap lookup).

See `Dockerfile`, `entrypoint.sh`, and `stubby.yml.tpl` in this repo for
exactly how it's wired — the entrypoint script does the bootstrap lookup,
renders `stubby`'s config, and redirects `/etc/resolv.conf`, mirroring
the steps below for native installs.

## 3b. Native install — Debian / Ubuntu

> Verified against a real Cloudflare Gateway DoT hostname on Ubuntu
> 22.04: `systemctl status stubby` confirmed "Strict Profile
> (Authentication required)" with TLS as the only configured
> transport, `dig`/`curl` resolved successfully through
> `127.0.0.1#53`, and a packet capture during live queries showed
> every off-host packet on port 853 — the only port-53 traffic seen
> anywhere was `dig`'s local loopback hop to `stubby` itself, which
> never reaches the network. Pointing `stubby` at a server that fails
> TLS validation returned `SERVFAIL` rather than silently falling back
> to plaintext, confirming the "TLS is the ONLY transport" guarantee
> stubby logs on startup.

```
sudo apt update
sudo apt install -y stubby dnsutils curl
```

**Bootstrap-resolve your DoT hostname** (replace with the hostname from
step 1) — this is the one-time plain DNS query explained in
[How this works](#how-this-works-bootstrapping-the-dot-endpoint) above:

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

Skip to [Step 4: Verify](#4-verify-its-working-docker--native-stubby-paths). (Want failover to
`8.8.8.8` if Gateway becomes unreachable? See
[Step 5: Optional fallback](#5-optional-fail-over-to-8888-if-gateway-becomes-unreachable).)

## 3c. Native install — RHEL / Fedora

> Verified against a real Cloudflare Gateway DoT hostname on Fedora 40
> (systemd 255): same result as the Debian/Ubuntu track — `stubby`
> logged "Strict Profile (Authentication required)" with TLS as the
> only transport, `dig`/`curl` resolved through `127.0.0.1#53`, a
> packet capture during live queries showed every off-host packet on
> port 853 with zero plaintext DNS reaching the network, and pointing
> `stubby` at a server that fails TLS validation returned `SERVFAIL`
> instead of falling back.

On RHEL/CentOS, enable EPEL first (Fedora already has `stubby` in its
official repos):

```
sudo dnf install -y epel-release   # RHEL/CentOS only, skip on Fedora
sudo dnf install -y stubby bind-utils curl
```

**Bootstrap-resolve your DoT hostname** — the one-time plain DNS query
explained in [How this works](#how-this-works-bootstrapping-the-dot-endpoint)
above:

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

Skip to [Step 4: Verify](#4-verify-its-working-docker--native-stubby-paths).
(Want failover to `8.8.8.8` if Gateway becomes unreachable? See
[Step 5: Optional fallback](#5-optional-fail-over-to-8888-if-gateway-becomes-unreachable).)

## 3d. Native install — systemd-resolved only (no `stubby`)

> Verified against a real Cloudflare Gateway DoT hostname on Ubuntu 22.04
> (systemd 249): `resolvectl status` showed `+DNSOverTLS` active, a
> packet capture during a live query showed every packet on port 853
> to the Gateway IP and zero on port 53, and deliberately pointing
> `DNS=` at a server that fails TLS certificate validation caused
> `resolvectl query` to fail outright rather than silently falling back
> to plaintext.

If you can't install `stubby` at all, systemd-resolved (systemd v243+,
default on most modern Ubuntu/Debian and Fedora Workstation installs)
speaks DoT natively. You reconfigure the resolver that's already running
instead of displacing it — which also means no port-53 conflict to fight
and no need to touch `/etc/resolv.conf` (it's typically already a symlink
to systemd-resolved's stub at `127.0.0.53`).

Check you have a new enough systemd first:

```
systemctl --version   # want 243 or newer
```

**Bootstrap-resolve your DoT hostname** (replace with the hostname from
step 1) — the one-time plain DNS query explained in
[How this works](#how-this-works-bootstrapping-the-dot-endpoint) above:

```
dig +short @8.8.8.8 A your-location-id.cloudflare-gateway.com
```

Note the IP it returns.

**Create a drop-in config** pointing systemd-resolved at that IP, with
the hostname pinned after `#` so it validates the upstream's TLS
certificate against it — this is systemd-resolved's equivalent of
`stubby`'s `tls_auth_name`:

```
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/dot-gateway.conf > /dev/null <<'EOF'
[Resolve]
DNS=PASTE_BOOTSTRAP_IP_HERE#your-location-id.cloudflare-gateway.com
DNSOverTLS=yes
Domains=~.
EOF
```

- `DNSOverTLS=yes` is the strict setting — it does not silently fall back
  to plaintext DNS if TLS fails. (There's also `opportunistic`, which
  does fall back — don't use that here, it defeats the point.)
- `Domains=~.` makes this the default/preferred server for every domain,
  not just a specific search domain — without it, systemd-resolved may
  keep using other configured resolvers for some lookups.

**Restart it:**

```
sudo systemctl restart systemd-resolved
```

**Verify** (this replaces step 4 below for this path — `/etc/resolv.conf`
won't show `127.0.0.1` here, it'll still show the systemd-resolved stub):

```
resolvectl status                 # look for your IP#hostname under "DNS Servers"
                                   # and a "+DNSOverTLS" flag under Protocols

resolvectl query example.com      # resolves through the DoT path — check the
                                   # last line of output: "Data was acquired
                                   # via local or encrypted transport: yes"
                                   # confirms it went out over DoT, not plaintext

dig example.com                   # goes through the systemd-resolved stub,
                                   # which forwards it over DoT
```

Then test a domain covered by the block policy from step 2 the same way
— via `resolvectl query` or `dig`. (Want failover to `8.8.8.8` if Gateway
becomes unreachable? See
[Step 5: Optional fallback](#5-optional-fail-over-to-8888-if-gateway-becomes-unreachable).)

> **Tradeoff vs. `stubby`:** `stubby` is configured with TLS as its
> *only* transport — there is no non-TLS path for it to fall back to,
> even accidentally, by construction. systemd-resolved's `DNSOverTLS=yes`
> is also strict in practice (verified above — it fails the query rather
> than falling back when TLS validation fails), but it's one runtime
> setting on a resolver that supports plaintext too, rather than a
> transport that was never compiled/configured in. If you need the
> stronger structural guarantee, prefer `stubby`; if `DNSOverTLS=yes`
> behaving correctly is good enough for your test, this path works.

## 4. Verify it's working (Docker / native `stubby` paths)

From a shell with `stubby` running and `/etc/resolv.conf` pointed at
`127.0.0.1` (this is automatic in the Docker container; done manually in
the native `stubby` steps above):

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

## 5. Optional: fail over to 8.8.8.8 if Gateway becomes unreachable

Both `stubby` and systemd-resolved can be given a second, fallback
server. Read this before you reach for it, though — it doesn't do what
the name "UDP/53 fallback" might suggest.

> **What actually happens (verified by testing):** `8.8.8.8` itself
> speaks DNS-over-TLS. Both `stubby` and systemd-resolved always prefer
> TLS to any server that offers it, so when failover to `8.8.8.8`
> kicks in, it happens over **encrypted DoT (port 853)**, not plaintext
> UDP/53. I confirmed this with a packet capture during a live failover
> in both tools, and confirmed the mechanism itself by blocking
> `8.8.8.8`'s DoT port with `iptables` — even then, neither tool
> reliably dropped to plain UDP against `8.8.8.8` within a normal query
> timeout. Forcing genuine plaintext UDP would mean disabling TLS
> preference for the whole resolver, which also strips DoT from your
> Gateway queries — defeating the point of this whole setup. So: this
> section gives you **encrypted failover to a second resolver**, not a
> plaintext escape hatch.

### `stubby`

Add a second `upstream_recursive_servers` entry for `8.8.8.8` with no
`tls_auth_name`/`tls_port` (so `stubby` doesn't try to pin its
certificate to anything), and set `round_robin_upstreams: 0` so Gateway
is always tried first, in order — `8.8.8.8` is only touched once Gateway
is judged unreachable:

```
resolution_type: GETDNS_RESOLUTION_STUB
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
  - GETDNS_TRANSPORT_UDP
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
idle_timeout: 10000
listen_addresses:
  - 127.0.0.1@53
round_robin_upstreams: 0
upstream_recursive_servers:
  - address_data: PASTE_BOOTSTRAP_IP_HERE
    tls_auth_name: "your-location-id.cloudflare-gateway.com"
    tls_port: 853
  - address_data: 8.8.8.8
```

`GETDNS_TRANSPORT_UDP` is kept in the list as a last-resort transport in
case `8.8.8.8` ever stops answering DoT, but don't count on it firing —
in testing, failover consistently landed on DoT to `8.8.8.8`, and total
failover time was several seconds (`stubby` retries the primary a few
times first). If Gateway is unreachable in a way that times out silently
rather than actively refusing the connection, `stubby` can also exhaust
its own retry budget and return `SERVFAIL` before ever reaching the
fallback — treat this as best-effort resilience, not guaranteed
sub-second failover.

### systemd-resolved

List both servers on the `DNS=` line, Gateway first, and leave
`DNSOverTLS=yes` in place:

```
[Resolve]
DNS=PASTE_BOOTSTRAP_IP_HERE#your-location-id.cloudflare-gateway.com 8.8.8.8
DNSOverTLS=yes
Domains=~.
```

Same result as `stubby`: once Gateway is judged unreachable (roughly
10 seconds in testing), systemd-resolved fails over to `8.8.8.8` — over
DoT, since `DNSOverTLS=yes` applies to every configured server, not just
the first one.

> Don't reach for `FallbackDNS=` here — it's tempting because of the
> name, but it does nothing in this setup. Verified by testing:
> `FallbackDNS=` servers are only ever used when **no** `DNS=` servers
> are configured at all. Since this tutorial always sets `DNS=`
> explicitly, a `FallbackDNS=8.8.8.8` line is silently ignored.

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
- **(RHEL/Fedora) `systemctl start stubby` hangs / stays "waiting"** —
  Fedora's `stubby.service` unit orders itself after
  `network-online.target`. If NetworkManager hasn't marked a connection
  "online" yet (flaky DHCP, a just-completed boot, or a non-NM-managed
  interface), that target — and `stubby` behind it — can sit waiting
  indefinitely. Check `systemctl list-jobs` and `nmcli device status`;
  if the interface is stuck un-online, resolving that (or as a last
  resort `sudo systemctl stop NetworkManager-wait-online.service`) will
  unblock the queued `stubby` start.
- **(systemd-resolved path) `resolvectl status` doesn't show
  `+DNSOverTLS`** — check `journalctl -u systemd-resolved` for TLS
  handshake errors, confirm `DNSOverTLS=yes` (not `opportunistic`) is
  actually in the drop-in that got applied
  (`resolvectl status` prints which config file supplied each setting),
  and re-check the bootstrap IP is still current.

## Notes / limitations

- The bootstrap IP is resolved once, at startup. If the DoT endpoint's
  IP changes mid-session, restart `stubby` (or the container).
- No firewall-level enforcement (no `iptables`) in the Docker path —
  `/etc/resolv.conf` points everything at the local `stubby` resolver,
  which only speaks DoT upstream. This is a test client for Gateway's
  policy, not a sandbox against itself.
