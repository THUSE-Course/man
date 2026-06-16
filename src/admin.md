# 管理

SECoder 既可以指整个包含 Kubernetes 集群在内的平台,
也可以指集群中负责用户管理的前后端.

没有特别说明的话, 部署 SECdoer 的含义是配置并调试集群在内的整个平台.

## 部署 SECoder

### 前置要求

- 拥有校园网 IPv4 或 IPv6 地址, SECoder 至少要使用 `22`, `443` 端口.
  尽管可以在应用层进行负载均衡, 但更推荐的做法是进行端口绑定或裸机监听,
  在这样的配置下 SECoder 才能够路由用户的部署业务并且对
  GitLab SSH 协议的 TCP 流量进行转发.
- NFS 存储
- SECoder 域名的 DNS 编辑权限. Kubernetes 集群的 cert-manager
  可以方便地自动更新证书并且保证服务不中断
- 至少两台虚拟机

### Kubernetes 集群

新版本 SECoder 的开发在 2026 年初完成, 使用 Debian 13 以及当时的最新 Kubernetes
版本 1.36, 但一般来说, 版本并不重要, 可以更新.

经过实验, 纯 IPv6 的集群也可以正常工作, 只需要提供合适的 DNS64 与 NAT64.

管理员应当首先准备 NFS 文件系统, 以便满足集群后续的存储需求.
其次准备 Debian 13 操作系统并安装
[`kubeadm`](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/).

`kubeadm` 可以通过配置文件首先启动一个控制面, 考虑课程的需要,
部署单个控制面节点 (分配 4c4g) 即可.
在这之外, 部署至少一个工作节点. 以下说明以 IPv4 单栈集群为准.

所有节点需要启用 Kubernetes 所需的内核转发参数:

```sh
cat >/etc/sysctl.d/k8s-net.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl --system
```

如果系统启用了 swap, 还需要关闭 swap 并从 `/etc/fstab` 中删除对应挂载.
确认 `containerd` 与 `kubelet` 已经安装并启动后, 在控制面节点准备
`kubeadm.conf`. 其中 `advertiseAddress` 与 `controlPlaneEndpoint`
应当填写控制面节点的固定内网地址; `podSubnet` 与 `serviceSubnet`
必须互不重叠, 并且不能与节点所在网段冲突.

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.128.1.111
  bindPort: 6443
skipPhases:
  - addon/kube-proxy
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
apiServer:
  certSANs:
    - c.@@SECODER_BASE_DOMAIN@@
networking:
  dnsDomain: cluster.local
  podSubnet: 100.64.0.0/17
  serviceSubnet: 100.64.128.0/17
controlPlaneEndpoint: 10.128.1.111:6443
clusterName: secoder
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
maxPods: 1024
```

这里跳过 `addon/kube-proxy`, 是因为 SECoder 默认使用 Cilium 的
kube-proxy replacement. 使用以下命令初始化控制面:

```sh
kubeadm init --config kubeadm.conf
```

初始化成功后, 为管理员配置 kubeconfig. 如果正在使用 root 用户,
可以直接执行:

```sh
export KUBECONFIG=/etc/kubernetes/admin.conf
```

如果使用普通用户, 则复制 kubeconfig:

```sh
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
```

此时控制面组件已经启动, 但网络插件尚未安装, 因而节点显示为
`NotReady`, CoreDNS 显示为 `Pending` 是正常现象. 接下来安装 Cilium.
首先添加 Helm 仓库:

```sh
helm repo add cilium https://helm.cilium.io/
helm repo update
```

随后创建 `cilium.yaml`. `k8sServiceHost` 应当与 kubeadm 配置中的
控制面地址一致, `devices` 应当填写节点承载集群流量的网卡名,
`ipv4NativeRoutingCIDR` 应当与 `podSubnet` 一致.

```yaml
ipam:
  mode: kubernetes
ipv4:
  enabled: true
ipv6:
  enabled: false
operator:
  replicas: 1
k8sServiceHost: "10.128.1.111"
k8sServicePort: 6443
kubeProxyReplacement: true
routingMode: native
autoDirectNodeRoutes: true
devices: "eth0"
ipv4NativeRoutingCIDR: "100.64.0.0/17"
bpf:
  lbExternalClusterIP: true
```

安装 Cilium:

```sh
helm install cilium cilium/cilium \
  --namespace kube-system \
  --values cilium.yaml
```

等待 Cilium 与 CoreDNS 启动完成后, 控制面节点应当变为 `Ready`:

```sh
kubectl get pods -A
kubectl get nodes -o wide
```

最后, 在每个工作节点上执行控制面初始化时输出的加入命令:

```sh
kubeadm join 10.128.1.111:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

如果初始化时输出的 token 已经过期, 可以在控制面节点重新生成:

```sh
kubeadm token create --print-join-command
```

所有工作节点加入后, 再次确认节点状态:

```sh
kubectl get nodes -o wide
kubectl get pods -A
```

所有节点都处于 `Ready` 状态, 且 `kube-system` 命名空间中的 Cilium,
CoreDNS 和控制面组件都正常运行后, Kubernetes 集群的 bootstrap
就完成了.

如果部署 IPv6 单栈集群, kubeadm 配置可参考:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "2001:db8:0:0:2::2"
  bindPort: 6443
skipPhases:
  - addon/kube-proxy
---
apiVersion: kubeadm.k8s.io/v1beta4
clusterName: tunet
kind: ClusterConfiguration
controlPlaneEndpoint: "[2001:db8:0:0:2::2]:6443"
apiServer:
  certSANs:
    - c.@@SECODER_BASE_DOMAIN@@
networking:
  podSubnet: "2001:db8:0:0:3::/96"
  serviceSubnet: "2001:db8:0:0:3:1::/108"
controllerManager:
  extraArgs:
    - name: node-cidr-mask-size-ipv6
      value: "100"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
maxPods: 512
```

IPv6 单栈还需要启用 `net.ipv6.conf.all.forwarding = 1`,
并且仍然需要安装 CNI 后节点才会进入 `Ready` 状态.

### FluxCD

为了保持不同学期之间的一致性, SECoder 采用 GitOps 的方式部署集群配置.
FluxCD 是将配置文件同步为集群资源的有力工具. 管理员需要[下载 `flux`
工具](https://github.com/fluxcd/flux2/releases)以便初始化 FluxCD.

开始前, 确认 Kubernetes 集群已经就绪, 当前 shell 的 kubeconfig
可以访问集群:

```sh
kubectl get nodes
flux check --pre
```

下面的 `flux bootstrap git` 是通用 Git 仓库的模板, 适合自建 Git
服务或者不希望依赖代码托管平台 API 的场景. 如果实际部署使用 GitHub,
GitLab, Gitea 等平台, 应当参考 FluxCD 对应的平台模板, 例如
`flux bootstrap github`, `flux bootstrap gitlab` 或
`flux bootstrap gitea`, 并按照平台要求准备 token, owner,
repository, deploy key 等参数. 这些模板的认证方式不同, 但目标一致:
在 Git 仓库中提交 FluxCD 组件和同步配置, 并让集群持续同步指定目录.

使用通用 Git 模板时, 管理员需要先准备一个保存集群配置的仓库, 例如
`secoder-cluster`, 并准备一把对该仓库有读写权限的 SSH 私钥. 对应公钥
需要提前加入 Git 服务端的仓库权限或者部署密钥中.

随后在控制面节点执行:

```sh
flux bootstrap git \
  --url=ssh://git@<git-host>/path/to/secoder-cluster \
  --branch=master \
  --private-key-file="$HOME/.ssh/id_ed25519" \
  --path=clusters/secoder
```

其中 `--url` 应当使用完整的 SSH URL, `--branch` 填写仓库实际使用的分支,
`--private-key-file` 指向有仓库读写权限的私钥, `--path` 是集群配置在
仓库中的目录. SECoder 默认使用 `clusters/secoder`.

命令完成后, FluxCD 会在仓库中提交组件清单和同步清单, 并在集群中创建
`flux-system` 命名空间, 安装 `source-controller`,
`kustomize-controller`, `helm-controller`, `notification-controller`
等组件. 它还会创建指向 Git 仓库的 `GitRepository` 和负责应用
`clusters/secoder` 的 `Kustomization`.

使用以下命令确认 bootstrap 成功:

```sh
kubectl get pods -n flux-system
flux get sources git -A
flux get kustomizations -A
```

FluxCD 的控制器 Pod 应当全部处于 `Running` 状态, Git source 和
Kustomization 应当处于 `Ready` 状态. 后续修改集群配置时, 将变更提交到
Git 仓库的 `clusters/secoder` 目录即可. 如果需要立即触发同步, 可以执行:

```sh
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system
```

### GitLab

因为 GitLab 的 Helm Chart 所能覆盖的配置有限, 在确认 GitLab 正确启动后,
管理员需要登录 root 用户并配置下列设置:

通过以下命令获取 root 用户的密码:

```sh
kubectl get secrets -n devops \
gitlab-gitlab-initial-root-password \
-o jsonpath="{.data.password}" | base64 -d
```

1. 允许 PAT 过期

   进入 `Admin > Settings > General > Account and limit`,
   - 禁用 `Access token expiration`
   - 禁用 `Allow new users to create top-level groups`

   点击 `Save changes` 保存选择.

1. 允许 PAT 过期

   进入 `Admin > Settings > General > Account and limit`,
   - 禁用 `Access token expiration`

   点击 `Save changes` 保存选择.

1. 禁止注册

   进入 `Admin > Settings > General > Sign-up restrictions`,
   - 禁用 `Sign-up enabled`

   点击 `Save changes` 保存选择.

1. 禁止密码登录

   进入 `Admin > Settings > General > Sign-in restrictions`
   - 启用 `Allow password authentication for the web interface`
     (必须, 否则 root 用户无法登录)
   - 禁用 `Allow password authentication for Git over HTTP(S)`
   - 启用 `Disable password authentication for users with an SSO identity`

   同样注意保存设置

1. 设置仓库

   进入 `Admin > Settings > Repository > Default branch`
   - 设置初始分支为 `master`
   - 允许 `Maintainers` push 到受保护分支
   - 允许 `Developers + Maintainers` merge
   - 启用 `Allow developers to push to the initial commit`

   同样注意保存设置

1. 配置 CI/CD

   进入 `Admin > Settings > CI/CD > Continuous Integration and Deployment`
   - 禁用 `Default to Auto DevOps pipeline for all projects`

   同样注意保存设置

1. 创建 System hook

   进入 `Admin > System hooks`, 配置 URL 为 `http://exporter:8000`. 不需要 Secret token. 这时测试可能看到 502 错误, 这是因为 exporter 还需要使用 Gitlab api token 主动查询.

1. 创建 Access token

   进入 `User settings > Personal access tokens`
   创建名为 `rw` 的 token, 设置 scope 为:
   - `api`

   这里的 token 随后应当提供给 SECoder 的 reconciler. 格式为

   ```yaml
   secretGenerator:
     - name: reconciler
     literals:
       - gitlab-token=<your-token>
   ```

1. 创建顶级分组

   以 root 身份创建 `g2026`, `u2026`, `pub` 顶级组.
   前两个在后续配置中会用到.

1. 为 Grafana 配置 oauth

   [Configure GitLab OAuth authentication | Grafana documentation](https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/gitlab/)

   完成后, 记录下凭据, 填写到集群配置中.

### SECoder 前后端

助教配置后端时, 需准备学期内选课学生的学号与初始密码, 格式为:

```json
[
  {
    "id": "2001",
    "passwd": "Bfwae"
  },
  {
    "id": "2002",
    "passwd": "Afaewab"
  }
]
```

记得一定要首先登录 root 用户, 密码是 `root`. 然后改掉密码.

### SonarQube

同样, 登录 admin 用户, 密码 `admin`.

记得修改 Permission template.
