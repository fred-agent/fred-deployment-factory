# Copyright Thales 2026
# SPDX-License-Identifier: Apache-2.0

from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path('/skills')
DAV = 'DAV:'
ET.register_namespace('d', DAV)
FILES = {
    '/summarize-document/SKILL.md': ROOT / 'summarize-document/SKILL.md',
    '/tabular-evidence/SKILL.md': ROOT / 'tabular-evidence/SKILL.md',
    '/tabular-evidence/analyze.py': ROOT / 'tabular-evidence/analyze.py',
}
CHILDREN = {
    '/': ['/summarize-document/', '/tabular-evidence/'],
    '/summarize-document/': ['/summarize-document/SKILL.md'],
    '/tabular-evidence/': ['/tabular-evidence/SKILL.md', '/tabular-evidence/analyze.py'],
}


class Handler(BaseHTTPRequestHandler):
    def target(self):
        path = self.path.split('?', 1)[0]
        if path not in {'/', *CHILDREN.keys(), *FILES.keys()}:
            self.send_error(404)
            return None
        return path

    def do_OPTIONS(self):
        if self.target() is None:
            return
        self.send_response(200)
        self.send_header('DAV', '1')
        self.send_header('Allow', 'OPTIONS, PROPFIND, GET, HEAD')
        self.end_headers()

    def do_PROPFIND(self):
        path = self.target()
        if path is None:
            return
        paths = [path]
        if self.headers.get('Depth') == '1':
            paths.extend(CHILDREN.get(path, []))
        root = ET.Element(f'{{{DAV}}}multistatus')
        for item in paths:
            response = ET.SubElement(root, f'{{{DAV}}}response')
            ET.SubElement(response, f'{{{DAV}}}href').text = item
            propstat = ET.SubElement(response, f'{{{DAV}}}propstat')
            prop = ET.SubElement(propstat, f'{{{DAV}}}prop')
            kind = ET.SubElement(prop, f'{{{DAV}}}resourcetype')
            ET.SubElement(prop, f'{{{DAV}}}getlastmodified').text = formatdate(usegmt=True)
            if item.endswith('/'):
                ET.SubElement(kind, f'{{{DAV}}}collection')
            else:
                ET.SubElement(prop, f'{{{DAV}}}getcontentlength').text = str(FILES[item].stat().st_size)
                ET.SubElement(prop, f'{{{DAV}}}getcontenttype').text = 'text/x-python' if item.endswith('.py') else 'text/markdown'
            ET.SubElement(propstat, f'{{{DAV}}}status').text = 'HTTP/1.1 200 OK'
        body = ET.tostring(root, encoding='utf-8', xml_declaration=True)
        self.send_response(207)
        self.send_header('Content-Type', 'application/xml')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        self.send_file(False)

    def do_GET(self):
        self.send_file(True)

    def send_file(self, include_body):
        target = self.target()
        if target not in FILES:
            self.send_error(405)
            return
        body = FILES[target].read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', 'text/x-python' if target.endswith('.py') else 'text/markdown')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def log_message(self, *_args):
        pass


HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
