# Copyright Thales 2026
# SPDX-License-Identifier: Apache-2.0

import os
import re
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit
from xml.etree import ElementTree as ET

ROOT = Path(os.environ.get('FRED_SKILLS_ROOT', '/skills'))
DAV = 'DAV:'
ET.register_namespace('d', DAV)
ALLOWED_SUFFIXES = {'.md', '.txt', '.json', '.yaml', '.yml', '.csv', '.py', '.sh'}
SKILL_NAME = re.compile(r'^[a-z0-9]+(?:-[a-z0-9]+)*$')


def mounted_tree():
    files = {}
    children = {'/': []}
    for skill in sorted(ROOT.iterdir()):
        if (not skill.is_dir() or skill.is_symlink() or not SKILL_NAME.fullmatch(skill.name)
                or not (skill / 'SKILL.md').is_file()):
            continue
        folder = f'/{skill.name}/'
        children['/'].append(folder)
        children[folder] = []
        for entry in sorted(skill.rglob('*')):
            if entry.is_symlink() or not entry.is_file() or entry.suffix.lower() not in ALLOWED_SUFFIXES:
                continue
            relative = entry.relative_to(ROOT)
            if any(part.startswith('.') or part == '__pycache__' for part in relative.parts):
                continue
            parent = '/'
            for part in relative.parts[:-1]:
                directory = parent + part + '/'
                if directory not in children:
                    children[directory] = []
                    children[parent].append(directory)
                parent = directory
            path = '/' + relative.as_posix()
            files[path] = entry
            children[parent].append(path)
    for entries in children.values():
        entries.sort()
    return files, children


class Handler(BaseHTTPRequestHandler):
    def target(self):
        path = unquote(urlsplit(self.path).path)
        files, children = mounted_tree()
        if path not in {'/', *children.keys(), *files.keys()}:
            self.send_error(404)
            return None
        return path, files, children

    def do_OPTIONS(self):
        if self.target() is None:
            return
        self.send_response(200)
        self.send_header('DAV', '1')
        self.send_header('Allow', 'OPTIONS, PROPFIND, GET, HEAD')
        self.end_headers()

    def do_PROPFIND(self):
        target = self.target()
        if target is None:
            return
        path, files, children = target
        paths = [path]
        if self.headers.get('Depth') == '1':
            paths.extend(children.get(path, []))
        root = ET.Element(f'{{{DAV}}}multistatus')
        for item in paths:
            response = ET.SubElement(root, f'{{{DAV}}}response')
            ET.SubElement(response, f'{{{DAV}}}href').text = quote(item, safe='/')
            propstat = ET.SubElement(response, f'{{{DAV}}}propstat')
            prop = ET.SubElement(propstat, f'{{{DAV}}}prop')
            kind = ET.SubElement(prop, f'{{{DAV}}}resourcetype')
            ET.SubElement(prop, f'{{{DAV}}}getlastmodified').text = formatdate(usegmt=True)
            if item.endswith('/'):
                ET.SubElement(kind, f'{{{DAV}}}collection')
            else:
                ET.SubElement(prop, f'{{{DAV}}}getcontentlength').text = str(files[item].stat().st_size)
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
        if target is None:
            return
        path, files, _ = target
        if path not in files:
            self.send_error(405)
            return
        source = files[path]
        size = source.stat().st_size
        self.send_response(200)
        self.send_header('Content-Type', 'text/x-python' if path.endswith('.py') else 'text/markdown')
        self.send_header('Content-Length', str(size))
        self.end_headers()
        if include_body:
            with source.open('rb') as stream:
                while chunk := stream.read(64 * 1024):
                    self.wfile.write(chunk)

    def log_message(self, *_args):
        pass


if __name__ == '__main__':
    HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
