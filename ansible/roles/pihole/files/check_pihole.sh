#!/bin/bash
# Verify both Pi-hole (port 53) and Unbound (port 5335) are responding
dig @127.0.0.1 -p 53 google.com +short +time=1 +tries=1 > /dev/null 2>&1 \
  && dig @127.0.0.1 -p 5335 google.com +short +time=1 +tries=1 > /dev/null 2>&1
