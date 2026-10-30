# Benchmark project: the SAFE counterpart. Any finding here is a false positive.
import json
import secrets
import sqlite3
import subprocess

import requests
import yaml


def find_user(user_id):
    cursor = sqlite3.connect('app.db').cursor()
    cursor.execute('SELECT * FROM users WHERE id = ?', (user_id,))
    return cursor.fetchall()


def load_settings(text):
    return yaml.safe_load(text)


def restore(text):
    return json.loads(text)


def fetch_status():
    return requests.get('https://status.example.com/health', timeout=5).text


def list_directory(path):
    return subprocess.run(['ls', '--', path], capture_output=True, check=False).stdout


def new_api_token():
    return secrets.token_urlsafe(32)
