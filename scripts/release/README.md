# Release scripts (Ship Ops)

- `smoke_run.sh <N>`: archive build N, then the release preflight smokes (iPad, then iPhone, then OKC to Amarillo 5 times).
- `asc.py`: a minimal App Store Connect API call. The key ID, issuer, app and group IDs are read from `~/.appstoreconnect/perfectrouter.json` on the build Mac. The `.p8` key never leaves `~/.appstoreconnect/private_keys/` and is never committed.
- `finish_build.py <N> <wtt.txt>`: after an upload, sets What to Test, adds the External group and submits for beta review.
- `ExportOptions-upload.plist`: upload export options.
- `what-to-test/`: What to Test text as shipped, per build.

No upload happens without Anton's explicit "ship it" for that build.
