# Task: Can we rescan just one side?

A pre-upgrade comparison needs two nix-audit snapshots. The candidate scan failed (exit 3,
vulnix crashed on a network error) and was set aside; the running-system snapshot
`kept.json` completed. Before rescanning, a teammate pasted the kept report's metadata and the
metadata the new candidate scan would have, for three different occasions:

```
A) kept:  producer.revision 7f3a9c1e2b4d…  policy.source.sha256 91be…04  scanners grype=ran vulnix=ran
   new:   producer.revision 7f3a9c1e2b4d…  policy.source.sha256 91be…04  scanners grype, vulnix
B) kept:  producer.revision 7f3a9c1e2b4d…  policy.source.sha256 91be…04  scanners grype=ran vulnix=ran
   new:   producer.revision 7f3a9c1e2b4d…  policy.source.sha256 c4d2…7a  scanners grype, vulnix
C) kept:  producer.revision 7f3a9c1e2b4d…  policy.source.sha256 91be…04  scanners grype=ran (vulnix not selected)
   new:   producer.revision 7f3a9c1e2b4d…  policy.source.sha256 91be…04  scanners grype, vulnix
```

Write `rescan.md` with exactly these lines first, then one short reason per case:
`A: candidate-only` or `A: both`, the same for `B:` and `C:`, and finally
`C full coverage: yes` or `C full coverage: no` (whether case C's kept snapshot, as it stands,
can be reported as grype and vulnix coverage of the running system).

Reply with only the file content as plain text, without code fences.
