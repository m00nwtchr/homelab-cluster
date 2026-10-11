
import ipaddress
import json
import os
import ssl
import urllib.request

name = os.environ["GATEWAY_NAME"]
namespace = os.environ["GATEWAY_NAMESPACE"]

with urllib.request.urlopen(
    os.environ["IP_URL"], timeout=10
) as response:
    ip = str(ipaddress.IPv4Address(
        response.read().decode().strip()
    ))

if not ipaddress.IPv4Address(ip).is_global:
    raise ValueError(f"Not a public IPv4: {ip}")

sa = "/var/run/secrets/kubernetes.io/serviceaccount"
with open(f"{sa}/token") as f:
    token = f.read().strip()

context = ssl.create_default_context(cafile=f"{sa}/ca.crt")

host = os.environ["KUBERNETES_SERVICE_HOST"]
port = os.environ["KUBERNETES_SERVICE_PORT_HTTPS"]

url = (
    f"https://{host}:{port}/apis/"
    f"gateway.networking.k8s.io/v1/"
    f"namespaces/{namespace}/gateways/{name}"
)

headers = {"Authorization": f"Bearer {token}"}

def api(method, payload=None):
    h = headers.copy()
    data = None

    if payload is not None:
        data = json.dumps(payload).encode()
        h["Content-Type"] = "application/merge-patch+json"

    request = urllib.request.Request(
        url, data=data, headers=h, method=method
    )

    with urllib.request.urlopen(
        request, context=context, timeout=10
    ) as response:
        return json.load(response)

gateway = api("GET")
addresses = gateway["spec"].get("addresses", [])

desired = [{"type": "IPAddress", "value": ip}]

if addresses == desired:
    print(f"Unchanged: {ip}")
else:
    api("PATCH", {"spec": {"addresses": desired}})
    print(f"Updated: {addresses} -> {desired}")

