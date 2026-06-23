#!/bin/bash

# ==============================================================================
# Script Name: setup-rocky-node.sh
# Description: Prepares Rocky Linux 9 Node for Kubernetes & Calico Networking
# Author: Sameh 
# ==============================================================================

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run with sudo or root privileges!"
  exit 1
fi

echo "Starting server configuration (Rocky Linux) for Kubernetes..."
echo "------------------------------------------------------------"

# 1. Configure SELinux (Set to Permissive)
echo "Step 1: Setting SELinux to Permissive..."
setenforce 0
if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    echo "Successfully updated SELinux config file."
else
    echo "Warning: /etc/selinux/config file not found."
fi

# 2. Stop and Disable Firewall
echo "Step 2: Stopping firewall and clearing iptables..."
systemctl stop firewalld
systemctl disable firewalld
iptables -F
echo "Successfully stopped firewalld and flushed iptables rules."

# 3. Resolve DNS path issue for Kubernetes Sandbox
echo "Step 3: Resolving resolv.conf path for systemd-resolved..."
mkdir -p /run/systemd/resolve/
ln -sf /etc/resolv.conf /run/systemd/resolve/resolv.conf
echo "Successfully created Symlink for the default path."

# 4. Restart Kubernetes and Container Runtime services
echo "Step 4: Restarting containerd and kubelet to apply changes..."
systemctl daemon-reload
systemctl restart containerd
systemctl restart kubelet
echo "Successfully restarted services."

echo "------------------------------------------------------------"
echo "Configuration complete! The server is ready and Pods should start shortly."