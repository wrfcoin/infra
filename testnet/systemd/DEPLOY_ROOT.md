# Rendering deployment paths

The two testnet service files contain `@WRFCOIN_DEPLOY_ROOT@` tokens. They are
render inputs, not directly installable units. Systemd does not interpolate
shell environment variables in `WorkingDirectory` or `Environment` values.

Before Wednesday's planned restarts, the owner adds these two lines to the
node's existing Compose `.env`, substituting its current absolute paths:

```dotenv
WRFCOIN_DEPLOY_ROOT=<deploy-root>
WRFCOIN_SRC_ROOT=<src-root>
```

Keep existing `WRFCOIN_ROOT`, `CORE4_PATH`, collector and `INSTALL_DIR` overrides.
They retain precedence. New examples use `/path/to/` placeholders; these are not
a deployment recommendation. Export the configured roots when invoking shell
helpers directly; Compose reads them from its `.env`. Bootstrap also reads the
source root from that file for workspace ignore preparation.

Render units into a new staging directory with the configured deploy root:

```bash
WRFCOIN_DEPLOY_ROOT=<deploy-root> python3 testnet/scripts/render-systemd-units.py --output-dir <staging-dir>
```

Compare both rendered units against the installed units before installation.
With the existing deploy root, path substitutions preserve the prior unit text.
The renderer does not read the live `.env`, install units, reload systemd or
restart services. Installation remains the owner's existing procedure.

This change lands with Wednesday's node restarts; no restart before. Abort the
rollout if Compose or unit comparison differs unexpectedly. Retain the prior
units and configuration for the owner's rollback procedure.
