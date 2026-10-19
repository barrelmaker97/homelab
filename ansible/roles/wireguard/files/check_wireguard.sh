#!/bin/bash
# Verify the WireGuard interface is up and listening
[ -n "$(ip link show up dev wg0 2>/dev/null)" ] \
  && [ -n "$(wg show wg0 listen-port 2>/dev/null)" ]
