# Creating a Cert Bundle Manually

[← Back to README](../README.md)

For MDM/at-scale deployment, the recommended path is distributing an existing bundle rather than putting the tenant name and org key on every endpoint — see [Recommended for MDM / at-scale deployment](../README.md#silent--automated-deployment) and the [deployment guides](../README.md#deploying-via-a-specific-mdmrmm-tool).

To prepare a bundle for distribution without running any of the scripts interactively, build it directly with two requests — this is exactly what the scripts do internally, so the result is a drop-in replacement for `--cert-bundle`/`-CertBundle` anywhere in this repo's docs:

```sh
# Linux / macOS
TENANT=mytenant.eu.goskope.com
ORGKEY=your-org-key

curl -k -f "https://addon-$TENANT/config/org/cert?orgkey=$ORGKEY" > netskope-cert-bundle.pem   # RootCA first
curl -k -f "https://addon-$TENANT/config/ca/cert?orgkey=$ORGKEY" >> netskope-cert-bundle.pem    # SubCA second

# Optional: append the public CA roots too (full bundle, the default the scripts produce,
# full bundle is recommended in most use cases and it makes sure applications will still
# work even when there is an SSL decryption bypass)
curl -k -f -L https://curl.se/ca/cacert.pem >> netskope-cert-bundle.pem

# Sanity check — should print 2 (or 3 with the public roots appended)
grep -c "BEGIN CERTIFICATE" netskope-cert-bundle.pem
```

```powershell
# Windows PowerShell
$tenant = "mytenant.eu.goskope.com"
$orgKey = "your-org-key"

$root = (Invoke-WebRequest -Uri "https://addon-$tenant/config/org/cert?orgkey=$orgKey" -SkipCertificateCheck).Content
$sub  = (Invoke-WebRequest -Uri "https://addon-$tenant/config/ca/cert?orgkey=$orgKey"  -SkipCertificateCheck).Content
[System.IO.File]::WriteAllBytes("netskope-cert-bundle.pem", $root + $sub)

# Optional: append the public CA roots too (full bundle, the default the scripts produce,
# full bundle is recommended in most use cases and it makes sure applications will still
# work even when there is an SSL decryption bypass)
$pub = (Invoke-WebRequest -Uri "https://curl.se/ca/cacert.pem" -SkipCertificateCheck).Content
[System.IO.File]::WriteAllBytes("netskope-cert-bundle.pem", $root + $sub + $pub)
```

The order matters — RootCA, then SubCA, then (optionally) the public roots — since that's the chain order every script in this repo produces and validates against.

Once you have `netskope-cert-bundle.pem`, use it with `--cert-bundle`/`-CertBundle` — see [Usage Examples](usage-examples.md) and the [deployment guides](../README.md#deploying-via-a-specific-mdmrmm-tool).
