# web-hub-bootstrap

**Public mirror** of the two bootstrap scripts used to deploy
[web-hub](https://github.com/Lingo2018/web-hub) (private) to a clean
customer VPS. Source of truth is the private web-hub repo; these
files are auto-synced by `scripts/sync-bootstrap-public.sh` over there.

> Do NOT edit files here directly — changes belong upstream.

## Files

| File | Purpose |
|---|---|
| `bootstrap-vps-root.sh` | Phase 1, root: deploy-user, SSH harden, docker / Caddy / ufw install |
| `bootstrap-vps-deploy.sh` | Phase 2, deploy: clone web-hub + install + reverse proxy + backup cron |
| `.bootstrap.env.example` | Phase 2 config template |

## One-liner usage

### Phase 1 (run as root on a fresh Ubuntu 22.04 VPS)

```bash
SSH_PUBKEY="ssh-ed25519 AAAA... your-pubkey" \
  bash <(curl -fsSL https://raw.githubusercontent.com/Lingo2018/web-hub-bootstrap/main/bootstrap-vps-root.sh)
```

### Phase 2 (run as the deploy user, after Phase 1)

```bash
curl -fsSL https://raw.githubusercontent.com/Lingo2018/web-hub-bootstrap/main/bootstrap-vps-deploy.sh -o b.sh
bash b.sh                    # generates ~/.bootstrap.env template, exits
nano ~/.bootstrap.env        # fill DOMAIN (and optional values)
bash b.sh                    # actually deploys
```

## Full operator playbook

See the upstream `docs/ops/first-customer-playbook.md` for the
complete sequence (sandbox drill, monitoring checklist, partner
role split, common-failure matrix).

## License

MIT — these are deployment helpers; no business logic.
