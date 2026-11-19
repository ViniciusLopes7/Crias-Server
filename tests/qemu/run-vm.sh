#!/bin/bash
# GitHub runner: boots a disposable official Arch cloud VM via QEMU.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
cleanup() {
    if [ -n "${vm_pid:-}" ]; then kill "$vm_pid" 2>/dev/null || true; wait "$vm_pid" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT
base=https://fastly.mirror.pkgbuild.com/images/latest
image=Arch-Linux-x86_64-cloudimg.qcow2
curl -fsSL --retry 3 --connect-timeout 20 --max-time 900 "$base/$image" -o "$tmp/$image"
curl -fsSL --retry 3 --connect-timeout 20 --max-time 900 "$base/$image.SHA256" -o "$tmp/$image.SHA256"
(cd "$tmp" && sha256sum -c "$image.SHA256")
qemu-img resize "$tmp/$image" 12G
ssh-keygen -q -t ed25519 -N '' -f "$tmp/key"
key=$(cat "$tmp/key.pub")
cat > "$tmp/user-data" <<CLOUD
#cloud-config
users:
  - name: ci
    groups: [wheel]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $key
ssh_pwauth: false
CLOUD
printf 'instance-id: crias-ci\nlocal-hostname: crias-ci\n' > "$tmp/meta-data"
cloud-localds "$tmp/seed.img" "$tmp/user-data" "$tmp/meta-data"
cp /usr/share/OVMF/OVMF_VARS.fd "$tmp/vars.fd"
accel=tcg
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then accel=kvm; fi
qemu-system-x86_64 -machine q35,accel="$accel" -cpu max -smp 2 -m 2048 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file="$tmp/vars.fd" \
    -drive if=virtio,format=qcow2,file="$tmp/$image" \
    -drive if=virtio,format=raw,file="$tmp/seed.img" \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0 \
    -nographic -no-reboot > "$tmp/serial.log" 2>&1 &
vm_pid=$!
ssh_opts=(-i "$tmp/key" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
ready=false
for i in $(seq 1 120); do
    if ssh "${ssh_opts[@]}" ci@127.0.0.1 true 2>/dev/null; then ready=true; break; fi
    if ! kill -0 "$vm_pid" 2>/dev/null; then break; fi
    sleep 5
done
if [ "$ready" != true ]; then cat "$tmp/serial.log" >&2; exit 1; fi
ssh "${ssh_opts[@]}" ci@127.0.0.1 'sudo cloud-init status --wait'
tar -C "$root" --exclude=.git -czf "$tmp/repo.tar.gz" .
scp -q -i "$tmp/key" -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$tmp/repo.tar.gz" ci@127.0.0.1:/tmp/crias-repo.tar.gz
ssh "${ssh_opts[@]}" ci@127.0.0.1 'mkdir -p /tmp/crias-repo && tar -xzf /tmp/crias-repo.tar.gz -C /tmp/crias-repo && sudo bash /tmp/crias-repo/tests/qemu/guest-test.sh /tmp/crias-repo'
