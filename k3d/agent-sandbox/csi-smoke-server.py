"""Serve one read-only WebDAV file for the disposable CSI mount probe."""

from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, HTTPServer
from xml.etree import ElementTree


CONTENT = b"sandbox-csi-smoke\n"
DAV = "DAV:"
ElementTree.register_namespace("d", DAV)


class Handler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("DAV", "1")
        self.send_header("Allow", "OPTIONS, PROPFIND, GET, HEAD")
        self.end_headers()

    def do_PROPFIND(self):
        if self.path not in {"/", "/sample.txt"}:
            self.send_error(404)
            return
        root = ElementTree.Element(f"{{{DAV}}}multistatus")
        paths = [self.path]
        if self.path == "/" and self.headers.get("Depth") == "1":
            paths.append("/sample.txt")
        for path in paths:
            response = ElementTree.SubElement(root, f"{{{DAV}}}response")
            ElementTree.SubElement(response, f"{{{DAV}}}href").text = path
            propstat = ElementTree.SubElement(response, f"{{{DAV}}}propstat")
            prop = ElementTree.SubElement(propstat, f"{{{DAV}}}prop")
            kind = ElementTree.SubElement(prop, f"{{{DAV}}}resourcetype")
            ElementTree.SubElement(prop, f"{{{DAV}}}getlastmodified").text = formatdate(usegmt=True)
            if path == "/":
                ElementTree.SubElement(kind, f"{{{DAV}}}collection")
            else:
                ElementTree.SubElement(prop, f"{{{DAV}}}getcontentlength").text = str(len(CONTENT))
                ElementTree.SubElement(prop, f"{{{DAV}}}getcontenttype").text = "text/plain"
            ElementTree.SubElement(propstat, f"{{{DAV}}}status").text = "HTTP/1.1 200 OK"
        body = ElementTree.tostring(root, encoding="utf-8", xml_declaration=True)
        self.send_response(207)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        self._send_file(include_body=False)

    def do_GET(self):
        self._send_file(include_body=True)

    def _send_file(self, *, include_body):
        if self.path != "/sample.txt":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(CONTENT)))
        self.end_headers()
        if include_body:
            self.wfile.write(CONTENT)


HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
