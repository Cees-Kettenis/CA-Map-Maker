"""Refuse to publish into a public package; newly created GHCR packages default private."""
import json
import os
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen

name = sys.argv[1]
owner = os.environ["GITHUB_REPOSITORY"].split("/")[0]
request = Request(f"https://api.github.com/users/{owner}/packages/container/{name}",
    headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"], "Accept": "application/vnd.github+json"})
try:
    with urlopen(request, timeout=30) as response:
        package = json.load(response)
except HTTPError as error:
    if error.code == 404 and "--allow-missing" in sys.argv:
        print("New GHCR package will be created with private visibility")
        sys.exit(0)
    raise SystemExit(f"Could not verify GHCR package visibility: HTTP {error.code}") from None
if package["visibility"] != "private":
    raise SystemExit("Refusing to publish: GHCR package must be private")
print(f"Verified private GHCR package: {name}")
