"""Synthetic Windows QA credentials only; never read real workshop secrets.

Automates the vendor password prompt for hosted CI. The remaining vendor CLI
and Windows keyring calls are real. This is not a database authentication test.
"""

import os
import sys

from mcp_server import cli_config
from mcp_server.credential_store import (
    get_keyring_password,
    load_config_file,
    remove_credentials,
)


def main():
    password = os.environ['PEAKGEAR_QA_SYNTHETIC_PASSWORD']
    existing = load_config_file().get('adp', {})
    if existing and get_keyring_password('adp', existing.get('user', '')) != password:
        raise RuntimeError('QA refuses to overwrite credentials not created by this fixture.')
    if len(sys.argv) > 1 and sys.argv[1] == 'cleanup':
        remove_credentials('adp')
        assert not load_config_file().get('adp')
        print('Synthetic credential removed before offline MCP startup.')
        return
    cli_config.getpass.getpass = lambda prompt: password
    cli_config.main()
    assert get_keyring_password('adp', 'PEAKGEAR_USER') == password
    assert password not in str(load_config_file())
    import keyring
    backend = type(keyring.get_keyring())
    assert backend.__module__ == 'keyring.backends.Windows', backend.__module__
    print('PASS actual Windows Credential Manager round trip; no password displayed.')


if __name__ == '__main__':
    main()
