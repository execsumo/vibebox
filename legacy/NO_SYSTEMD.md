# Running a process without systemd

This container has no init system. PID 1 is `scripts/entrypoint`, which execs
`sshd` at the end of its own setup — there is no `systemd`, no `launchd`, no
`/run/systemd/system`. Anything that expects `systemctl enable --now foo` (or
tells you to install/start a service) needs to be supervised by hand instead.

If you just typed a `systemctl` command and landed here: that's what
`systemctl` in this box tells you to do — it's a stub, not the real thing.

There are two shapes of tool, and they need different treatment.

## 1. The tool already daemonizes itself

Some tools have their own "detach and keep running after my parent shell
exits" mode (double-forking, `nohup` + a trap, etc.). For these you only need
a thin start/stop wrapper around that mode — no restart-on-crash loop
required, since the tool already survives its launcher exiting.

A real example already in this image: `/opt/hermes-webui/ctl.sh` (installed
by the Hermes WebUI build step). It backgrounds the process with `nohup` and
traps `HUP` so a restart doesn't kill it, and exposes a plain
`start|stop|restart|status|logs` interface.

## 2. The tool only runs in the foreground

Most CLIs only offer a foreground mode — this is the common case. Wrap it in
a restart loop, run that loop as its own session leader (so `stop` can kill
the loop *and* whatever it spawned in one shot), and log to a file instead of
your terminal:

```bash
#!/bin/bash
NAME="mytool"
LOGFILE="$HOME/.vibebox/$NAME/daemon.log"
PIDFILE="$HOME/.vibebox/$NAME/supervisor.pid"
mkdir -p "$(dirname "$LOGFILE")"

is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "${1:-start}" in
  start)
    is_running && { echo "$NAME already running"; exit 0; }
    # setsid makes the supervisor its own session/process-group leader, so
    # `stop` can kill it and the child it spawns in one shot via the negative
    # (group) pid — a plain `kill $pid` would leave the child orphaned.
    setsid env LOGFILE="$LOGFILE" bash -c '
      while true; do
        mytool-command-here >>"$LOGFILE" 2>&1
        sleep 2   # backoff, so an instantly-failing command does not spin the CPU
      done
    ' </dev/null >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    disown
    echo "$NAME started (pid $(cat "$PIDFILE"))"
    ;;
  stop)
    if is_running; then
      pid="$(cat "$PIDFILE")"
      kill -TERM -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      rm -f "$PIDFILE"
      echo "$NAME stopped"
    else
      echo "$NAME not running"
    fi
    ;;
  restart) "$0" stop; "$0" start ;;
  status) is_running && echo "$NAME running (pid $(cat "$PIDFILE"))" || echo "$NAME not running" ;;
  logs) exec tail -n 200 -f "$LOGFILE" ;;
  *) echo "usage: $NAME {start|stop|restart|status|logs}" >&2; exit 1 ;;
esac
```

Two real examples already in this image, both built from exactly this
template: `scripts/hermes-gateway` (supervises `hermes gateway run
--external-supervisor`, which exits with code 75 whenever it wants a
restart) and `scripts/droid-daemon` (supervises `droid daemon
--remote-access`, which has no such signal — it just restarts on any exit).
Copying one of those as a starting point is usually less work than
retyping the template above.

## Starting it automatically at boot

If you want your supervisor running as soon as the container starts, add a
call to it in `scripts/entrypoint` — see the existing blocks there that start
`hermes-gateway` and `droid-daemon` (each guarded by `command -v <tool>` so
it's a no-op when the tool isn't installed) for the pattern to copy.
