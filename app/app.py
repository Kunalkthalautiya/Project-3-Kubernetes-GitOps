from flask import Flask, jsonify
import os
import psycopg2

app = Flask(__name__)

VERSION = os.environ.get("APP_VERSION", "v1")

DB_HOST = os.environ.get("DB_HOST", "postgres")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("POSTGRES_DB", "gitopsdemo")
DB_USER = os.environ.get("POSTGRES_USER", "gitopsdemo")
DB_PASSWORD = os.environ.get("POSTGRES_PASSWORD", "")


def get_connection():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD
    )


@app.route("/")
def home():
    return jsonify({"message": "Hello from Kubernetes + GitOps!", "version": VERSION})


@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok"})


@app.route("/api/visits")
def visits():
    conn = get_connection()
    with conn, conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE IF NOT EXISTS visits (id SERIAL PRIMARY KEY, created_at TIMESTAMPTZ DEFAULT now())"
        )
        cur.execute("INSERT INTO visits DEFAULT VALUES")
        cur.execute("SELECT count(*) FROM visits")
        count = cur.fetchone()[0]
    conn.close()
    return jsonify({"total_visits": count})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
