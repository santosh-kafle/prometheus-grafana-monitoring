# Homelab Monitoring

See what your Linux machine is doing: CPU, memory, disks, network, temperatures and
battery, on a ready-made dashboard. Built with Prometheus and Grafana, the same tools used
to monitor production servers, and set up so a beginner can install it with one command
and understand how every piece works.

![Dashboard overview](docs/images/dashboard.png)

Further down the same dashboard: network, battery, temperatures and resource pressure.

![Hardware and pressure panels](docs/images/hardware.png)

## What you get

- A dashboard that's there as soon as you log in. Nothing to import or click through.
- 30 days of history, capped at 5 GB so it can never fill your disk.
- Private by default: nothing is reachable from other devices unless you choose that
  during install.
- An installer that checks your machine first and tells you exactly what to fix if
  something's missing.
- Explanations of every decision, so you learn how monitoring works, not just that it does.

## Requirements

- **Linux.** A laptop, desktop, old PC, home server or Raspberry Pi all work.
- **Docker Engine** with the **Compose plugin** (`docker compose`, not the old `docker-compose`).
  Your user needs to be able to run `docker` without `sudo`.
- **git**, **openssl** and **curl**. Most distros already have them.
- Ports **9090**, **9100** and **3000** free. Grafana's port can be changed.

**Not supported:** macOS and Windows (Docker runs inside a VM there, so you'd be
monitoring the VM), rootless Docker, and Podman.

Don't worry about checking all of this yourself. The installer checks it for you.

## Install

```bash
git clone https://github.com/santosh-kafle/prometheus-grafana-monitoring.git
cd prometheus-grafana-monitoring
./scripts/install.sh
```

The installer asks you one question:

- **Only this machine.** Pick this on a laptop or desktop you sit in front of.
- **Any device on your home network.** Pick this on a server with no screen, so you can
  open the dashboard from your laptop or phone.

When it's done, it prints the address to open. Log in as `admin`. The password was
generated for you and saved in `.env`. To see it:

```bash
grep GF_SECURITY_ADMIN_PASSWORD .env
```

The dashboard is under **Dashboards → Laptop → Laptop Overview**.

Running the installer again is safe. It keeps your settings and your data.

### Installer options

| Option | What it does |
| --- | --- |
| `--local` | Only this machine can open Grafana (the default) |
| `--lan` | Devices on your home network can open Grafana |
| `--yes` | Don't ask anything, use the defaults |
| `--help` | Show all options |

## Everyday use

```bash
docker compose ps            # is everything running?
docker compose logs grafana  # what went wrong?
docker compose restart       # restart everything
docker compose down          # stop (your data is kept)
docker compose up -d         # start again
```

The stack starts on its own after a reboot, as long as Docker does. The installer warns
you if it doesn't.

**Updating and uninstalling:** dedicated scripts are coming in the next release. Until
then:

```bash
git pull && docker compose pull && docker compose up -d   # update
docker compose down                                       # uninstall, keep your data
docker compose down -v && rm .env                         # uninstall and delete ALL data
```

## Settings

Settings live in `.env`, which the installer creates for you. After changing it, run
`docker compose up -d` to apply.

| Setting | Default | What it does |
| --- | --- | --- |
| `GF_SECURITY_ADMIN_USER` | `admin` | Grafana username |
| `GF_SECURITY_ADMIN_PASSWORD` | generated | Grafana password (see below before changing it) |
| `GRAFANA_BIND_ADDR` | `127.0.0.1` | `127.0.0.1` = this machine only, `0.0.0.0` = your home network too |
| `GRAFANA_PORT` | `3000` | Change it if another app already uses 3000 |

### Changing the Grafana password

Grafana only reads the password from `.env` the **first time** it starts. After that, the
password is stored in Grafana's own database, so editing `.env` does nothing. Change it in
Grafana (your profile → Change password), or run:

```bash
docker exec -it grafana grafana cli admin reset-admin-password <new-password>
```

### Opening Grafana to your home network

Set `GRAFANA_BIND_ADDR=0.0.0.0` in `.env` (or choose it during install), then run
`docker compose up -d`. If you have a firewall on, allow the port as well:

```bash
sudo ufw allow 3000/tcp                                                        # ufw
sudo firewall-cmd --permanent --add-port=3000/tcp && sudo firewall-cmd --reload  # firewalld
```

Only Grafana is ever opened up, because it's the only piece with a login. Prometheus and
Node Exporter always stay private to the machine.

## Some panels are empty. Is that broken?

Probably not. Some panels only have data on some hardware:

| Panel | Empty when |
| --- | --- |
| Battery, power source | The machine has no battery, e.g. a desktop or server |
| Temperatures, sensors | Virtual machines, and some boards that don't expose sensors |
| CPU frequency | Virtual machines |
| Pressure | Older kernels (before 4.20), or kernels built without PSI |

If *everything* is empty, check each piece from the bottom up. Whichever step fails first
is the broken one:

```bash
curl -s localhost:9100/metrics | head                 # 1. is Node Exporter collecting?
curl -s 127.0.0.1:9090/api/v1/targets | grep health   # 2. is Prometheus collecting? both should say "up"
curl -s 127.0.0.1:3000/api/health                     # 3. is Grafana alive?
```

If a container isn't behaving the way the config says, check what it actually got. The
file and the running container can drift apart:

```bash
docker inspect grafana --format '{{range .Mounts}}{{.Destination}}{{println}}{{end}}'
docker inspect node-exporter --format '{{range .Config.Cmd}}{{println .}}{{end}}'
```

## How it works

Monitoring is split into three jobs, and each one has its own tool:

| Tool | What it does | Port |
| --- | --- | --- |
| **Node Exporter** | Reads the kernel's stats from `/proc` and `/sys` and serves them as a web page | 9100 |
| **Prometheus** | Fetches that page every 15 seconds and keeps the history in a database | 9090 |
| **Grafana** | Asks Prometheus for numbers and draws the graphs | 3000 |

The flow is **Node Exporter → Prometheus → Grafana**.

Node Exporter has no memory. Ask it for stats and it tells you what's true right now, and
nothing else. Prometheus is what turns that into history. Grafana stores no metrics at all;
every graph is a live query to Prometheus.

### Everything is set up from files

Grafana's data source and dashboard come from **provisioning** files in this repo, not
from clicking around in the UI. Anything set up through the UI only lives in Grafana's
database, which isn't in Git, so it wouldn't survive a reinstall and couldn't be shared.
With files, `git clone` and one command give everyone the same working dashboard.

For the same reason, the dashboard is **read-only in the UI**. To change a panel, edit
`grafana/dashboards/laptop-overview.json`, save, and refresh your browser. Grafana checks
the folder every 10 seconds.

### What's deliberately not in Git

- **Your metrics and Grafana's database** live in Docker volumes, which Docker keeps in
  `/var/lib/docker/volumes`. They're outside the project folder entirely, so they can't be
  committed by accident.
- **Your password** lives in `.env`, which is in `.gitignore`. `.env.example` is committed
  so you can see which settings exist, but it never holds a real value. The installer
  generates the real `.env` on your machine, so the password is never typed, shared or
  committed.

### Why everything uses host networking

This is the one unusual decision, so it's worth explaining.

Node Exporter's job is reading the kernel's files. But every container gets its **own**
network namespace, and network stats come from `/proc/net/dev`, which is different in
each namespace. So a normal containerised Node Exporter reports on the container's own
virtual network card. It would show an `eth0` your machine doesn't have, and never show
your real Wi-Fi or Ethernet. Mounting `/proc` into the container doesn't fix this, because
`/proc/net` is a link to `/proc/self/net`, and `self` always means the process doing the
reading.

The only real fix is `network_mode: host`, which puts the process in the host's network
namespace.

Once Node Exporter is there, Prometheus has to cross from Docker's network to the host's to
reach it. That's surprisingly fragile: `host.docker.internal` can point at the wrong bridge,
the bridge can be down, and firewalls like `ufw` block bridge-to-host traffic. Putting
Prometheus and Grafana on the host network as well turns every connection into a plain
`localhost` one, which removes that whole class of problems.

The trade-off: no Docker DNS names between the services, and no network isolation between
them. For a single machine that's fine.

Side effect: with `network_mode: host`, a `ports:` block does nothing (Docker even warns
about it). The address each service listens on is set on the process instead, which is why
every service has an explicit listen address.

### Other decisions

- **Image versions are pinned** (`v1.9.1`, `v3.6.0`, `13.2.1`) instead of `:latest`, so
  a clone next year gets the same software and the dashboard still works.
- **Virtual network interfaces are ignored** (`veth*`, `br-*`, `docker*`). Every container
  you start creates one with a random name, and each name would become a permanent new
  entry in Prometheus.
- **The data source has a fixed ID** (`uid: prometheus`). Grafana makes a random one
  otherwise, which would differ on every install and break every panel with "data source
  not found".
- **Node Exporter can only read the host, never write to it.** Every host folder is
  mounted read-only (`:ro`).

## What's in the repo

```
docker-compose.yml                              the three services
prometheus/prometheus.yml                       what to collect and how often
grafana/provisioning/datasources/prometheus.yml connects Grafana to Prometheus
grafana/provisioning/dashboards/dashboards.yml  tells Grafana where dashboards live
grafana/dashboards/laptop-overview.json         the dashboard itself
scripts/install.sh                              the installer
scripts/setup.sh                                creates .env with a generated password
scripts/lib.sh                                  shared helpers for the scripts
.env.example                                    which settings exist
docs/images/                                    screenshots for this README
CHANGELOG.md                                    what changed in each release
```

## License

[MIT](LICENSE). Free to use, change and share.
