#!/bin/bash
# Verify both Pi-hole (port 53) and Unbound (port 5335) resolve a name. dig
# exits 0 on SERVFAIL and prints errors to stdout, so look for an address.
resolves() {
  dig @127.0.0.1 -p "$1" google.com +short +time=1 +tries=1 2>/dev/null | grep -q '^[0-9]'
}

resolves 53 && resolves 5335
