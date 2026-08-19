# Copy this to something like local.pkrvars.hcl (already gitignored) and fill in
# real values, then: packer build -var-file=local.pkrvars.hcl windows10.pkr.hcl
#
# For a local ISO, get the checksum with:
#   Get-FileHash C:\isos\win10pro.iso -Algorithm SHA256

iso_url      = "C:/isos/win10pro.iso"
iso_checksum = "sha256:REPLACE_WITH_HASH_FROM_GET-FILEHASH"