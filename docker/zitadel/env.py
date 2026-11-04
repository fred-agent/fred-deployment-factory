#!/usr/bin/env python3
"""Generate local ZITADEL secrets once, without printing them."""

import os
import secrets
from pathlib import Path

os.umask(0o077)
output = Path(__file__).with_name(".env")
try:
    with output.open("x") as stream:
        stream.write(f"POSTGRES_PASSWORD={secrets.token_hex(24)}\n")
        stream.write(f"ZITADEL_MASTERKEY={secrets.token_hex(16)}\n")
        stream.write(f"LOGIN_COOKIE_SECRET={secrets.token_hex(32)}\n")
    print("Created local ZITADEL environment (secrets not displayed).")
except FileExistsError:
    print("Existing ZITADEL environment preserved.")
