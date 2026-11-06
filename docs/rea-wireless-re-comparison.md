# REA and wireless-RE tooling comparison

Purpose: decide which tools become a portable agent skill, a workstation tool install, or are ignored, for a 1 GiB Raspberry Pi 3 rf-lab appliance where heavy analysis runs on a workstation and not on the Pi (sammasak/nixos-config#41). Date of research: 2026-10-16.

Anything not confirmed from a fetched source is marked "(unverified)".

## Sources fetched

- https://github.com/morluto/rea
- https://registry.npmjs.org/rea-agents/latest
- https://api.github.com/repos/morluto/rea/commits?per_page=1
- https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest
- https://api.github.com/repos/ReFirmLabs/binwalk/releases/latest
- https://api.github.com/repos/onekey-sec/unblob/releases/latest
- https://api.github.com/repos/wireshark/wireshark/tags?per_page=5
- https://www.wireshark.org/download.html
- https://api.github.com/repos/secdev/scapy/releases/latest
- https://api.github.com/repos/kismetwireless/kismet/tags?per_page=5
- https://api.github.com/repos/bcopeland/wmediumd/commits?per_page=1

## Matrix

| Tool | Upstream | Pinned revision | License | Primary capability / rf-lab mapping | aarch64 / 1 GiB Pi | Dependencies | Verdict | Target |
|---|---|---|---|---|---|---|---|---|
| REA | https://github.com/morluto/rea | npm `rea-agents` 6.5.0; `main` HEAD `9e7e13fb7155a2fe6f672ddb4a17e40d1a9c4173` (2026-10-16, a moving commit); no GitHub release tag | MIT (REA code only) | MCP/CLI for agent-assisted RE of binaries, JS/Electron, .NET, APKs, firmware, pcaps and SQLite. It is not an 802.11/RF suite. Maps only to firmware/pcap triage, which the Pi does not run. | Not suitable on the Pi. Needs Node.js 22.19+/24.11+/26+, and native analysis needs Hopper, Ghidra or IDA. aarch64 support is (unverified). | Node and npm. Backends such as Ghidra, JADX+JDK and adb per target. No LLM provider requirement is stated; the agent's own provider applies. | Adapt | Design patterns go into sammasak/skills. No install. |
| Ghidra | https://github.com/NationalSecurityAgency/ghidra | `Ghidra_12.1.4_build`, 2026-09-21 | Apache-2.0 (unverified, not shown in the fetched response) | Static firmware/binary RE. Relevant only if we need to inspect vendor firmware. | Workstation only. It needs a JDK and is heavy for 1 GiB. | JDK and optionally a GUI. Headless mode exists (unverified). | Ignore, as a workstation tool only | Workstation, not a skill |
| binwalk | https://github.com/ReFirmLabs/binwalk | `v3.1.0`, 2024-10-31 | MIT (unverified) | Firmware signature scan and extraction. | The v3 rewrite is in Rust (unverified). Light enough to run on the Pi in principle, but not needed there. | Extraction helper tools. | Ignore, as a workstation tool only | Workstation |
| unblob | https://github.com/onekey-sec/unblob | `26.6.4`, 2026-06-04 | MIT (unverified) | Firmware extraction, a more robust alternative to binwalk extraction. | Python plus external extractors. Workstation only. | Python, many extractor binaries. | Ignore, as a workstation tool only | Workstation |
| Wireshark / tshark | https://github.com/wireshark/wireshark | Current stable `4.6.9` (date not given on https://www.wireshark.org/download.html). Tags page returned `wireshark-4.4.9` (SHA `57bf672140761a871aaad0f709fb7f7c32fd186b`) but was not in recency order, so a 4.6.9 SHA is unverified. | GPL-2.0-or-later (unverified, not shown in the fetched pages) | Protocol trace analysis. The tshark CLI is the scriptable half and feeds the pcap-evidence-analysis skill. | tshark is available on aarch64 (unverified). Dissecting large captures is memory-heavy, so large captures go to the workstation. | Standalone CLI. The GUI is optional. | Adopt, as a skill wrapper around tshark | sammasak/skills (`pcap-evidence-analysis`) |
| Scapy | https://github.com/secdev/scapy | `v2.8.0`, 2026-10-02 | GPL-2.0 (unverified) | Offline packet fixture generation only, as in `modules/rf-lab/fixtures/craft-fixtures.py`. Never used for transmission. | Pure Python. Fine on aarch64 for fixture generation. | Python only. | Adopt (offline fixtures only) | nixos-config rf-lab fixtures; usage guarded inside the skills |
| Kismet | https://github.com/kismetwireless/kismet | Tag `kismet-2025-09-R1`, SHA `7a3b5d207e6b15d7dcbb8fa916e121e51d3280e0` (tag date not fetched; newest tag unverified) | GPL-2.0 (unverified) | Wireless discovery. It is a live-capture daemon and therefore a different job from offline analysis. | Runs on a Pi, but needs a capture-capable radio and real RF. Not part of this decision. | C++ daemon with a web UI. | Ignore, as a workstation tool only | nixos-config hardware role, if ever enabled |
| mac80211_hwsim + wmediumd | https://github.com/bcopeland/wmediumd (hwsim is in the Linux kernel) | wmediumd `717e5d7fcc23eecbc8e32bd897a8fd4b1e3ba640` (commit date 2021-03-02, so effectively unmaintained) | wmediumd: ISC (unverified); hwsim: GPL-2.0 (kernel) | Virtual-radio regression with no RF hardware. We package wmediumd ourselves because it is absent from nixpkgs. | Kernel module plus a small C daemon. Works on aarch64 if the kernel ships the module (unverified). | Kernel module, libnl, and our own Nix package. | Adopt, as a hardware-role package, not a skill | nixos-config hardware role / rf-lab module |

## Notes per tool

- **REA.** Its README stresses that results carry the evidence and limitations behind each conclusion. Setup shows proposed changes for approval and backs up existing config. It documents CLI exit statuses and evidence output. The README does not use the term "dry-run". Failure modes: runtime capture runs the target under the user's permissions, and the Node/backend footprint is large. Installing it on the Pi is out of scope. The GitHub page showed no releases, so the npm version is the best pin. The `main` SHA moves daily and is a snapshot only.
- **Ghidra.** Revision confirmed. The license, headless support and workstation fit are inferences (unverified). An agent would need a project directory and a long-running JVM, which is poor for the Pi.
- **binwalk.** The 3.1.0 release is nearly two years old at the time of writing. Check for activity before relying on it.
- **unblob.** Preferred over binwalk for extraction depth (unverified). Its extractor dependencies make it a good fit for a Nix devshell on the workstation.
- **Wireshark.** Capture in the field, analyse on the workstation. The skill should record the tshark version used.
- **Scapy.** Keep the fixture script deterministic (fixed timestamps and seeds) so fixtures are reproducible.
- **Kismet.** Not an offline-analysis tool. It would need hardware and legal review before use (unverified).
- **wmediumd.** The last commit is from 2021, which is a supply-chain and maintenance risk for a package we pin ourselves.

## REA design rules we adopt

1. **Evidence first.** Every conclusion cites the artifact that supports it, such as a frame number, field value or file hash.
2. **Observed versus inferred.** Findings are labelled as observed in the data or inferred from it, and limitations are stated.
3. **Dry-run and approval.** The default is read-only and offline. Anything that changes state or transmits shows its plan first and needs approval.
4. **No unneeded provider setup.** Skills work with the files and CLIs already present. They need no extra network service, LLM provider or daemon.
5. **Record versions.** Tool name, version and input hashes go into every report so results can be reproduced.

Our shipped skills follow these rules: `pcap-evidence-analysis`, `wireless-lab-diagnostics`, `rf-chaos-experiment-review` and `device-protocol-investigation` (nixos-config#42).

## Recommendation summary

We do not install REA, Ghidra or Node on the Pi. Heavy reverse engineering runs on a workstation. The portable, agent-facing value is captured as the three shipped skills (adopt), and REA's tool-contract and evidence discipline is adapted into them. Ghidra, binwalk, unblob and Kismet stay workstation CLIs invoked as needed, not skills. Scapy stays limited to offline fixture generation. Wireshark/tshark is used through the pcap skill, and mac80211_hwsim with our own wmediumd package stays a hardware-role regression facility in nixos-config.
