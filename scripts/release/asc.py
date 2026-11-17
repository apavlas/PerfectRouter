"""Tiny App Store Connect API client. IDs come from ~/.appstoreconnect/perfectrouter.json
(not in git); the .p8 key stays in ~/.appstoreconnect/private_keys/ and is never committed.
Usage: python3 asc.py GET /v1/apps [body.json]   (needs: pip install pyjwt cryptography requests)"""
import sys, time, json, os, jwt, requests
CFG = json.load(open(os.path.expanduser(os.environ.get("ASC_CONFIG", "~/.appstoreconnect/perfectrouter.json"))))
KEY = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{CFG['key_id']}.p8")
def tok():
    with open(KEY) as f: k = f.read()
    now = int(time.time())
    return jwt.encode({"iss": CFG["issuer_id"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                      k, algorithm="ES256", headers={"kid": CFG["key_id"], "typ": "JWT"})
def call(method, path, body=None):
    r = requests.request(method, "https://api.appstoreconnect.apple.com" + path,
                         headers={"Authorization": "Bearer " + tok(), "Content-Type": "application/json"},
                         data=json.dumps(body) if body is not None else None, timeout=60)
    print("HTTP", r.status_code); print(r.text or "")
    return r
if __name__ == "__main__":
    m, p = sys.argv[1], sys.argv[2]
    b = json.loads(open(sys.argv[3]).read()) if len(sys.argv) > 3 else None
    call(m, p, b)
