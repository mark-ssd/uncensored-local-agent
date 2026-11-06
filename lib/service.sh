# shellcheck shell=bash
# Run llama-swap as a per-user service: launchd (macOS), systemd --user (Linux),
# or a plain background process with a pidfile when neither is available (containers, CI).
# The mode chosen at setup is saved (ULA_SERVICE in ula.env) so every later shell agrees.

SVC_LABEL="com.ula.llama-swap"
SVC_PLIST="$HOME/Library/LaunchAgents/$SVC_LABEL.plist"
SVC_UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/ula-llama-swap.service"
SVC_PID="$ULA_RUN/llama-swap.pid"
SWAP_BIN() { echo "$ULA_OPT/llama-swap/current/llama-swap"; }

svc_mode() {
  if [ -n "${ULA_SERVICE:-}" ]; then echo "$ULA_SERVICE"; return; fi
  if [ "$ULA_OS" = macos ]; then echo launchd; return; fi
  if have systemctl && systemctl --user show-environment >/dev/null 2>&1; then echo systemd; return; fi
  echo process
}

# gui/<uid> exists only with a console login; fall back to user/<uid> over SSH / headless.
svc_domain() {
  if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then echo "gui/$(id -u)"; else echo "user/$(id -u)"; fi
}

launchd_gone() {
  local i=0
  while launchctl print "$(svc_domain)/$SVC_LABEL" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -ge 30 ] && return 1; sleep 1
  done
}

xml_esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

svc_install() {
  mkdir -p "$ULA_LOGS" "$ULA_RUN"
  case "$(svc_mode)" in
    launchd)
      mkdir -p "$(dirname "$SVC_PLIST")"
      {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0"><dict>'
        echo "  <key>Label</key><string>$SVC_LABEL</string>"
        echo '  <key>ProgramArguments</key><array>'
        for a in "$(SWAP_BIN)" --config "$SWAP_YAML" --listen "$ULA_HOST:$ULA_PORT" --watch-config; do
          printf '    <string>%s</string>\n' "$(xml_esc "$a")"
        done
        echo '  </array>'
        echo '  <key>RunAtLoad</key><true/>'
        echo '  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>'
        echo '  <key>ProcessType</key><string>Interactive</string>'
        echo "  <key>StandardOutPath</key><string>$(xml_esc "$ULA_LOGS/llama-swap.log")</string>"
        echo "  <key>StandardErrorPath</key><string>$(xml_esc "$ULA_LOGS/llama-swap.log")</string>"
        echo '  <key>EnvironmentVariables</key><dict>'
        echo "    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>"
        echo '  </dict>'
        echo '</dict></plist>'
      } > "$SVC_PLIST"
      launchctl bootout "$(svc_domain)/$SVC_LABEL" 2>/dev/null || true
      launchd_gone || warn "previous llama-swap job is still exiting"
      launchctl bootstrap "$(svc_domain)" "$SVC_PLIST" 2>/dev/null ||
        { sleep 2; launchctl bootstrap "$(svc_domain)" "$SVC_PLIST"; } || die "launchctl bootstrap failed"
      ;;
    systemd)
      mkdir -p "$(dirname "$SVC_UNIT")"
      local exec q a
      exec=""
      for a in "$(SWAP_BIN)" --config "$SWAP_YAML" --listen "$ULA_HOST:$ULA_PORT" --watch-config; do
        q="$(printf '%s' "$a" | sed 's/\\/\\\\/g; s/"/\\"/g')"; exec="$exec \"$q\""
      done
      cat > "$SVC_UNIT" <<EOF
[Unit]
Description=uncensored-local-agent: llama-swap model router
After=network.target

[Service]
ExecStart=${exec# }
Restart=on-failure
RestartSec=3
StandardOutput=append:$ULA_LOGS/llama-swap.log
StandardError=append:$ULA_LOGS/llama-swap.log

[Install]
WantedBy=default.target
EOF
      systemctl --user daemon-reload
      systemctl --user enable ula-llama-swap.service >/dev/null 2>&1 || die "systemctl --user enable failed"
      systemctl --user restart ula-llama-swap.service || die "systemctl --user restart failed (no user session? try ULA_SERVICE=process)"
      if have loginctl && ! case "$(loginctl show-user "$(id -un)" 2>/dev/null || true)" in *Linger=yes*) true ;; *) false ;; esac; then
        info "tip: 'sudo loginctl enable-linger $(id -un)' keeps the service running after logout"
      fi
      ;;
    process) svc_stop; svc_start ;;
  esac
}

svc_start() {
  case "$(svc_mode)" in
    launchd)
      [ -f "$SVC_PLIST" ] || { svc_install; return; }
      launchctl kickstart "$(svc_domain)/$SVC_LABEL" 2>/dev/null || launchctl bootstrap "$(svc_domain)" "$SVC_PLIST" ;;
    systemd)
      [ -f "$SVC_UNIT" ] || { svc_install; return; }
      systemctl --user start ula-llama-swap.service || die "systemctl --user start failed (no user session? try ULA_SERVICE=process ula up)" ;;
    process)
      if svc_running_pid; then return 0; fi
      mkdir -p "$ULA_LOGS" "$ULA_RUN"
      nohup "$(SWAP_BIN)" --config "$SWAP_YAML" --listen "$ULA_HOST:$ULA_PORT" --watch-config >> "$ULA_LOGS/llama-swap.log" 2>&1 &
      echo $! > "$SVC_PID" ;;
  esac
}

svc_stop() {
  case "$(svc_mode)" in
    launchd) launchctl bootout "$(svc_domain)/$SVC_LABEL" 2>/dev/null || true; launchd_gone || true ;;
    systemd) systemctl --user stop ula-llama-swap.service 2>/dev/null || true ;;
    process)
      if svc_running_pid; then
        kill "$(cat "$SVC_PID")" 2>/dev/null || true
        local i=0; while svc_running_pid && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
      fi
      rm -f "$SVC_PID" ;;
  esac
}

svc_running_pid() { [ -f "$SVC_PID" ] && kill -0 "$(cat "$SVC_PID")" 2>/dev/null; }

svc_uninstall() {
  svc_stop
  case "$(svc_mode)" in
    launchd) rm -f "$SVC_PLIST" ;;
    systemd) systemctl --user disable ula-llama-swap.service 2>/dev/null || true; rm -f "$SVC_UNIT"; systemctl --user daemon-reload 2>/dev/null || true ;;
  esac
}

# Wait until llama-swap answers (its /health needs no API key).
svc_wait() {
  local i=0
  until curl -fsS --max-time 2 "http://$ULA_HOST:$ULA_PORT/health" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -ge "${1:-30}" ] && return 1; sleep 1
  done
}
