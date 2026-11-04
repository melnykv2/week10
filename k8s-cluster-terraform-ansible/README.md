# Week 10 TASK

## How to run

```bash
# 1. Infrastructure (~2 min). Ports are open to everyone; see "Admin access" to restrict them.
cd terraform
terraform init
terraform apply

# 2. Cluster bootstrap (~6-8 min)
cd ../ansible
ansible-playbook site.yml

# 3. Use the cluster from your laptop
export KUBECONFIG=~/week10/k8s-cluster-terraform-ansible/artifacts/admin-remote.kubeconfig
kubectl get nodes -o wide

# 4. Open the nginx test website (NodePort service created by the smoke test)
NODE_PORT=$(kubectl get svc nginx -o jsonpath='{.spec.ports[0].nodePort}')
cd ../terraform && terraform output worker_public_ips    # any worker IP works
curl -I http://<worker-public-ip>:$NODE_PORT              # or open it in a browser

# 5. Tear down when finished (stops the AWS charges)
cd ../terraform && terraform destroy
```

You can run a single step again with tags, for example `ansible-playbook site.yml --tags smoke-test`. Running the whole playbook again is safe: it is idempotent, and a second run of the certs/configs plays reports `changed=0`.

**Cost:** 3 × t3.small plus an Elastic IP and EBS comes to about $0.07/h in us-east-1.

---

## Admin access

SSH (22), the Kubernetes API (6443), NodePorts (30000–32767) and ping are **open to everyone** (`admin_cidrs = ["0.0.0.0/0"]` by default). 

To restrict access later (for example, to an office network or a VPN exit IP), copy `terraform/terraform.tfvars.example` to `terraform.tfvars`, list the networks in `admin_cidrs`, and run `terraform apply`. Only the security group changes; the instances are not touched.

## Step-by-step

### Infrastructure (Terraform)

* **Static private IPs** (`10.240.0.1x` for controllers, `10.240.0.2x` for workers), so certificate SANs and configs are predictable.
* An **Elastic IP** on the controller. Its public address goes into the API server certificate and the remote kubeconfig, so it must not change when the instance stops and starts.
* `source_dest_check = false` on the workers, and **one VPC route per worker** (`10.200.N.0/24 → worker-N ENI`). This is the pod network, with no overlay.
* A security group that allows all traffic inside the VPC and the pod CIDR, and SSH (22), the Kubernetes API (6443), NodePort services (30000–32767) and ICMP from `admin_cidrs` (everyone by default).
* `local_file` renders `ansible/inventory.ini`. Each host gets `ansible_host`, `private_ip` and (for workers) `pod_cidr`.

A pre-play in `site.yml` runs before the 10 steps. It sets each node's hostname to its inventory name (`controller-0`, `worker-0`, …), turns on cloud-init's `preserve_hostname` and writes `/etc/hosts` entries for every node. The hostname must match the node certificate's CN.

### Step 1 — Provision the CA and generate TLS certificates (`generate-certs`)

This step runs **locally** (`hosts: localhost`) with `openssl`:

1. It creates a 4096-bit CA key and a self-signed CA certificate (`ca.crt`, valid 10 years).
2. For each certificate it renders an openssl config from `cert.conf.j2` (CN, O, EKU, SANs), then generates a key and a CSR and signs it with the CA:

| Cert | CN | O | Used by |
|---|---|---|---|
| admin | `admin` | `system:masters` | kubectl |
| worker-N | `system:node:worker-N` | `system:nodes` | kubelet (client + serving cert) |
| kube-proxy | `system:kube-proxy` | `system:node-proxier` | kube-proxy |
| kube-controller-manager | `system:kube-controller-manager` | same | controller-manager |
| kube-scheduler | `system:kube-scheduler` | same | scheduler |
| kube-api-server | `kubernetes` | `Kubernetes` | apiserver serving cert, client cert to kubelets/etcd, etcd server/peer |
| service-accounts | `service-accounts` | `Kubernetes` | signing ServiceAccount tokens |

The API server certificate's SANs are `10.32.0.1` (the `kubernetes` service IP), `127.0.0.1`, the controller private and public IPs, and `kubernetes.default.svc.cluster.local` plus the other DNS names. Every certificate is checked with `openssl verify`.

The tasks are idempotent: keys and certs use `creates:`. If a certificate's config changes (for example, a new IP after you re-provision), that certificate is deleted and issued again.

### Step 2 — Kubernetes configuration files for authentication (`generate-configs`)

`kubeconfig.j2` builds a kubeconfig with the CA, client cert and key embedded as base64. That is the same result as `kubectl config set-cluster/set-credentials --embed-certs=true`, but this way is idempotent and needs no local kubectl.

| kubeconfig | API server address |
|---|---|
| worker-N (kubelet), kube-proxy | `https://10.240.0.10:6443` (private IP) |
| kube-controller-manager, kube-scheduler, admin | `https://127.0.0.1:6443` (on the controller) |

### Step 3 — Data encryption config and key (`generate-configs`)

The `password` lookup generates a 32-byte random key and **saves it** to `artifacts/pki/encryption.key`, so later runs reuse the same key. A new key would make the Secrets already in etcd unreadable. `encryption-config.yaml` puts the `aescbc` provider (`key1`) first and `identity` second, which means Secrets are encrypted before they are written to etcd.

### Step 4 — Bootstrap the etcd cluster (`bootstrap-etcd`)

* Downloads etcd and extracts only `etcd` and `etcdctl` into `/usr/local/bin`.
* Copies `ca.crt` and the `kube-api-server` cert and key to `/etc/etcd`.
* Installs a systemd unit with **mutual TLS** for both clients (`--client-cert-auth`) and peers (`--peer-client-cert-auth`). `--initial-cluster` is built from the `controllers` group, so the same role works for a 3-node HA etcd.
* Waits until `etcdctl member list` shows every member as `started`.

### Step 5 — Bootstrap the control plane (`setup-control-plane`)

* Downloads `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` and `kubectl`.
* Copies the certs, the service-account key pair, the encryption config and the kubeconfigs to `/var/lib/kubernetes`.
* Sets up the systemd units:
  * **apiserver:** `Node,RBAC` authorization, `NodeRestriction` admission, the etcd TLS client cert, `--encryption-provider-config`, ServiceAccount token signing/issuer, and `--kubelet-certificate-authority` so the API server checks the kubelet serving certificates.
  * **controller-manager:** `--cluster-cidr=10.200.0.0/16`, signs CSRs with the cluster CA, `--use-service-account-credentials`.
  * **scheduler:** a `KubeSchedulerConfiguration` file.
* Waits for `/readyz` to return `ok`. Then it applies the **`system:kube-apiserver-to-kubelet` ClusterRole/Binding**, which lets the API server (user `kubernetes`) call the kubelet API. `logs`, `exec` and `port-forward` need this.

### Step 6 — Bootstrap the worker nodes (`setup-worker-nodes`)

* Installs OS packages (`socat conntrack ipset iptables`) and turns off swap.
* Loads the `overlay` and `br_netfilter` kernel modules and sets the sysctls `ip_forward=1` and `bridge-nf-call-iptables=1`. Both are kept across reboots.
* Installs containerd, runc, the CNI plugins, crictl, kubelet and kube-proxy.
* **CNI:** a `bridge` plugin (`cni0`, `host-local` IPAM with the node's `pod_cidr`, `ipMasq`) plus `loopback`.
* **containerd:** the CRI plugin with `SystemdCgroup = true`, because Ubuntu 24.04 uses cgroup v2.
* **kubelet:** `KubeletConfiguration` with webhook authn/authz, `cgroupDriver: systemd`, `clusterDNS: 10.32.0.10`, `resolvConf: /run/systemd/resolve/resolv.conf`, and its own serving cert. It also runs with `--node-ip`.
* **kube-proxy:** iptables mode, with `clusterCIDR` set.
* Waits until each node reports `Ready`.

### Step 7 — Configure kubectl for remote access (`configure-kubectl`)

Writes `ansible/artifacts/admin-remote.kubeconfig`, which points at the controller's **Elastic IP**. That works because the public IP is a SAN in the API server certificate. Your own `~/.kube/config` is **not** changed. If kubectl is installed locally, the role checks the setup by running `kubectl version` and `kubectl get nodes` through the public endpoint.

### Step 8 — Set up networking (`setup-networking`)

Pod-to-pod traffic across nodes is **routed, with no overlay**:

* **AWS level** (Terraform): VPC routes `10.200.N.0/24 → worker-N ENI`, plus the disabled source/destination check.
* **OS level** (this role): on each worker, `ip route replace <other pod CIDR> via <other worker IP>`. The route is also saved as a netplan drop-in so it survives a reboot. The role then checks the routing table.

### Step 9 — Deploy the DNS cluster add-on (`deploy-dns`)

Applies a CoreDNS manifest: ServiceAccount, RBAC, Corefile ConfigMap, a 2-replica Deployment spread across nodes with anti-affinity, and the `kube-dns` Service with the fixed ClusterIP `10.32.0.10`. The role then waits for `rollout status`.

### Step 10 — Smoke test (`smoke-test`)

Each check is an `assert`, so the playbook **fails** if any of them fails:

| # | Test | How |
|---|---|---|
| 1 | Data encryption | creates a Secret, reads it **directly from etcd** with `etcdctl`, checks for the `k8s:enc:aescbc:v1:key1` prefix and that the plaintext `mydata` is absent |
| 2 | Deployments | `nginx` deployment, `rollout status` |
| 3 | Pod networking | from the controller, HTTP GET to **every nginx pod IP** (crosses the VPC routes) |
| 4 | Port forwarding | `kubectl port-forward deploy/nginx 8080:80`, then `curl` returns `200 OK` |
| 5 | Logs | `kubectl logs` contains the requests above |
| 6 | Exec | `kubectl exec … nginx -v` |
| 7 | Services | NodePort service, then HTTP 200 from **every** worker's node port |
| 8 | DNS | a busybox pod runs `nslookup kubernetes.default.svc.cluster.local`, which should resolve to `10.32.0.1` |

The test resources are left in place for inspection. Run with `-e smoke_cleanup=true` to delete them.

---

## Challenges and how I overcame them

Items 1–8 are the known failure points of a hand-built cluster, which I handled while designing the roles. Item 9 lists the problems that actually came up while I wrote and validated the code. Add anything new from the real run to this list.

1. **macOS ships LibreSSL, not OpenSSL.** The newest KTHW guide uses OpenSSL 3 options such as `-noenc` and `-copy_extensions`, which LibreSSL 3.3 does not support. I used options that both support: `req -new` creates the CSR, and `x509 -req -extfile <conf> -extensions v3_ext` adds the SANs and EKUs when signing. I checked the generated certs with `openssl x509 -text`.
2. **Node name must match the certificate CN.** EC2 hostnames look like `ip-10-240-0-20`. The Node authorizer only lets a kubelet modify the `Node` object whose name is in its cert (`system:node:worker-0`). A pre-play sets the hostname, and kubelet runs with `--node-ip`. cloud-init's `preserve_hostname: true` stops it from resetting the hostname on reboot.
3. **The public IP is baked into the API server certificate.** A plain EC2 public IP changes on stop/start, which would make the certificate and the remote kubeconfig invalid. The fix is an Elastic IP. The certs role also re-issues any certificate whose SAN config changed.
4. **Pod networking on AWS without an overlay.** By default AWS drops packets whose source or destination IP isn't the instance's own, so traffic to pod IPs (`10.200.x.x`) would never arrive. The fix is `source_dest_check = false` on the workers, VPC routes for each worker's pod CIDR, and a security group rule for `10.200.0.0/16`.
5. **CoreDNS forwarding loop.** On Ubuntu, `/etc/resolv.conf` points at systemd-resolved's stub `127.0.0.53`. Inside a pod, that address is the pod itself, so CoreDNS would forward queries to itself, and the `loop` plugin crashes it. The fix is the kubelet setting `resolvConf: /run/systemd/resolve/resolv.conf`, which holds the real VPC resolver.
6. **cgroup v2 on Ubuntu 24.04.** kubelet and containerd must use the same cgroup driver. I set `SystemdCgroup = true` in containerd and `cgroupDriver: systemd` in kubelet. containerd 2.x still reads the `version = 2` config format, so one config works for both 1.7 and 2.x.
7. **Keeping the encryption key the same between runs.** If each run made a new key, existing Secrets could no longer be decrypted. The `password` lookup saves the key to a file and reads it back on later runs.
8. **`kubectl logs/exec/port-forward` return `Forbidden` without extra RBAC.** By default the API server (user `kubernetes`) has no RBAC permission on `nodes/proxy`. The fix is the `system:kube-apiserver-to-kubelet` ClusterRole/Binding.
9. **Ansible problems I hit while writing the roles:**
   * `-o jsonpath={…@.type=="Ready"…}` passed to the `command` module lost its double quotes, because `command` splits arguments shlex-style. I wrapped the jsonpath in single quotes.
   * A bare `that: x is search('Address: …')` failed YAML parsing ("colons in unquoted values"). I changed it to a folded `>-` scalar.
   * The DNS check needed an anchored regex (`Address: 10.32.0.1$`). Otherwise the DNS server address `10.32.0.10` also matches.
   * Building the per-worker cert list as a JSON string in `vars` depends on Ansible's string-to-list conversion, which differs between versions. I replaced it with a `set_fact` loop.
   * `ansible-lint` flagged shell pipes without `pipefail` and extra collection modules (`community.general.modprobe`, `ansible.posix.sysctl`). I added `set -o pipefail` and switched to `modules-load.d`/`sysctl.d` files with `ansible.builtin`. The roles now pass the `production` profile with no extra collections.

## Verification done

* `terraform fmt -check` and `terraform validate` pass.
* `ansible-playbook --syntax-check site.yml` and `ansible-lint` (production profile) pass.
* Steps 1–3 ran for real against a sample inventory. The certificates chain to the CA and have the correct CN/O/EKU/SANs, the AES key is 32 bytes, and a second run reports `changed=0`.
* The node templates (etcd and apiserver units, kubelet config, CNI, netplan) were rendered for sample hosts and checked by reading them. The CNI config also parses as valid JSON.

## End-to-end run log

Deployed on AWS us-east-1 with 1 controller and 2 workers. Commands were run from the Ansible control machine with `KUBECONFIG=ansible/artifacts/admin-remote.kubeconfig`, so they reached the API server remotely through the controller's Elastic IP (Step 7).

**Nodes.** Both workers registered under their certificate names (`worker-0`, `worker-1`) and are `Ready`. They run Kubernetes v1.34.13 on containerd 2.1.6:

```
$ kubectl get nodes -o wide
NAME       STATUS   ROLES    AGE     VERSION    INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION   CONTAINER-RUNTIME
worker-0   Ready    <none>   2m23s   v1.34.13   10.240.0.20   <none>        Ubuntu 24.04.5 LTS   7.0.0-1014-aws   containerd://2.1.6
worker-1   Ready    <none>   2m24s   v1.34.13   10.240.0.21   <none>        Ubuntu 24.04.5 LTS   7.0.0-1014-aws   containerd://2.1.6
```

**Pods.** Each worker hands out IPs from its own pod CIDR (worker-0 `10.200.0.0/24`, worker-1 `10.200.1.0/24`). The anti-affinity rule spreads the two CoreDNS replicas across both nodes. `dns-test` is the smoke-test DNS pod, and `Completed` means its `nslookup` succeeded:

```
$ kubectl get pods -A -o wide
NAMESPACE     NAME                       READY   STATUS      RESTARTS   AGE    IP           NODE
default       dns-test                   0/1     Completed   0          70s    10.200.0.4   worker-0
default       nginx-85f7d4dd78-m4nx2     1/1     Running     0          90s    10.200.1.3   worker-1
default       nginx-85f7d4dd78-rmmrg     1/1     Running     0          90s    10.200.0.3   worker-0
kube-system   coredns-74479d7d97-kfhdl   1/1     Running     0          102s   10.200.0.2   worker-0
kube-system   coredns-74479d7d97-s49m5   1/1     Running     0          102s   10.200.1.2   worker-1
```

**Services.** The `kubernetes` service received the first IP of the service range (`10.32.0.1`), which matches the API server certificate SAN. The smoke test's nginx NodePort service is also listed:

```
$ kubectl get svc
NAME         TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)        AGE
kubernetes   ClusterIP   10.32.0.1    <none>        443/TCP        5m11s
nginx        NodePort    10.32.0.28   <none>        80:31408/TCP   79s
```
