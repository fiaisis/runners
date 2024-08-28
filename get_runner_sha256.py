import hashlib
import requests


# Set your image name
USER_IMAGE = "fiaisis/mantid"
versions = ["6.8.0", "6.9.0", "6.9.1"]

response = requests.get(f"https://ghcr.io/token?scope=repository:{USER_IMAGE}:pull")
TOKEN = response.json()['token']

# Get the manifest of the image
headers = {
    "Authorization": f"Bearer {TOKEN}",
    "Accept": "application/vnd.docker.distribution.manifest.v2+json"
}

for version in versions:
    response = requests.get(f"https://ghcr.io/v2/{USER_IMAGE}/manifests/{version}", headers=headers)
    manifest = response.text
    sha256 = hashlib.sha256(manifest.encode('utf-8')).hexdigest()
    print(f"Mantid {version} sha256: {sha256}")
