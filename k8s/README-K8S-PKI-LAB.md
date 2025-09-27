# Mini PKI & TLS Lab on Kubernetes (Two Services + curl)
**Goal:** run two HTTPS services in Kubernetes (`nginx-a` and `nginx-b`) whose certificates are signed by the same local **CA**, and verify trust using a `curl` pod. Files are split by purpose: **ConfigMaps**, **Deployments**, **Services**, and a **curl pod**.

---

## 1) What you’ll learn
- How to build a local **Certificate Authority (CA)** and issue **server certificates**.
- Why **SANs** (Subject Alternative Names) must include the service DNS names used by clients.
- How to mount certificates in **NGINX** pods and enable **TLS**.
- How Kubernetes DNS generates names like `nginx-b.pki-lab.svc.cluster.local`.
- How to validate trust with `curl` (**fail** without the CA, **succeed** with it).

---

## 2) Prerequisites
- A working Kubernetes cluster and `kubectl`.
- `openssl` on your workstation.
- Namespace `pki-lab`. (We create it below.)

---

## 3) Prepare PKI locally (CA + 2 server certs)
Create a working folder on your machine (not inside the cluster):
```bash
mkdir -p pki-k8s-lab/{ca,a,b} && cd pki-k8s-lab

# 3.1 Root CA (self-signed)
openssl genrsa -out ca/ca.key 2048
openssl req -x509 -new -key ca/ca.key -days 365   -subj "/CN=PKI-Lab Root CA" -out ca/ca.crt

# 3.2 nginx-a server key/CSR with SANs for Kubernetes service DNS
openssl genrsa -out a/server.key 2048
openssl req -new -key a/server.key -out a/server.csr   -subj "/CN=nginx-a.pki-lab.svc.cluster.local"
cat > a/a.ext <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature, keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names
[alt_names]
DNS.1=nginx-a
DNS.2=nginx-a.pki-lab
DNS.3=nginx-a.pki-lab.svc
DNS.4=nginx-a.pki-lab.svc.cluster.local
EOF
openssl x509 -req -in a/server.csr -CA ca/ca.crt -CAkey ca/ca.key   -CAcreateserial -out a/server.crt -days 365 -extfile a/a.ext

# 3.3 nginx-b server key/CSR with SANs
openssl genrsa -out b/server.key 2048
openssl req -new -key b/server.key -out b/server.csr   -subj "/CN=nginx-b.pki-lab.svc.cluster.local"
cat > b/b.ext <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature, keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names
[alt_names]
DNS.1=nginx-b
DNS.2=nginx-b.pki-lab
DNS.3=nginx-b.pki-lab.svc
DNS.4=nginx-b.pki-lab.svc.cluster.local
EOF
openssl x509 -req -in b/server.csr -CA ca/ca.crt -CAkey ca/ca.key   -CAserial ca/ca.srl -out b/server.crt -days 365 -extfile b/b.ext
```

**Why SANs?** Modern TLS verifies the hostname you connect to **only** against the certificate’s **Subject Alternative Name** list. Because inside Kubernetes you will connect as `https://nginx-a.pki-lab.svc.cluster.local:8443`, that exact FQDN **must** appear in the SANs.

---

## 4) Create K8s secrets and CA ConfigMap
```bash
kubectl create namespace pki-lab

# Secrets for the two servers (no need to base64 by hand)
kubectl -n pki-lab create secret tls tls-a --cert=a/server.crt --key=a/server.key
kubectl -n pki-lab create secret tls tls-b --cert=b/server.crt --key=b/server.key

# CA as a ConfigMap so client pods can trust the servers
kubectl -n pki-lab create configmap ca-cm --from-file=ca.crt=ca/ca.crt
```

---

## 5) Apply the manifests (split by purpose)
Download the four YAML files and apply them:
```bash
kubectl apply -f 10-configmaps.yaml
kubectl apply -f 20-deployments.yaml
kubectl apply -f 30-services.yaml
kubectl apply -f 40-curl-pod.yaml
```

Check resources:
```bash
kubectl -n pki-lab get pods,svc,cm,secret
```

---

## 6) Test with curl

### 6.1 Expected **failure** (client does not trust your CA)
```bash
kubectl -n pki-lab exec curl --   sh -lc 'curl -v https://nginx-a.pki-lab.svc.cluster.local:8443'
```
You should see `curl: (60) SSL certificate problem: unable to get local issuer certificate`.

### 6.2 Success when trusting your CA
```bash
kubectl -n pki-lab exec curl --   sh -lc 'curl -v --cacert /ca/ca.crt https://nginx-a.pki-lab.svc.cluster.local:8443'

kubectl -n pki-lab exec curl --   sh -lc 'curl -v --cacert /ca/ca.crt https://nginx-b.pki-lab.svc.cluster.local:8443'
```
You should see `SSL certificate verify ok` and then `Hello from nginx-a (TLS)` or `Hello from nginx-b (TLS)`.

> Convenience: inside the curl pod you can export `CURL_CA_BUNDLE=/ca/ca.crt` and then omit `--cacert`:

```bash
kubectl -n pki-lab exec curl -- sh -lc  'export CURL_CA_BUNDLE=/ca/ca.crt && curl -v https://nginx-a.pki-lab.svc.cluster.local:8443 && curl -v https://nginx-b.pki-lab.svc.cluster.local:8443'
```

---

## 7) Why the name `nginx-b.pki-lab.svc.cluster.local`?

Kubernetes DNS builds service names as:
```
<SERVICE_NAME>.<NAMESPACE>.svc.cluster.local
```
- `SERVICE_NAME` → here `nginx-b` (from the Service metadata.name).  
- `NAMESPACE` → `pki-lab`.  
- `svc` → the DNS subdomain for cluster services.  
- `cluster.local` → the cluster domain (default; can be different in some clusters).

**Resolution details:**
- Inside the same namespace, you may use the short name `nginx-b` (KubeDNS adds search domains).  
- From other namespaces, you typically use `nginx-b.pki-lab` (or the full FQDN).  
- TLS hostname verification requires the **exact** name used in the URL to be present in the certificate SANs.

**Visualize/verify DNS:**
```bash
kubectl -n pki-lab get svc nginx-a nginx-b -o wide
kubectl -n pki-lab exec curl -- sh -lc 'apk add --no-cache bind-tools >/dev/null 2>&1 || true; dig +short nginx-b.pki-lab.svc.cluster.local'
kubectl -n pki-lab exec curl -- sh -lc 'nslookup nginx-b.pki-lab.svc.cluster.local || true'
```

**Visualize certificate SANs from the cluster:**
```bash
kubectl -n pki-lab exec curl -- sh -lc  "apk add --no-cache openssl >/dev/null 2>&1 || true;   echo | openssl s_client -connect nginx-b.pki-lab.svc.cluster.local:8443 -servername nginx-b.pki-lab.svc.cluster.local -showcerts 2>/dev/null |   openssl x509 -noout -subject -issuer -ext subjectAltName"
```

---

## 8) Files in this lab

### `10-configmaps.yaml`
- `nginx-a-conf`, `nginx-b-conf` — minimal NGINX configs enabling TLS on port **8443**, pointing to the mounted server cert/key. (mTLS is **off** to keep the lab minimal.)

### `20-deployments.yaml`
- Two Deployments (`nginx-a`, `nginx-b`) that mount the TLS secrets and the configmaps.

### `30-services.yaml`
- Two ClusterIP Services listening on `8443` routed to each Deployment.

### `40-curl-pod.yaml`
- A simple `curl` pod that mounts the `ca.crt` from the `ca-cm` ConfigMap so you can pass `--cacert /ca/ca.crt`.

---

## 9) Clean up
```bash
kubectl delete -f 40-curl-pod.yaml
kubectl delete -f 30-services.yaml
kubectl delete -f 20-deployments.yaml
kubectl delete -f 10-configmaps.yaml
kubectl -n pki-lab delete secret tls-a tls-b
kubectl -n pki-lab delete configmap ca-cm
kubectl delete ns pki-lab
```

---

## 10) Optional next step: mTLS
- Issue a **client** cert (`client.crt`/`client.key`) signed by your CA.
- In the NGINX configs add:  
  ```nginx
  ssl_client_certificate /etc/nginx/ca/ca.crt;
  ssl_verify_client on;
  ```
- Mount the CA in the NGINX pods at `/etc/nginx/ca` and call from curl with `--cert` and `--key`.

This extends the lab so **both sides** authenticate each other.
