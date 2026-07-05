import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import app


def client():
    app.testing = True
    return app.test_client()


def test_home():
    resp = client().get("/")
    assert resp.status_code == 200
    assert resp.get_json()["message"] == "Hello from Kubernetes + GitOps!"


def test_healthz():
    resp = client().get("/healthz")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"
