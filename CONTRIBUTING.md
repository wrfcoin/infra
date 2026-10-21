# Contributing to WRFCoin Infrastructure

Follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities
privately using [SECURITY.md](SECURITY.md).

## Development and validation

This repository contains deployment configuration and scripts rather than one
application build. Use an isolated local checkout with Bash, Python 3, pytest,
PyYAML, and ShellCheck for script work. Docker Compose and Node.js are needed
for the components that use them. Read [README.md](README.md) for component
layout and [the script-test workflow](.github/workflows/scripts-tests.yml) for
suite-specific dependencies.

```bash
git clone https://github.com/wrfcoin/infra.git
cd infra
python3 -m pytest scripts/tests/ -q
```

Run the relevant shell fixtures listed in the workflow for your change, plus
`bash -n path/to/script.sh` and `shellcheck path/to/script.sh` on edited shell
scripts. For Compose changes, render the affected file with local synthetic
configuration before testing disposable local containers. For Node components,
use that component's package scripts and locked dependencies. Do not run
operator deployment or live-network scripts as a substitute for local tests.

## Pull request flow

Search existing issues and PRs first. Fork the repository, create a focused
branch from current `main`, add regression coverage, and update documentation.
Open a PR against `main` with `Refs #N`, a description of the change, exact test
commands and results, and explicit limits on runtime evidence. Address review
feedback; maintainers handle admission and merging.

Never include credentials, personal locations, private host details, or real
deployment configuration in a contribution. Use synthetic fixtures and sanitized
logs. Operator actions need the operator's authorization.

## License

Contributions are licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE),
at the recipient's option.
