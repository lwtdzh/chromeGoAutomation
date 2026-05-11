# chromeGoAutomation

`chromeGoAutomation` builds a validated ChromeGo subscription result from the URLs in `chromego-filter-then-push-github.list`.

The script reads every subscription URL from the list file, downloads each subscription into `nodes/`, parses supported proxy nodes, removes duplicates, filters unsupported or local/private endpoints, validates each remaining node through local proxy clients, and writes only working nodes to `result.list`.

Supported node types:

- `vmess`
- `vless`
- `ss`
- `trojan`
- `hysteria2`
- `hysteria`
- `tuic`

## Usage

On Windows, run the Bash script from Git Bash:

```bash
./chromego-filter-then-push-github.sh --no-push
```

On Linux, run:

```bash
./chromego-filter-then-push-github.sh --no-push
```

The script downloads `xray` and `sing-box` into local dependency folders when they are missing. Those folders, downloaded subscription YAML files, and temporary clone folders are intentionally ignored by Git.

To tune validation speed:

```bash
TEST_JOBS=12 PROXY_TEST_TIMEOUT=4 ./chromego-filter-then-push-github.sh --no-push
```

`result.list` is the committed output file for this repository. Each run regenerates it from the subscription list and the current validation result.
