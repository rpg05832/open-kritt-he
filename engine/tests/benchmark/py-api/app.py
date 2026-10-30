# Benchmark project: deliberately vulnerable Flask API. Never run it.
import pickle
import sqlite3

import requests
import yaml
from flask import Flask, request

app = Flask(__name__)


@app.route('/user')
def user():
    cursor = sqlite3.connect('app.db').cursor()
    cursor.execute(f"SELECT * FROM users WHERE id = {request.args['id']}")
    return str(cursor.fetchall())


@app.route('/import', methods=['POST'])
def import_settings():
    return str(yaml.load(request.data))


@app.route('/restore', methods=['POST'])
def restore():
    return str(pickle.loads(request.data))


@app.route('/proxy')
def proxy():
    return requests.get(request.args['url'], verify=False).text


if __name__ == '__main__':
    app.run(host='0.0.0.0', debug=True)
