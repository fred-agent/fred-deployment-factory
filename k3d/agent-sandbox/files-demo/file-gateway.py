# Copyright Thales 2026
# SPDX-License-Identifier: Apache-2.0
"""Temporary in-cluster TLS boundary for the k3d read-only mount test."""

import http.client
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PREFIX = "/knowledge-flow/v1/sandbox-mount/"
UPSTREAM = "knowledge-flow-backend.fred.svc.cluster.local"


class Handler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.forward()

    def do_PROPFIND(self):
        self.forward()

    def do_HEAD(self):
        self.forward()

    def do_GET(self):
        self.forward()

    def forward(self):
        path = self.path.split("?", 1)[0]
        if not path.startswith(PREFIX) or ".." in path.split("/"):
            self.send_error(404)
            return
        try:
            body_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400)
            return
        if body_length < 0 or body_length > 16384:
            self.send_error(413)
            return
        body = self.rfile.read(body_length) if body_length else None
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in {"host", "connection", "content-length"}
        }
        try:
            client = http.client.HTTPConnection(UPSTREAM, 8000, timeout=30)
            client.request(self.command, self.path, body=body, headers=headers)
            upstream = client.getresponse()
            body = upstream.read(21 * 1024 * 1024)
            if upstream.read(1):
                self.send_error(502)
                return
            self.send_response(upstream.status)
            for key, value in upstream.getheaders():
                if key.lower() not in {"transfer-encoding", "connection", "content-length"}:
                    self.send_header(key, value)
            self.send_header(
                "Content-Length",
                upstream.getheader("Content-Length", "0")
                if self.command == "HEAD"
                else str(len(body)),
            )
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            client.close()
        except (OSError, http.client.HTTPException):
            self.send_error(502)

    def log_message(self, *_args):
        pass


server = ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain("/tls/tls.crt", "/tls/tls.key")
server.socket = tls.wrap_socket(server.socket, server_side=True)
server.serve_forever()
