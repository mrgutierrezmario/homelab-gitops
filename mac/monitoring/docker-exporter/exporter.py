"""Per-container CPU, memory and network for Prometheus, from the Docker API.

Replaces cAdvisor here: cAdvisor cannot identify containers when Docker
Desktop uses the containerd image store ("failed to identify the read-write
layer ID"). This asks Docker for the same numbers `docker stats` shows.
Standard library only; reads the socket mounted at /var/run/docker.sock.
"""
import http.client, json, socket
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SOCK = "/var/run/docker.sock"


class UnixConn(http.client.HTTPConnection):
    def __init__(self):
        super().__init__("localhost", timeout=10)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        self.sock.connect(SOCK)


def get(path):
    conn = UnixConn()
    try:
        conn.request("GET", path)
        return json.loads(conn.getresponse().read())
    finally:
        conn.close()


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def sample(c):
    s = get(f"/containers/{c['Id']}/stats?stream=false&one-shot=true")
    labels = c.get("Labels") or {}
    lab = '{name="%s",project="%s",service="%s"}' % (
        esc(c["Names"][0].lstrip("/")),
        esc(labels.get("com.docker.compose.project", "")),
        esc(labels.get("com.docker.compose.service", "")),
    )
    mem = s.get("memory_stats") or {}
    # Working set, as `docker stats` reports it: usage minus reclaimable page cache.
    ws = mem.get("usage", 0) - (mem.get("stats") or {}).get("inactive_file", 0)
    nets = (s.get("networks") or {}).values()
    return [
        f"container_memory_working_set_bytes{lab} {max(ws, 0)}",
        f"container_memory_limit_bytes{lab} {mem.get('limit', 0)}",
        f"container_cpu_usage_seconds_total{lab} {(s.get('cpu_stats') or {}).get('cpu_usage', {}).get('total_usage', 0) / 1e9}",
        f"container_network_receive_bytes_total{lab} {sum(n.get('rx_bytes', 0) for n in nets)}",
        f"container_network_transmit_bytes_total{lab} {sum(n.get('tx_bytes', 0) for n in nets)}",
    ]


def metrics():
    containers = get("/containers/json")
    out = [
        "# TYPE container_memory_working_set_bytes gauge",
        "# TYPE container_memory_limit_bytes gauge",
        "# TYPE container_cpu_usage_seconds_total counter",
        "# TYPE container_network_receive_bytes_total counter",
        "# TYPE container_network_transmit_bytes_total counter",
    ]
    with ThreadPoolExecutor(max_workers=8) as pool:
        for lines in pool.map(lambda c: _safe(sample, c), containers):
            out += lines
    out.append(f"docker_exporter_containers {len(containers)}")
    return "\n".join(out) + "\n"


def _safe(fn, c):
    try:
        return fn(c)
    except Exception:
        return []  # a container that stopped mid-scrape


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404); self.end_headers(); return
        body = metrics().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("", 9417), Handler).serve_forever()
