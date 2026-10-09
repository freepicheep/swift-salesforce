import http.server, socketserver, time, sys
class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_GET(self):
        try:
            if self.path == '/redirect':
                self.send_response(302); self.send_header('Location', '/secret'); self.send_header('Content-Length', '0'); self.end_headers(); return
            if self.path == '/slow': time.sleep(2)
            if self.path == '/broken':
                self.send_response(200); self.send_header('Content-Length', '100000'); self.end_headers(); self.wfile.write(b'short'); self.wfile.flush(); self.close_connection = True; return
            count = 8 * 1024 * 1024 if self.path == '/large' else 16
            self.send_response(200); self.send_header('Content-Length', str(count)); self.send_header('Sforce-Limit-Info', 'api-usage=1/5000'); self.end_headers()
            chunk = b'x' * 16384
            while count:
                n = min(count, len(chunk)); self.wfile.write(chunk[:n]); self.wfile.flush(); count -= n
        except (BrokenPipeError, ConnectionResetError): pass
    def do_PUT(self):
        try:
            size = 0
            if self.headers.get('Transfer-Encoding') == 'chunked':
                while True:
                    n = int(self.rfile.readline().strip(), 16)
                    if not n: self.rfile.readline(); break
                    data = self.rfile.read(n); self.rfile.read(2); size += len(data)
            else:
                remaining = int(self.headers.get('Content-Length', 0))
                while remaining:
                    data = self.rfile.read(min(remaining, 65536)); size += len(data); remaining -= len(data)
            body = str(size).encode(); self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
server = Server(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
