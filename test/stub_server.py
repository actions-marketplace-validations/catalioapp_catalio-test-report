"""Stand-in for Catalio's token and ingest endpoints, for test/post.bats.

Usage: python3 stub_server.py DIR

Writes the port it bound to DIR/port, then appends one JSON line per request to
DIR/requests.jsonl: {"path", "authorization", "fields"}. Multipart fields are
recorded except the report file itself. Response codes come from
STUB_TOKEN_STATUS and STUB_INGEST_STATUS (default 200 and 202).
"""

import email.parser
import email.policy
import json
import os
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

OUT = sys.argv[1]


def multipart_fields(content_type, body):
    message = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
        b"Content-Type: " + content_type.encode() + b"\r\n\r\n" + body
    )
    fields = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name != "report":
            fields[name] = part.get_content().strip()
    return fields


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        content_type = self.headers.get("Content-Type", "")

        if self.path == "/oauth/token":
            fields = dict(urllib.parse.parse_qsl(body.decode()))
            status = int(os.environ.get("STUB_TOKEN_STATUS", "200"))
            reply = b'{"access_token":"tok"}' if status == 200 else b'{"error":"x"}'
        else:
            fields = multipart_fields(content_type, body)
            status = int(os.environ.get("STUB_INGEST_STATUS", "202"))
            reply = b"{}"

        with open(os.path.join(OUT, "requests.jsonl"), "a") as log:
            record = {
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "fields": fields,
            }
            log.write(json.dumps(record, sort_keys=True) + "\n")

        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *_args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(OUT, "port"), "w") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
