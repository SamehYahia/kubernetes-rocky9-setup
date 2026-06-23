# Kubernetes Cluster Setup — Ubuntu Master + Rocky Linux Workers

A complete guide to building a production-style Kubernetes cluster using `kubeadm` with an **Ubuntu** Control Plane and **Rocky Linux 9** Worker Nodes. This repo covers every real-world error we hit, why it happened, and how we fixed it — plus automation scripts to save you the pain next time.

---

## Cluster Architecture

| Role         | OS           | IP Address       |
|--------------|--------------|-----------------|
| master-node  | Ubuntu 22.04 | 192.168.10.143  |
| worker-1     | Rocky Linux 9| 192.168.10.144  |
| worker-2     | Rocky Linux 9| 192.168.10.145  |

**Kubernetes version:** v1.30.14  
**Container Runtime:** containerd  
**CNI Plugin:** Calico v3.28

---

## Prerequisites

- 3 virtual or physical machines (minimum 2 vCPUs / 2 GB RAM each)
- Static IP addresses configured on all nodes
- SSH access from the master to all workers
- Internet access on all nodes

---

## Part 1 — Manual Step-by-Step Guide

### Step 1: System Preparation (All Nodes)

**Set unique hostnames:**
```bash
# On master
sudo hostnamectl set-hostname master-node

# On worker-1
sudo hostnamectl set-hostname worker-1

# On worker-2
sudo hostnamectl set-hostname worker-2
```

**Disable Swap:**
```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

**Enable Kernel Modules:**
```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

**Configure sysctl for bridged traffic:**
```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

---

### Step 2: Install containerd (All Nodes)

```bash
# Add Docker repository (containerd source)
sudo apt-get update && sudo apt-get install -y ca-certificates curl gnupg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update && sudo apt-get install -y containerd.io

# Configure containerd to use systemd cgroup driver (critical for stability)
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

> **Why SystemdCgroup = true?**  
> If Docker is already installed, its `containerd` defaults to the `cgroupfs` driver. Kubernetes requires `systemd`. Mismatching drivers causes the kubelet to crash silently — this was one of our hardest bugs to diagnose.

---

### Step 3: Install Kubernetes Tools (All Nodes)

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
  | sudo gpg --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

---

### Step 4: Initialize the Control Plane (Master Only)

```bash
sudo kubeadm init \
  --apiserver-advertise-address=192.168.10.143 \
  --pod-network-cidr=192.168.0.0/16
```

**After init completes, configure kubectl:**
```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

> **Save the `kubeadm join` command** printed at the end — you will need it for every worker.

---

### Step 5: Install Calico CNI (Master Only)

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

Nodes will remain `NotReady` until Calico is installed and its pods reach `Running` state.

---

### Step 6: Join Worker Nodes

On each worker, run the join command from Step 4:
```bash
sudo kubeadm join 192.168.10.143:6443 \
  --token <your-token> \
  --discovery-token-ca-cert-hash sha256:<your-hash>
```

To generate a new join token at any time:
```bash
kubeadm token create --print-join-command
```

---

### Step 7: Verify the Cluster

```bash
kubectl get nodes
kubectl get pods -n kube-system -o wide
```

Expected output:
```
NAME          STATUS   ROLES           AGE   VERSION
master-node   Ready    control-plane   5m    v1.30.14
worker-1      Ready    <none>          3m    v1.30.14
worker-2      Ready    <none>          2m    v1.30.14
```

---

## Part 2 — Real-World Problems & Solutions

These are the exact errors we encountered building this lab.

---

### Problem 1: Broken Package Dependencies (`Unmet dependencies`)

**Symptom:**
```
E: Package 'cri-tools' has no installation candidate
E: Unmet dependencies. Try 'apt --fix-broken install'
```

**Root Cause:** Manually installing `.deb` packages with `dpkg -i` without their dependencies locked the `apt` package manager, blocking all subsequent installs.

**Fix:**
```bash
# Force-remove the broken local packages
sudo dpkg --remove --force-remove-reinstreq kubeadm kubelet kubectl

# Let apt repair itself and download clean versions
sudo apt-get install -f -y
sudo apt-get install -y kubeadm kubelet kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

---

### Problem 2: Silent Firewall Timeout (`context deadline exceeded`)

**Symptom:**
```
couldn't validate the identity of the API Server:
... context deadline exceeded
```

**Root Cause:** UFW (Ubuntu firewall) on the master node was blocking port `6443` — the Kubernetes API Server port — preventing workers from connecting.

**Fix:**
```bash
# On the master node
sudo ufw disable
```

---

### Problem 3: Kubelet Crash — Docker & Cgroup Driver Conflict

**Symptom:**
```
The kubelet is not healthy after 4m0s
```

**Root Cause:** Docker was previously installed on the worker nodes. Docker configures `containerd` to use the `cgroupfs` driver by default, while Kubernetes requires `systemd`. This mismatch caused the kubelet to silently fail on startup.

**Fix:**
```bash
sudo swapoff -a

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

sudo systemctl restart containerd
```

---

### Problem 4: Rocky Linux — SELinux Blocking Calico (`Init:0/3`)

**Symptom:** Calico pods stuck at `Init:0/3` on Rocky Linux workers for 20+ minutes.

**Root Cause:** SELinux in `Enforcing` mode prevented Calico's init containers from writing CNI binaries to `/opt/cni/bin` and mounting BPF filesystem paths.

**Fix:**
```bash
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
sudo systemctl restart containerd kubelet
```

---

### Problem 5: Rocky Linux — Missing DNS Path (`no such file or directory`)

**Symptom:**
```
Failed to create pod sandbox:
open /run/systemd/resolve/resolv.conf: no such file or directory
```

**Root Cause:** The kubelet expects `systemd-resolved` to manage DNS at a specific path (`/run/systemd/resolve/`). Rocky Linux uses `NetworkManager` instead, so this directory does not exist.

**Fix:**
```bash
sudo mkdir -p /run/systemd/resolve/
sudo ln -sf /etc/resolv.conf /run/systemd/resolve/resolv.conf
sudo systemctl restart containerd kubelet
```

---

### Problem 6: SSH Host Key Conflict (`REMOTE HOST IDENTIFICATION HAS CHANGED`)

**Symptom:**
```
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
Host key verification failed.
```

**Root Cause:** A VM was rebuilt and got a new SSH fingerprint, but the old one was still cached in `~/.ssh/known_hosts`.

**Fix:**
```bash
ssh-keygen -f '/home/sameh/.ssh/known_hosts' -R '192.168.10.144'
ssh-keygen -f '/home/sameh/.ssh/known_hosts' -R '192.168.10.145'
```

---

## Part 3 — Automation Scripts

For a faster, repeatable setup, use the scripts in the `scripts/` directory.

| Script | Purpose |
|--------|---------|
| `scripts/ubuntu_master.sh` | Prepares Ubuntu master node (kernel modules, sysctl, containerd, k8s tools) |
| `scripts/Rocky_worker.sh` | Fixes all Rocky Linux-specific issues (SELinux, firewall, DNS path) |

**Usage:**
```bash
chmod +x scripts/Rocky_worker.sh
sudo ./scripts/Rocky_worker.sh
```

Run these scripts **before** executing `kubeadm init` (master) or `kubeadm join` (workers).

---

## Verification Commands

```bash
# Check all node statuses
kubectl get nodes

# Check all system pods and their assigned nodes
kubectl get pods -n kube-system -o wide

# Check component health
kubectl get componentstatuses

# Watch nodes update in real time
kubectl get nodes -w
```

---

## Lessons Learned

- Always set `SystemdCgroup = true` in containerd config when Kubernetes is involved
- On Red Hat family (Rocky, RHEL, Fedora): disable SELinux and firewalld before joining
- The `/run/systemd/resolve/resolv.conf` symlink is mandatory on non-systemd-resolved distros
- Manual `dpkg -i` installs without dependencies will break `apt` — always use the official repository
- Never skip `hostnamectl set-hostname` before joining — duplicate hostnames cause silent cluster conflicts
