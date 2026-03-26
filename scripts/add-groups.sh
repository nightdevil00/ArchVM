#!/bin/bash
for group in docker libvirt vboxusers wireshark kvm input uucp; do
    if ! getent group "$group" > /dev/null 2>&1; then
        sudo groupadd "$group"
    fi
done
sudo usermod -aG docker,libvirt,vboxusers,wireshark,kvm,input,uucp mihai
echo "Done. Run 'groups' to verify or log out/in."
