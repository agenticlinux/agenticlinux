# Say what the stage service is doing: bootc draws progress bars only on a
# terminal, and the service has none
if [ -t 1 ]; then
  case "$(systemctl is-active agenticlinux-stage 2>/dev/null)" in
    active | activating)
      echo "AgenticLinux is downloading in the background: journalctl -fu agenticlinux-stage" >&2 ;;
    inactive)
      [ -n "$(systemctl show -p ExecMainExitTimestamp --value agenticlinux-stage)" ] &&
        [ "$(systemctl show -p ExecMainStatus --value agenticlinux-stage)" = 0 ] &&
        echo "AgenticLinux is staged: restart this VM to boot it" >&2 ;;
  esac
fi
