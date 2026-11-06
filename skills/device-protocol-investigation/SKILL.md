---
name: device-protocol-investigation
description: "Use when working out how an owned or authorized device, its firmware image, companion app or capture speaks a protocol (USB serial/RPC, BLE, Wi-Fi, LAN API; e.g. Flipper Zero, a Pineapple module, a smart plug), before writing an independent client or parser for it."
allowed-tools: Bash, Read
---

# Device Protocol Investigation

A bounded, evidence-first investigation that ends in an **evidence record** and
acceptance fixtures another agent can implement against. It reads; it does not
transmit, replay, or impersonate.

## 1. Split the request first

Write two lists before any command:

- **In scope:** reading published sources, hashing artifacts, offline parsing,
  and a read-only query to a device the owner owns, when the owner has
  authorized live work for this task.
- **Refused:** replaying or cloning access credentials (garage, car, door,
  badge, rolling codes), attack-frame injection, jamming, impersonating
  another device, credential capture, anything aimed at a bystander. Do not
  read, copy or decode the stored credential files that would enable these.

When the request contains both, say which part is refused in one line and
carry out the in-scope part. Refusing the whole task is a failure too. A
refused item is not an "open gate" for the owner: write no procedure for it.

## 2. Source first, in this order

1. The vendor's published spec, protobuf/IDL, SDK or official source.
2. An existing open implementation or protocol write-up.
3. Captures of the device's normal, authorized traffic.
4. Only then static RE of firmware or the app (binwalk, unblob, Ghidra, REA),
   and it runs on the **workstation**, never on a small lab node like
   naked-pi (1 GiB). The Pi runs captures and the finished binary only.

Record what each level gave you before going down to the next one. "Source
first sufficed" is a valid result.

## 3. The evidence record (every field required)

```
Artifact:      <file or source> sha256 <hash> size <bytes>
Origin:        <URL / dumped from owned unit serial … / operator-supplied>, <date>
License:       <SPDX, or "unverified: no LICENSE at <rev>">; redistributable? yes/no
Pinned:        <repo>@<commit> / <package version> for every source and tool used
Authorization: owner + device ownership + what live access was granted (or "offline only")
Refused:       the refused items from section 1, one line each, no procedure
Observed:      facts with their locator (proto line, frame no., offset, fn address)
Inferred:      readings with confidence high/medium/low and why
Unknown:       open fields; the client leaves these out or typed as Unknown
Fixtures:      <path> crafted | capture (sanitized) | simulated, each labelled
Needs live:    steps not done and what each needs
```

Commit the record and the fixtures. Do not commit a firmware image, key or raw
capture that is not redistributable or holds secrets: commit its hash and origin
instead.

## 4. Bound it and hand it off

Set a budget up front (time, artifacts, commands that touch a device) and stop
at it with the record as it stands. The handoff is the record plus acceptance
tests derived from **Observed** only. A guessed field never becomes a constant
the client sends.

## Common mistakes

| Mistake | Instead |
|---|---|
| Probe the device or open Ghidra while a `.proto` or SDK is public | Section 2 order |
| binwalk/Ghidra on the Pi | workstation; move the hash, not the binary |
| Forum firmware committed to a repo | hash and origin only; ask where it came from |
| Refusing the whole task over one refused item | split, refuse that item, do the rest |
| "Open gate: replay the garage remote once" | refused items get no procedure |

See also `pcap-evidence-analysis` (offline capture analysis),
`wireless-lab-diagnostics` (adapter capabilities), and `rust-engineering` (the
client). Design rules adapted from [morluto/rea](https://github.com/morluto/rea)
(MIT), design only: `docs/rea-wireless-re-comparison.md`.
