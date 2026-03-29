#!/usr/bin/env python3
"""Test YFY stock command API."""

import requests
import json
import sys

API_URL = "https://stock.haidian666.com/stock/subscribe/info"

# Test commands
TEST_COMMANDS = [
    "yfy#股票#成交额#1-10",
    "yfy#股票#排名#1-10",
    "yfy#股票#主净#1-10",
    "yfy#板块#涨跌#1-10:0",
    "yfy#概念#涨跌#1-10:0",
]


def query(cmd_name):
    """Send a command to the YFY API and return the response."""
    payload = {"subscribeCmdName": cmd_name}
    print(f"\n{'='*60}")
    print(f"Command: {cmd_name}")
    print(f"{'='*60}")
    try:
        resp = requests.post(API_URL, json=payload, timeout=15)
        print(f"Status: {resp.status_code}")
        data = resp.json()
        # Print first 2000 chars to see the structure
        text = json.dumps(data, ensure_ascii=False, indent=2)
        if len(text) > 2000:
            print(text[:2000])
            print(f"\n... (truncated, total {len(text)} chars)")
        else:
            print(text)
        return data
    except Exception as e:
        print(f"Error: {e}")
        return None


if __name__ == "__main__":
    if len(sys.argv) > 1:
        # Custom command from CLI
        cmd = " ".join(sys.argv[1:])
        query(cmd)
    else:
        # Run all test commands
        for cmd in TEST_COMMANDS:
            query(cmd)
