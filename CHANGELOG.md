# Changelog

All notable changes to this project are written down here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Alert rules for Node Exporter being down, high CPU, high memory, memory pressure, a disk
  that's almost full or will be full within a day, overheating and a low battery. For now
  they're shown in Prometheus at `http://127.0.0.1:9090/alerts`; notifications come later.
- Alertmanager, which receives alerts from Prometheus and groups them.
- Container monitoring with cAdvisor: CPU, memory, network and disk per container, in a
  new "Containers" row at the top of the dashboard, plus alerts for a container that keeps
  restarting or runs out of memory.

## [0.3.0] - 2026-09-28

### Added

- Automatic checks on every push and pull request (GitHub Actions). They lint the
  scripts and config files, then do a full install, uninstall with `--remove-data`,
  and check that nothing was left behind.
- Dependabot opens a pull request when Grafana, Prometheus or Node Exporter has a new
  version, and the checks above test it before it's merged.
- CI status badge in the README.

### Changed

- Updated Prometheus to 3.15.0, Node Exporter to 1.12.1 and Grafana to 13.2.2.

## [0.2.0] - 2026-09-25

### Added

- `scripts/install.sh`: one command to install. It checks your machine first and lists
  every problem it finds with how to fix it, asks whether Grafana should be reachable
  from your home network, creates `.env`, starts the stack and waits until it's really
  working. Safe to run again, it keeps your `.env` and your data.
- `scripts/update.sh`: updates to the newest release, shows what changed, and checks the
  stack still works afterwards. `--to <version>` goes to a specific release, which is also
  how you roll back. Never touches your `.env` or your data.
- `scripts/uninstall.sh`: removes the containers and keeps your data. `--remove-data`
  deletes all metrics, Grafana's database and `.env` for good, after you type `delete`
  to confirm.

### Changed

- Setup messages are clearer, and coloured when shown in a terminal. Set `NO_COLOR=1`
  to turn colours off.

## [0.1.0] - 2026-09-25

First release. Monitors the Linux machine it's installed on.

### Added

- Docker Compose stack with Node Exporter (collects the stats), Prometheus (stores them)
  and Grafana (draws the graphs).
- A ready-made "Laptop Overview" dashboard that loads by itself, with sections for CPU,
  memory, disk, network, hardware (battery, temperatures) and resource pressure.
- `scripts/setup.sh`, which creates your `.env` and fills it with a randomly generated
  Grafana password. It refuses to run if `.env` already exists, so it never overwrites
  a real password.
- Optional `.env` settings: `GRAFANA_BIND_ADDR` to open Grafana to your home network,
  and `GRAFANA_PORT` if port 3000 is already taken.
- Safe defaults: everything listens on `127.0.0.1` only, and Prometheus keeps 30 days of
  data capped at 5 GB, so it can never fill your disk.
- Works on SELinux distros like Fedora and RHEL.
- The power source panel works on any laptop, whatever the charger is called.
- Disk model and serial number labels from the host's udev data.

[Unreleased]: https://github.com/santosh-kafle/prometheus-grafana-monitoring/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/santosh-kafle/prometheus-grafana-monitoring/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/santosh-kafle/prometheus-grafana-monitoring/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/santosh-kafle/prometheus-grafana-monitoring/releases/tag/v0.1.0
