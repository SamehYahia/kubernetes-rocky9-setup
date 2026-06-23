#!/bin/bash

# ==============================================================================
# Script Name: setup-ubuntu-master.sh
# Description: Prepares Ubuntu 20.04 MASTER Node for Kubernetes (Control Plane)
# Author: Sameh 
# ==============================================================================

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run with sudo or root privileges!"
  exit 1
fi

echo "Starting master server configuration (Ubuntu 20.04) for Control Plane..."
echo "------------------------------------------------------------"

# 1. Configure SELinux (Set to Permissive)
echo "Step 1: Setting SELinux to Permissive..."
setenforce 0
if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    echo "Successfully configured SELinux."
fi

# 2. Stop and Disable Firewall
echo "Step 2: Stopping firewall and clearing iptables..."
systemctl stop firewalld
systemctl disable firewalld
iptables -F
echo "Successfully stopped firewalld and flushed iptables."

# 3. Enable required Kernel Modules for Routing and Bridging
echo "Step 3: Enabling required kernel modules (overlay & br_netfilter)..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
echo "Successfully loaded kernel modules."

# 4. Configure Sysctl settings for IP Forwarding
echo "Step 4: Configuring Sysctl settings (IP Forwarding)..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
echo "Successfully applied kernel network settings."

# 5. Resolve DNS path issue for Kubernetes Sandbox
echo "Step 5: Resolving default resolv.conf path..."
mkdir -p /run/systemd/resolve/
ln -sf /etc/resolv.conf /run/systemd/resolve/resolv.conf
echo "Successfully created Symlink for the default path."

# 6. Restart and Enable core services
echo "Step 6: Restarting and enabling containerd and kubelet..."
systemctl daemon-reload
systemctl enable --now containerd
systemctl enable --now kubelet
systemctl restart containerd kubelet

echo "------------------------------------------------------------"
echo "Configuration complete! The master server is now ready for: kubeadm init"