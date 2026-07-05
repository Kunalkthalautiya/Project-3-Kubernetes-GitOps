from flask import Flask, jsonify
import os

app = Flask(__name__)

VERSION = os.environ.get("APP_VERSION", "v1")


@app.route("/")
def home():
    return jsonify({"message": "Hello from Kubernetes + GitOps!", "version": VERSION})


@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
