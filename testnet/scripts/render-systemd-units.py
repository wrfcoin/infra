#!/usr/bin/env python3
"""Render deployment-root tokens into a new directory; never install or restart."""
import argparse
import os
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    root = os.environ.get('WRFCOIN_DEPLOY_ROOT', '')
    # Systemd path directives have escaping/specifier rules. Accept plain absolute
    # paths only, rather than generating a unit with ambiguous interpretation.
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', root) or '..' in Path(root).parts or root.startswith('/path/to/'):
        parser.error('WRFCOIN_DEPLOY_ROOT must be a configured plain absolute path')
    root = root.rstrip('/')
    if not root:
        parser.error('WRFCOIN_DEPLOY_ROOT cannot be the filesystem root')
    source = Path(__file__).resolve().parents[1] / 'systemd'
    names = ['wrfcoin-testnet.service', 'wrfcoin-testnet-public-uptime-probe.service']
    rendered = {name: (source / name).read_text().replace('@WRFCOIN_DEPLOY_ROOT@', root) for name in names}
    args.output_dir.mkdir(parents=True, exist_ok=False)
    for name, text in rendered.items():
        (args.output_dir / name).write_text(text)
    print('PASS: rendered 2 systemd units; no install or restart performed')


if __name__ == '__main__':
    main()
