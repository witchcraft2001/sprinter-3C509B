# TFTP

`TFTP.EXE` transfers files in octet mode through the configured polling-only
`NETDRV` backend. Run `NETCFG -i` and `IFUP` first.

```text
TFTP host[:port] GET remote [-o local] [-y|-f]
TFTP host[:port] PUT local [-o remote]
```

`host` is a dotted IPv4 address or ASCII hostname. The optional `:port` remains
part of the TFTP syntax after hostname resolution. The request port defaults to
69 and may be `1..65535`. A wire filename is limited to
79 bytes. Without `-o`, GET uses the basename of `remote`, and PUT uses the
basename of `local`.

GET prompts `Y/N` before replacing an existing file. Esc or refusal cancels
with `code=23` and DSS exit 7. `-y` and `-f` are equivalent and skip the
prompt. Paths are supported for local input/output; the original DSS current
directory is restored. A failed GET closes and retains its partial file.

The client requests `blksize=1428` and falls back to 512 when the server
ignores the option. An OACK must contain only one valid `blksize` in 8..1428
and cannot exceed the request. The first valid response fixes the server TID;
packets from another TID receive ERROR 5. Duplicate DATA is ACKed without a
second write, while duplicate ACK and future blocks are ignored.

Each lock-step state has a 5000 ms deadline and at most six transmissions.
GET uses an 8 KiB DSS-page file buffer; PUT reads directly into the outgoing
payload. Files whose size is an exact block multiple finish with an additional
zero-length DATA block. Error exits are timeout 3 (`code=14`), local file I/O 5
(`code=26`), remote TFTP/option failure 6 (`code=25`), matching ICMP
unreachable 6 (`code=24`), and cancellation 7 (`code=23`).
