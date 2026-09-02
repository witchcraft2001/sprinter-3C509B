# NTP

```text
NTP [server]
```

Without an argument, `NTP` uses `NET_NTP`. A server may be dotted IPv4 or a
hostname resolved by the common DNS resolver. The polling-only SNTP client
sends a 48-byte NTPv4 request to UDP/123 and makes at most three 5000 ms
attempts.

Replies must match the IP/UDP endpoint and originate cookie, have a valid
checksum, version 3 or 4, server mode, a synchronised leap indicator, stratum
1..15, and a nonzero transmit timestamp. The supported era is
1970-01-01 through 2036-02-07 06:28:15 UTC.

`NET_TZ` is revalidated on every run. It accepts the same quarter-hour grammar
as `NETCFG`: empty, `[+|-]H`, `[+|-]HH`, `[+|-]H:MM`, or `[+|-]HH:MM`, in
`-12:00..+14:00`. The printed form is always normalised, for example
`UTC+05:45`, `UTC-03:30`, or `UTC+00:00`. Date, month, year and leap-day
rollover are applied before `DSS_SETTIME`. The ISA window is closed before the
clock service is called; a DSS clock failure returns local exit code 5.
