# Mini PKI & TLS Lab with Docker
**From zero to a working HTTPS endpoint (and the foundation for mTLS)**

> **Audience:** students and engineers who want a hands‑on, minimal, fully local lab to understand how PKI, certificates, and TLS actually work.  
> **Goal:** issue your own **CA**, create a **server certificate** with proper **SANs**, run **NGINX over TLS** in Docker, and verify it with `curl` while understanding **why** each step matters.

---

## 1) What you will build
- A private **Certificate Authority (CA)** (self‑signed), i.e., your own local "root of trust".  
- A **server private key** and a **server certificate** signed by your CA (contains the server **public key**).  
- An NGINX container that serves HTTPS using that server certificate.  
- A client (`curl`) that validates the server’s identity **only** if it trusts your CA.

This proves the essential PKI ideas used daily in HTTPS, VPNs, and service‑to‑service security.

---

## 2) Prerequisites
- Docker + Docker Compose
- OpenSSL (1.1.1+ recommended)
- Bash (or a shell that can run the commands below)

---

## 3) Folder layout
Create a new working directory (e.g., `pki-lab`) and inside it:
```
pki-lab/
├─ ca/            # your Certificate Authority (root of trust)
├─ server/        # server private key + certificate
├─ nginx/         # nginx.conf
├─ Dockerfile
└─ docker-compose.yml
```

> We'll generate files into these folders step by step.

---

## 4) Primer: PKI concepts (short & practical)

- **Asymmetric cryptography:** a **private key** (keep it secret) and a **public key** (shareable). Anything encrypted with one can be verified/decrypted with the other.
- **Certificate (X.509):** a public key plus identity metadata (subject, validity, SANs…), **digitally signed** by an issuer.
- **CA (Certificate Authority):** a special identity that signs other certificates. Clients trust a CA’s certificate (`ca.crt`), and therefore trust anything it signs.
- **Certificate chain:** your server cert is trusted because a trusted CA signed it (or an intermediate CA signed by a trusted root). In this lab we use a single root CA.
- **SAN (Subject Alternative Name):** the official place to list hostnames/IPs the certificate is valid for. Modern TLS ignores the old CN for hostname matching—**SANs are mandatory**.
- **TLS handshake (high level):** client and server negotiate algorithms, the server proves identity with its certificate, and both sides derive a symmetric session key for fast encryption.

Keep these in mind as we build.

---

## 5) Step‑by‑step: build your CA and server cert

### 5.1 Create directories
```bash
mkdir -p ca server nginx
```

### 5.2 Generate your **CA private key**
```bash
openssl genrsa -out ca/ca.key 2048
```
**Why:** The CA **private key** is the *ultimate secret* of your PKI. Anything signed with it will be trusted by clients that import your CA certificate. Keep `ca/ca.key` safe.

> For production‑grade setups use 3072/4096 bits and protect the key with a passphrase (e.g., `-aes256`).

### 5.3 Create a **self‑signed CA certificate**
```bash
openssl req -x509 -new -key ca/ca.key -days 365 \
  -subj "/C=CO/O=PKI Lab/CN=PKI-Lab Root CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -addext "authorityKeyIdentifier=keyid:always,issuer" \
  -out ca/ca.crt
```
**Why:** This produces `ca/ca.crt`, the **public** part of your CA. Clients will **trust** your server **only** if they’re configured to trust this CA. The extensions make it a proper CA certificate (able to sign other certificates).

> If your OpenSSL doesn’t support `-addext`, you can omit those flags for the lab, or use an `openssl.cnf` with `-extensions v3_ca`.

### 5.4 Generate a **server private key**
```bash
openssl genrsa -out server/server.key 2048
```
**Why:** The server **private key** proves the server’s identity and enables decryption during TLS. Keep it secret inside the container or host. The corresponding **public key** will be embedded in the server certificate we’ll create next.

### 5.5 Create a **CSR** (Certificate Signing Request) for the server
```bash
openssl req -new -key server/server.key -out server/server.csr \
  -subj "/CN=server.local"
```
**Why:** The CSR packages the public key and identity information for the CA to sign. The CN is largely ignored for hostnames in modern TLS, but it’s still customary to set.

### 5.6 Define **SANs** (the names/addresses clients will connect to)
Create `server/server.ext`:
```ini
basicConstraints=CA:FALSE
keyUsage=digitalSignature, keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names
[alt_names]
DNS.1=server.local
DNS.2=localhost
IP.1=127.0.0.1
```
**Why:** **This is crucial.** Clients validate the hostname they used against the certificate’s **SANs**. If you access `https://localhost:8443`, `localhost` must appear here, otherwise you’ll get:  
`SSL: no alternative certificate subject name matches target host name 'localhost'`.

### 5.7 **Sign** the server certificate with your CA
```bash
openssl x509 -req -in server/server.csr -CA ca/ca.crt -CAkey ca/ca.key \
  -CAcreateserial -out server/server.crt -days 365 -extfile server/server.ext
```
**Why:** The CA signs the CSR and produces `server/server.crt`. This file contains the **server public key** and identity, and is **trusted** by any client that trusts `ca/ca.crt`.

### 5.8 (Optional) Inspect & verify
```bash
# Inspect SANs and validity
openssl x509 -noout -text -in server/server.crt | sed -n '/Subject Alternative Name/,+5p'

# Cryptographic verification against your CA
openssl verify -CAfile ca/ca.crt server/server.crt
```

---

## 6) NGINX over TLS in Docker

### 6.1 NGINX config (`nginx/nginx.conf`)
```nginx
events {}
http {
  server {
    listen 443 ssl;
    server_name _;  # we won't enforce a single hostname at the HTTP layer

    ssl_certificate     /etc/nginx/tls/server.crt;  # public cert (contains public key)
    ssl_certificate_key /etc/nginx/tls/server.key;  # matching private key

    # mTLS is OFF for this basic lab (we only prove the server's identity)
    ssl_verify_client off;

    location / {
      default_type text/plain;
      return 200 "OK: TLS is on\n";
    }
  }
}
```

### 6.2 Dockerfile
```dockerfile
FROM nginx:alpine
COPY nginx/nginx.conf /etc/nginx/nginx.conf
RUN mkdir -p /etc/nginx/tls
COPY server/server.crt /etc/nginx/tls/server.crt
COPY server/server.key /etc/nginx/tls/server.key
```

### 6.3 docker-compose.yml
```yaml
services:
  nginx:
    build: .
    container_name: pki-nginx
    ports:
      - "8443:443"
    networks:
      pki:
        aliases:
          - server.local
networks:
  pki: {}
```

### 6.4 Build & run
```bash
docker compose build --no-cache
docker compose up -d
```

---

## 7) Test with `curl` (and understand the results)

### 7.1 Without trusting your CA (expected failure)
```bash
curl -v https://localhost:8443
```
**Why it fails:** your OS/browser don’t know your private CA. You’ll see an error like **`unable to get local issuer certificate`**.

### 7.2 Trust your CA for this command only (success)
```bash
curl -v --cacert ca/ca.crt https://localhost:8443
```
**Why it succeeds:** you explicitly tell `curl` to trust `ca/ca.crt`. It validates the server’s certificate chain, checks **SAN = localhost**, completes the **TLS handshake**, and then you see `OK: TLS is on`.

> Tip: if you want to avoid `--cacert` every time (only for `curl`), you can:
> ```bash
> export CURL_CA_BUNDLE="$PWD/ca/ca.crt"
> curl -v https://localhost:8443
> ```

### 7.3 Access by `server.local` (no `/etc/hosts` changes needed)
```bash
curl -v --cacert ca/ca.crt \
  --resolve server.local:8443:127.0.0.1 \
  https://server.local:8443
```
**Why it works:** we included `server.local` in SANs and we map the hostname to `127.0.0.1` just for this call.

---

## 8) Understanding the artifacts

| File | Secret? | Purpose |
|---|---|---|
| `ca/ca.key` | **YES** | The **CA private key**. Used to sign other certificates. Guard it carefully. |
| `ca/ca.crt` | No | The **CA certificate** (public part). Distribute to clients so they can trust what your CA signs. |
| `server/server.key` | **YES** | The **server private key**. Proves the server’s identity and decrypts traffic. Must match the public key in `server.crt`. |
| `server/server.csr` | No | Certificate Signing Request sent to the CA. Contains the server public key and identity to be signed. |
| `server/server.ext` | No | Extra X.509 extensions, notably **SANs** (hostnames/IPs the certificate is valid for). |
| `server/server.crt` | No | The **server certificate** (contains the server **public key** + identity) **signed by your CA**. |
| `nginx/nginx.conf` | No | HTTPS server configuration, pointing to the cert/key. |
| `Dockerfile` | No | Builds an image with NGINX + your TLS materials. |
| `docker-compose.yml` | No | Runs the container and exposes port `8443`. |

**Private vs Public keys** (mental model):  
- A **private key** stays hidden and is used to **sign** (prove identity) or **decrypt**.  
- The corresponding **public key** is **public** and is used to **verify signatures** or **encrypt for the private key holder**.  
- A **certificate** is essentially: **public key + identity + CA’s signature**.

---

## 9) Optional next step: add **mTLS** (client authentication)
- Generate a **client private key** and **client certificate** signed by your CA.  
- Configure NGINX with `ssl_client_certificate /etc/nginx/tls/ca.crt;` and `ssl_verify_client on;`  
- Call with `curl --cert client.crt --key client.key --cacert ca/ca.crt https://...`  
This proves **both** sides’ identities.

---

## 10) Common errors & fixes
- **`unable to get local issuer certificate`** → your client does not trust the CA. Use `--cacert ca/ca.crt` (or install the CA in the OS trust store).  
- **`no alternative certificate subject name matches target host name`** → your SANs are missing the hostname you used (e.g., `localhost`). Re‑issue the server cert with the correct SANs.  
- **`key values do not match`** (NGINX start failure) → the private key and certificate don’t belong together. Recreate the CSR/cert from the same private key.

---

## 11) Clean up
```bash
docker compose down -v
```

---

### That’s it!
You now have a complete, minimal PKI lab: your own CA, a signed server certificate with proper SANs, a TLS‑enabled service in Docker, and a client that validates the server using your CA. This is the same foundation behind real‑world HTTPS and can be extended to mTLS, Ingress controllers, service meshes, and beyond.
