"""Compose chain inputs must stay nonempty; network selection stays literal."""
import re


def assert_safe_identity(variable, value):
    value = value.strip()
    if variable == 'WRFCOIN_NETWORK_ID':
        assert value == 'testnet', 'network must remain literal testnet'
        return
    assert variable == 'WRFCOIN_CHAIN_ID'
    assert re.fullmatch(r'[1-9][0-9]*|\$\{WRFCOIN_CHAIN_ID:-(?:[1-9][0-9]*)\}|\$\{WRFCOIN_CHAIN_ID:\?[^{}]+\}', value), (
        'chain identity needs a nonempty integer default or an explicit required input')
