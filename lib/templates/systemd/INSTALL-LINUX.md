# Linux systemd-user install

Place .service + .timer files in `~/.config/systemd/user/`:

```
mkdir -p ~/.config/systemd/user
cp <BRAND_SLUG>-memory-decay.{service,timer}  ~/.config/systemd/user/
cp <BRAND_SLUG>-sprint-standup.{service,timer} ~/.config/systemd/user/
```

Enable + start each timer:

```
systemctl --user enable --now <BRAND_SLUG>-memory-decay.timer
systemctl --user enable --now <BRAND_SLUG>-sprint-standup.timer
```

Check status:

```
systemctl --user list-timers
systemctl --user status <BRAND_SLUG>-memory-decay.timer
journalctl --user -u <BRAND_SLUG>-memory-decay.service -n 50
```

If `systemd-user` is not available (rare; minimal containers), fall back to cron:

```
crontab -e
# Add:
0 0 * * * cd <REPO_ROOT> && node scripts/sprint-memory-decay.mjs >> .swarm/memory-decay.log 2>&1
0 9 * * * cd <REPO_ROOT> && SLUG=$(bash scripts/sprint-status.sh --slug-only) && [ -n "$SLUG" ] && node scripts/sprint-standup.mjs "$SLUG"
```
