# DNS Infrastructure Configuration Overview

This configuration implements a comprehensive DNS infrastructure for local network management.

## Architecture Components

### DNS Resolution Chain

1. **Client Request** → **Pi-hole (port 53)** → **Unbound (port 5335)** → **Upstream DNS**
2. **Local/mDNS** → **Avahi** → **systemd-resolved** (stub disabled)

### Service Ports

- Pi-hole FTL: 53 (DNS), 80 (Web Interface)
- Unbound: 5335 (Recursive DNS)
- Avahi: 5353 (mDNS)

### Key Features

- **Ad/Tracker Blocking**: Pi-hole filters malicious domains
- **Privacy**: Unbound provides recursive DNS resolution
- **Local Discovery**: Avahi enables .local domain resolution
- **Performance**: Optimized caching and minimal latency

## Network Configuration

### Static IP Setup

```text
Interface: eth0
IP: 192.168.0.53/24
Gateway: 192.168.0.1
DNS: 127.0.0.1 (local), 8.8.8.8, 9.9.9.9 (fallback)
```

### Security Considerations

- SSH restricted to local network only (ListenAddress bound to the static LAN IP)
- SSH accepts both password and public-key authentication; key-only mode (`AuthenticationMethods publickey`) is present but commented in the policy pending debugging of remote-login issues — see "SSH Debugging Quick Reference" below
- Unbound is source-built (1.26.x, hardened compile flags) and protected by local dpkg diversions so package upgrades cannot overwrite it
- IPv6 disabled (not in use)
- DNS-over-HTTPS/DNS-over-TLS not used; recursive resolution handled by local Unbound
- Rate limiting enabled for Avahi

### DHCP Authority

- DHCP is served by Pi-hole (`etc/pihole/pihole.toml`, `[dhcp] active = true`).
- Router DHCP should be disabled during cutover to avoid lease and resolver conflicts.
- Do not run router DHCP and Pi-hole DHCP at the same time.

## Maintenance Commands

### Service Management

```bash
# Check all DNS services
systemctl status pihole-FTL unbound avahi-daemon systemd-resolved

# Restart DNS stack
systemctl restart systemd-resolved unbound pihole-FTL

# Check DNS resolution
dig @127.0.0.1 google.com

# Check periodic health-check status
systemctl status dns-health-check.timer dns-health-check.service
journalctl -u dns-health-check.service -n 100 --no-pager
```

### Pi-hole Management

```bash
# Update blocklists
pihole -g

# Check query log
pihole tail

# Flush network tables
pihole networkflush
```

### Unbound Management

```bash
# Check configuration
unbound-checkconf

# Monitor statistics
unbound-control stats_noreset

# Flush cache
unbound-control reload
```

### Performance Observability

```bash
# Verify kernel network buffers expected by DNS stack
sysctl net.core.rmem_max net.core.wmem_max net.core.netdev_max_backlog

# Review Unbound cache behavior
unbound-control stats_noreset | grep -E 'total.cachehits|total.cachemiss'

# Check CPU governor state (expected: schedutil, set via cmdline.txt)
grep -H . /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null
```

## Troubleshooting

### SSH Debugging Quick Reference

For validating remote login when testing a freshly flashed host:

```bash
# Effective server config as sshd actually resolved it (drop-ins included)
sudo sshd -T | grep -Ei 'addressfamily|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|authenticationmethods|kbdinteractive'

# Validate config syntax before restarting sshd
sudo sshd -t

# Confirm sshd is listening on the expected (static) address only
ss -tlnp | grep ':22'

# Watch auth attempts server-side while a client connects
sudo journalctl -u ssh -f

# Client side: verbose handshake shows which auth methods are offered/tried
ssh -vv localadmin@192.168.0.53
```

Notes:

- `ListenAddress` binds only the static LAN IP, and `ssh.service` waits for
  `network-online.target` — if the address is wrong or the link is down, sshd
  will be unreachable or fail to bind. Check `systemctl status ssh` and the
  journal first.
- Key logins require correct permissions on the target: `~/.ssh` 700,
  `~/.ssh/authorized_keys` 600, home directory not group-writable.
- The build injects the build user's `id_ed25519.pub` into `authorized_keys`
  via `SSH_PUBKEY_USER1`; verify with `cat ~/.ssh/authorized_keys` on the host.
- When re-testing key-only mode, uncomment `PubkeyAuthentication yes` and
  `AuthenticationMethods publickey` in
  `etc/ssh/sshd_config.d/local_network_only.conf` — and update the matching
  assertions in `scripts/pre-release-check.sh`, which pins the current
  commented state.

### Common Issues

1. **DNS not resolving**: Check service status and port conflicts
2. **Slow resolution**: Verify upstream DNS servers
3. **Local domains not working**: Check Avahi configuration and mDNS setup
4. **Pi-hole not blocking**: Update blocklists and check configuration
5. **Intermittent client connectivity**: Ensure only one DHCP server is active (Pi-hole OR router)

### Log Locations

- Pi-hole (v6): `/var/log/pihole/pihole.log` and `/var/log/pihole/FTL.log`
- Unbound: `journalctl -u unbound` (file logging disabled: `verbosity: 0`, no `logfile` configured)
- Avahi: `journalctl -u avahi-daemon`
- systemd-resolved: `journalctl -u systemd-resolved`

## Backup and Recovery

### Backup Targets

- `/etc/pihole/`
- `/etc/unbound/`
- `/etc/avahi/`
- `/etc/systemd/resolved.conf.d/`
- `/etc/systemd/network/`

### Manual Backup Command

```bash
sudo tar -czf /var/backups/ke-net-screen-config-$(date +%F).tgz \
 /etc/pihole /etc/unbound /etc/avahi /etc/systemd/resolved.conf.d /etc/systemd/network
```

### Restore Command

```bash
sudo tar -xzf /var/backups/ke-net-screen-config-YYYY-MM-DD.tgz -C /
sudo systemctl restart systemd-resolved unbound pihole-FTL avahi-daemon
```

## Incident Response Quick Steps

1. Confirm DNS stack process state:

```bash
sudo systemctl status pihole-FTL unbound avahi-daemon systemd-resolved
```

1. Inspect health-check service output:

```bash
sudo journalctl -u dns-health-check.service -n 200 --no-pager
```

1. Validate resolver behavior:

```bash
dig @127.0.0.1 github.com
dig @127.0.0.1 pi-hole.net
```

1. If needed, restart the stack:

```bash
sudo systemctl restart systemd-resolved unbound pihole-FTL avahi-daemon
```
