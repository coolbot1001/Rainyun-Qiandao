#!/bin/sh
# Render Web Service 启动脚本
# 作用：前台启动一个 HTTP 健康检查服务，后台运行容器内定时签到。
# 这样 Render 能检测到开放端口，外部保活服务访问 URL 时也能得到正常响应。
set -e

PORT="${PORT:-10000}"

# 防止 entrypoint 再次进入 Render Web 模式导致递归。
export RENDER_WEB_MODE=false

# Web Service 模式需要让签到调度器常驻后台运行。
export CRON_MODE=true

cleanup() {
  echo "收到停止信号，正在关闭后台定时任务..."
  if [ -n "${SCHEDULER_PID:-}" ]; then
    kill "$SCHEDULER_PID" 2>/dev/null || true
    wait "$SCHEDULER_PID" 2>/dev/null || true
  fi
}
trap cleanup INT TERM

echo "=== Render Web Service 模式启用 ==="
echo "HTTP 健康检查端口: ${PORT}"
echo "后台定时计划: ${CRON_SCHEDULE:-0 8 * * *}"

/app/entrypoint.sh &
SCHEDULER_PID="$!"
echo "后台定时任务 PID: ${SCHEDULER_PID}"

# 启动一个极简 HTTP 服务：
# - 监听 0.0.0.0:$PORT，满足 Render Web Service 的端口探测
# - GET / 返回运行状态，便于外部 cron / UptimeRobot 保活
# - 不触发签到，签到仍由后台 supercronic 按 CRON_SCHEDULE 执行
python -u - <<'PY'
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "10000"))

class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (
            "Rainyun-Qiandao is running.\n"
            "This endpoint is only for Render health check / keep-alive.\n"
            "Sign-in is scheduled by the background cron process.\n"
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()

    def log_message(self, fmt, *args):
        print("HTTP", self.address_string(), "-", fmt % args)

server = ThreadingHTTPServer(("0.0.0.0", PORT), HealthHandler)
print(f"HTTP health server listening on 0.0.0.0:{PORT}", flush=True)
server.serve_forever()
PY
