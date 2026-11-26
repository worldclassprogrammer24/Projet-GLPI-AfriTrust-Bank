#!/usr/bin/env python3
"""
alert-receiver.py : récepteur central des alertes du watchdog (webhook simulé).

Écoute en POST sur http://0.0.0.0:9000/alert, attend un JSON, et l'ajoute à
/var/log/glpi-alerts.log (une ligne JSON par alerte, avec l'IP source).
Bibliothèque standard uniquement : rien à installer.

Test :
  curl -X POST -H 'Content-Type: application/json' \
       -d '{"host":"TEST","type":"DEMO","message":"essai"}' http://127.0.0.1:9000/alert
"""
import json
import sys
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST, PORT = "0.0.0.0", 9000
ALERT_LOG = "/var/log/glpi-alerts.log"
MAX_BODY = 8192  # octets : on refuse les corps trop gros


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # Sonde de santé : curl http://serveur:9000/
        self._reply(200, "alert-receiver OK\n")

    def do_POST(self):
        if self.path != "/alert":
            return self._reply(404, "not found\n")
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0 or length > MAX_BODY:
            return self._reply(400, "invalid length\n")
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8", "replace"))
            if not isinstance(data, dict):
                raise ValueError("objet JSON attendu")
        except ValueError:
            return self._reply(400, "invalid json\n")

        data["received_at"] = datetime.now().isoformat(timespec="seconds")
        data["source_ip"] = self.client_address[0]
        with open(ALERT_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(data, ensure_ascii=False) + "\n")
        print(f"ALERTE reçue de {data['source_ip']} : {data.get('type')} - {data.get('host')}", flush=True)
        self._reply(200, "ok\n")

    def log_message(self, fmt, *args):  # logs HTTP vers stdout (journalctl)
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()


if __name__ == "__main__":
    print(f"alert-receiver en écoute sur {HOST}:{PORT}", flush=True)
    HTTPServer((HOST, PORT), Handler).serve_forever()
