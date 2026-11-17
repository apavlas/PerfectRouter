"""After an upload: wait for processing, set export compliance, set What to Test,
add the External group, submit for beta review, print testers.
Usage: python3 finish_build.py <build_number> <what_to_test.txt>
Only run after Anton's explicit "ship it" for that build."""
import sys, time, asc
N, WTT = sys.argv[1], sys.argv[2]
APP, GRP = asc.CFG["app_id"], asc.CFG["external_group_id"]
def q():
    return asc.call("GET", f"/v1/builds?filter[app]={APP}&filter[version]={N}&fields[builds]=version,processingState,usesNonExemptEncryption").json().get("data", [])
start = time.time()
while True:
    d = q()
    if d and d[0]["attributes"]["processingState"] != "PROCESSING": break
    if time.time() - start > 3600: print("TIMEOUT", flush=True); raise SystemExit(1)
    time.sleep(60)
b = d[0]; B = b["id"]; print("STATE", B, b["attributes"], flush=True)
if b["attributes"]["processingState"] != "VALID": raise SystemExit(1)
if b["attributes"].get("usesNonExemptEncryption") is None:
    asc.call("PATCH", f"/v1/builds/{B}", {"data": {"type": "builds", "id": B, "attributes": {"usesNonExemptEncryption": False}}})
t = open(WTT).read().rstrip("\n")
loc = [x for x in asc.call("GET", f"/v1/builds/{B}/betaBuildLocalizations").json()["data"] if x["attributes"]["locale"] == "en-US"]
if loc:
    asc.call("PATCH", f"/v1/betaBuildLocalizations/{loc[0]['id']}", {"data": {"type": "betaBuildLocalizations", "id": loc[0]["id"], "attributes": {"whatsNew": t}}})
else:
    asc.call("POST", "/v1/betaBuildLocalizations", {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": t}, "relationships": {"build": {"data": {"type": "builds", "id": B}}}}})
loc = [x for x in asc.call("GET", f"/v1/builds/{B}/betaBuildLocalizations").json()["data"] if x["attributes"]["locale"] == "en-US"]
print("WTT_MATCH", loc[0]["attributes"]["whatsNew"] == t, flush=True)
print("GROUP", asc.call("POST", f"/v1/betaGroups/{GRP}/relationships/builds", {"data": [{"type": "builds", "id": B}]}).status_code, flush=True)
print("REVIEW", asc.call("POST", "/v1/betaAppReviewSubmissions", {"data": {"type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": B}}}}}).status_code, flush=True)
print("REVIEWSTATE", asc.call("GET", f"/v1/builds/{B}/betaAppReviewSubmission").json().get("data", {}).get("attributes"), flush=True)
print("FINISHED", flush=True)
