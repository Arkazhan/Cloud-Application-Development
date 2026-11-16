import json
import os
import signal
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3

TOPIC_ARN = os.environ.get("TOPIC_ARN")          # configuration comes from the environment
sns = boto3.client("sns") if TOPIC_ARN else None


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":                # cheap: never touches AWS
            self._send(200, {"status": "ok"})
        else:
            self._send(200, {"service": "cad-sis3", "host": socket.gethostname(),
                             "version": os.environ.get("APP_VERSION", "dev")})

    def do_POST(self):
        if self.path != "/orders":
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            order = json.loads(self.rfile.read(length) or b"{}")
            order_id = str(order["orderId"])
        except (ValueError, KeyError, TypeError):
            self._send(400, {"error": "JSON body with 'orderId' is required"})
            return
        if sns is None:
            self._send(503, {"error": "TOPIC_ARN is not configured"})
            return
        # the domain event: "an order was placed"; consumers decide what to do with it
        sns.publish(TopicArn=TOPIC_ARN, Message=json.dumps(order))
        print(json.dumps({"msg": "OrderPlaced published", "orderId": order_id}), flush=True)
        self._send(202, {"published": order_id})

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)            # stdout -> CloudWatch Logs


def main():
    server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)   # not localhost

    def stop(signum, frame):
        print("SIGTERM received, shutting down", flush=True)
        threading.Thread(target=server.shutdown).start()

    signal.signal(signal.SIGTERM, stop)
    print("listening on 0.0.0.0:8080", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
