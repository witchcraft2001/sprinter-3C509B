# NSLOOKUP

```text
NSLOOKUP name [dns-server]
```

`name` is a bounded ASCII DNS name. Labels are 1..63 bytes, a final dot is
accepted, and the complete wire name cannot exceed 255 bytes. An explicit
`dns-server` must be dotted IPv4 and is used alone. Otherwise the resolver
tries `NET_DNS1`, then `NET_DNS2` after timeout, unreachable, malformed, no-A,
or temporary server errors. NXDOMAIN is final.

The resolver sends an A/IN query with RD set, its own transaction ID and local
UDP port. It uses three 5000 ms attempts per server. Foreign endpoints, stale
IDs, bad checksums, truncation, invalid counts and compression pointer loops
are discarded without extending the current deadline. On success it prints
the queried name, DNS server actually used, IPv4 address, and `RESULT OK`.
