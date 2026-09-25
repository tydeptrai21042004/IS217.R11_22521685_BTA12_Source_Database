# Hotfix notes

## False APT package-resolution failure

The previous installer used this pattern under `set -o pipefail`:

```bash
apt-cache policy "$pkg" | grep -q 'Candidate:'
```

When `grep -q` finds a match it can exit early. `apt-cache` can then receive
SIGPIPE, causing the whole pipeline to be reported as failed even though APT
showed a valid `Candidate`.

This version captures `apt-cache policy` output first and extracts `Candidate`
with `awk`. A valid candidate such as `16.0.4295.3-1` now passes correctly.
The Microsoft signing-key check was hardened similarly.
