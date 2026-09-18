#!/usr/bin/env python3
import socket, sys
s=socket.create_connection(("127.0.0.1",10000),timeout=30); s.settimeout(30)
def rd(until=b"command> "):
    buf=b""
    while not buf.endswith(until):
        try: c=s.recv(65536)
        except socket.timeout: break
        if not c: break
        buf+=c
    return buf.decode("latin1")
rd()
for c in sys.argv[1:]:
    s.sendall((c+"\n").encode()); print(rd())
