# Sourced by build-app.sh. Return 2 for a live or unconfirmed owner.
deskcapture_acquire_build_lock() {
  local lock_path="$1" inherited_owner="${2:-}" recorded_owner="" retry
  build_owns_lock=0
  for retry in 1 2 3; do
    if mkdir "$lock_path" 2>/dev/null; then
      print -r -- "$$" > "$lock_path/pid"
      build_owns_lock=1
      return 0
    fi
    recorded_owner="$(cat "$lock_path/pid" 2>/dev/null || true)"
    if [[ -n "$inherited_owner" && "$recorded_owner" == "$inherited_owner" ]] && kill -0 "$inherited_owner" 2>/dev/null; then
      return 0
    fi
    # An absent PID can be another builder between mkdir and writing pid.
    # Never reclaim that directory or a lock whose process is still alive.
    if [[ "$recorded_owner" != <-> ]] || kill -0 "$recorded_owner" 2>/dev/null; then
      print -u2 -- "另一个编译或检查任务正在运行（进程：${recorded_owner:-正在初始化}），本次未修改构建结果。"
      return 2
    fi
    # Serialize recovery, then recheck ownership before removing only our
    # known lock files. rmdir leaves unexpected contents untouched.
    if ! mkdir "$lock_path/reclaim" 2>/dev/null; then
      print -u2 -- "正在回收上次中断留下的构建锁，请稍后重试。"
      return 2
    fi
    if [[ "$(cat "$lock_path/pid" 2>/dev/null || true)" == "$recorded_owner" ]] && ! kill -0 "$recorded_owner" 2>/dev/null; then
      rm -f "$lock_path/pid"
    fi
    rmdir "$lock_path/reclaim" 2>/dev/null || true
    if rmdir "$lock_path" 2>/dev/null; then
      print -- "已清理上次中断留下的构建锁。"
    fi
  done
  print -u2 -- "无法获取构建锁，本次未修改构建结果。"
  return 2
}
