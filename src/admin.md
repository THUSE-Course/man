# 管理

SECoder 既可以指整个包含 Kubernetes 集群在内的平台,
也可以指集群中负责用户管理的前后端.

没有特别说明的话, 部署 SECoder 的含义是配置并调试集群在内的整个平台.

## 部署 SECoder

### 前置要求

- 拥有校园网 IPv4 或 IPv6 地址, SECoder 至少要使用 `22`, `443` 端口.
  尽管可以在应用层进行负载均衡, 但更推荐的做法是进行端口绑定或裸机监听,
  在这样的配置下 SECoder 才能够路由用户的部署业务并且对
  GitLab SSH 协议的 TCP 流量进行转发.
- NFS 存储
- SECoder 域名的 DNS 编辑权限, 以及内外两层 TLS 证书的签发和续期能力.
  只有实际部署并配置了 cert-manager 时, 才能认为集群内证书会自动续期.
- 推荐至少两台虚拟机 (控制面和工作节点分离). 单节点部署也可运行,
  但控制面、入口和所有有状态依赖会同时失效, 不属于高可用部署.

### Kubernetes 集群

新版本 SECoder 的开发在 2026 年初完成, 使用 Debian 13 和 Kubernetes 1.36.
部署时应固定 Kubernetes minor 版本的软件源, 同时安装匹配版本的 `kubeadm`,
`kubelet` 和 `kubectl`; 不要在未检查 CNI、CRI、Gateway API 和 Helm Chart
兼容性的情况下跨 minor 更新.

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
确认 `containerd` 与 `kubelet` 已经安装后, 配置 containerd 使用 systemd cgroup,
并使 sandbox image 与当前 kubeadm 完全一致:

```sh
kubeadm config images list --kubernetes-version v1.36.4
containerd config dump | grep -E 'sandbox_image|SystemdCgroup'
crictl info
```

例如 kubeadm 输出 `registry.k8s.io/pause:3.10.2` 时,
`/etc/containerd/config.toml` 中也应配置同一个 `sandbox_image`, 随后重启并验证:

```sh
systemctl restart containerd
systemctl is-active containerd
crictl info | grep sandboxImage
```

Debian 13 当前提供的 containerd 1.7 可以运行 Kubernetes 1.36, 但没有实现 CRI
`RuntimeConfig` RPC. 在更新到 Kubernetes 1.37 或更高版本之前, 必须先执行
`crictl runtime-config` 并确认不再返回 `Unimplemented`; 否则先升级容器运行时.

确认运行时与 `kubelet` 已经启动后, 在控制面节点准备 `kubeadm.conf`.
其中 `advertiseAddress` 与 `controlPlaneEndpoint`
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
controllerManager:
  extraArgs:
    - name: "node-cidr-mask-size"
      value: "20"
    - name: "allocate-node-cidrs"
      value: "true"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
maxPods: 1024
```

`maxPods` 是 kubelet 对单节点 Pod 数量的上限, 不是按 CPU 或内存推导出的容量.
在这里的 `/20` 单节点 Pod CIDR 下有足够的地址容纳 1024 个 Pod, 因而单个工作节点
在配置层面最多承载 1024 个 Pod; 实际可承载数量还要受内存、CPU、PID、端口、
镜像磁盘和 CNI 状态容量限制. 多节点部署时, 必须同时核对
`node-cidr-mask-size`、每节点地址数与 `maxPods`.

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
autoDirectNodeRoutes: true
bpf:
  lbExternalClusterIP: true
devices: eth0
ipam:
  mode: kubernetes
ipv4:
  enabled: true
ipv4NativeRoutingCIDR: 100.64.0.0/17 # 要包含 Pod network CIDR
ipv6:
  enabled: false
k8sServiceHost: 10.128.1.111 # 填写 API Server 的 IP
k8sServicePort: 6443
kubeProxyReplacement: true
operator:
  replicas: 1
routingMode: native
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

控制节点默认是不调度工作负载的. 只有接受单节点非高可用风险时,
才让控制节点运行工作负载:

```sh
kubectl taint node <control-plane-node> node-role.kubernetes.io/control-plane:NoSchedule-
```

注意, 每个节点加入后, 使用 `kubectl describe <nodename>`
来查看集群给该节点分配了哪个 Pod Network CIDR. 随后在每个节点上配置对应路由,
例如在节点 `.10` 上:

```
[Match]
Name=eth0

[Network]
Address=172.30.20.10/24
Gateway=172.30.20.1
DNS=172.30.20.1

[Route]
Destination=100.64.32.0/20
Gateway=172.30.20.12
# 100.64.32.0/20 这个 Pod Network CIDR 在 172.30.20.12 机器上

[Route]
Destination=100.64.16.0/20
Gateway=172.30.20.11
```

在节点 `.11` 上:

```
[Match]
Name=eth0

[Network]
Address=172.30.20.11/24
Gateway=172.30.20.1

[Route]
Destination=100.64.32.0/20
Gateway=172.30.20.12

[Route]
Destination=100.64.0.0/20
Gateway=172.30.20.10
```

虽然 cilium 理论上能通过二层发现自动学到这个路由. 但如果未来要配置三层可达的路由, 就可以这么办.

### IPv6

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

为了部署该实例版本, 记得查看 FluxCD 仓库下的 `overlays` 文件夹, 特别理解
`overlays/secoder-infra*/`, `overlays/secoder-mon*/`. 管理员应当至少查看
`overlays` 下的所有文件, 以了解自己部署的是什么东西.

例如, 查看 `overlays/secoder-infra-pre/csi-driver-nfs/values.yaml`, 可以看到:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: csi-driver-nfs
spec:
  values:
    storageClasses:
      - name: nfs-retain
        parameters:
          server: "10.128.1.111"
          share: /retain
          mountPermissions: "0777"
        reclaimPolicy: Retain
        volumeBindingMode: Immediate
        mountOptions:
          - nfsvers=4.2
          - noatime
      - name: nfs-tmp
        parameters:
          server: "10.128.1.111"
          share: /tmp
          mountPermissions: "0777"
        reclaimPolicy: Delete
        volumeBindingMode: Immediate
        mountOptions:
          - nfsvers=4.2
          - noatime
```

`nfs-retain` 用于需要保留的数据, 因而 PV 的 reclaim policy 必须是 `Retain`;
`nfs-tmp` 用于可重建数据, reclaim policy 才是 `Delete`. 部署后要检查实际 PV,
不能只检查 StorageClass 名字:

```sh
kubectl get storageclass
kubectl get pv -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName,RECLAIM:.spec.persistentVolumeReclaimPolicy,PHASE:.status.phase
```

在部署时, 一定注意准备需要的 NFS server, 否则会遇到 PVC 无法绑定成功并不断重试.

推荐采用如下配置的 NFS server (async 是很重要的, 因为 GitLab CI 的任务也在 NFS
上跑, sync 会显著影响在 CI 上的编译的性能):

```
cat /etc/exports

/srv 172.30.20.0/24(rw,fsid=0,async,no_subtree_check,sec=sys,no_root_squash)
```

这里的 `/srv` 只是示例. 操作现有环境, 特别是清理或恢复数据之前, 必须先读取
`/etc/exports`, 再用 `findmnt`, `exportfs -v` 和 `stat` 确认实际 export root、
子目录和挂载目标; 不得从文档示例推断破坏性操作的路径.

### GitOps 依赖顺序与发布验证

完整部署不是把所有 Kustomization 同时创建即可. 推荐的依赖顺序是:

1. 安装 Gateway API CRD 和 Flux 控制器, 等待 CRD Established;
2. 安装存储、Traefik 等 `infra-pre` 依赖;
3. 安装 `infra`, 并等待 Kyverno 和其他 webhook Ready;
4. 安装 `mon-pre` 与监控组件;
5. 安装 PostgreSQL、Valkey、Garage 等 `prod-pre` 有状态依赖;
6. 最后安装 SECoder、GitLab 和 SonarQube 等 `prod` 工作负载.

如果 GitOps 仓库使用 Flux `dependsOn`, 每一步仍应设置明确的 health check,
不能只依赖对象创建顺序. Gateway API CRD 必须先于引用它们的 Gateway/Route;
Kyverno 必须先于 SECoder 的生成策略. CloudNativePG 若启用
`shared_preload_libraries`, 必须先确认镜像中存在对应扩展, 否则 PostgreSQL 会在
启动阶段反复失败. Garage 第一次启动时, 需要先完成 layout 分配和应用,
再创建 bucket、key 和依赖它们的 Secret; 只等待 Pod Ready 不代表 layout 已可用.

大型 Chart 第一次冷启动会拉取数百 MB 到 1 GB 以上的镜像. GitLab 和 SonarQube
的 HelmRelease 应为 install/upgrade 设置足够的超时 (例如 `60m`) 和明确 remediation:

```yaml
spec:
  timeout: 60m
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
      remediateLastFailure: true
```

如果第一次 install 在正常资源创建前失败, Helm history 可能让后续 reconcile
错误地走 upgrade 路径并触发 Chart 的升级保护. 先修正超时/remediation, 盘点 PVC、
数据库和其他独立资源的所有权, 然后只删除并让 Flux 重建对应 HelmRelease,
以获得真正的 clean install. 不要为此删除 namespace、数据库或独立 PVC.

发布前不仅要检查 HelmRelease values, 还要渲染实际 Chart 资源并断言关键字段.
至少执行:

```sh
kubectl kustomize overlays/<target> >/tmp/rendered.yaml
helm template <release> <repo>/<chart> --version <version> \
  --namespace <namespace> -f /tmp/effective-values.yaml >/tmp/chart.yaml
kubeconform -strict -summary -ignore-missing-schemas /tmp/chart.yaml
kubectl apply --server-side --dry-run=server -f /tmp/rendered.yaml
```

Chart 大版本会移动 values 路径而不一定报错. 例如 Traefik Chart 41 的
Kubernetes Service 原生字段位于 `service.spec`; external IP 应写成:

```yaml
service:
  spec:
    externalIPs:
      - 10.128.1.111
```

因此还应解析 `/tmp/chart.yaml`, 确认最终 `Service.spec.externalIPs` 等关键字段
确实存在, 而不是仅确认 HelmRelease 保存了输入值.

下面的 `flux bootstrap git` 是通用 Git 仓库的模板 (需要 SSH 端口), 适合自建 Git
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
Git 仓库即可. 如果需要立即触发同步, 可以执行:

```sh
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system
```

### 反代

反代通过 Traefik 的 LoadBalancer/External IP 暴露. 如果外层再部署 Nginx 并在
Nginx 终止 TLS, 需要单独维护外层证书、到 Traefik 的 upstream, 以及足够大的
`client_max_body_size`. 外层 HTTPS 返回 502 时, 应同时检查:

```sh
kubectl -n infra get service traefik -o wide
kubectl -n infra get endpointslice -l kubernetes.io/service-name=traefik
kubectl -n infra get gateway traefik-gateway -o yaml
kubectl get httproute,tcproute -A -o wide
```

每条 Route 都应在 `.status.parents[].conditions` 中出现 `Accepted=True` 和
`ResolvedRefs=True`. Traefik Chart 创建的 Gateway 通常名为
`<release>-gateway`; 本部署为 `traefik-gateway`, 不能把 TCPRoute 的 parentRef
写成不存在的 `traefik`. Gateway listener 显示 `attachedRoutes: 0` 而后端
Service/Endpoint 正常时, 优先检查 parent 名称和 `sectionName`.

外层 Nginx 与集群入口是两个独立故障边界. 公网 HTTPS 正常不代表公网
GitLab SSH 正常; 外层主机还必须把 `gitlab.<domain>:22` 的 TCP 流量转发到
Gateway 的 SSH listener. 应分别验证 HTTP、Gateway TCPRoute/Endpoint 和公网 22
端口. 如果没有外层主机的授权访问, 不要用修改集群内 TCPRoute 来掩盖公网
`connection refused`.

外层和集群内 Traefik 也可能使用不同证书. 即使外层 Let's Encrypt 证书有效,
提交在 GitOps 仓库中的 `secoder-tls` 仍可能过期, 影响节点 hosts shortcut 或
直接访问 Traefik 的客户端. 部署和日常监控都要分别检查两层证书的 SAN 与
`notAfter`; 若未部署 cert-manager, 必须建立人工续期和滚动验证流程.

### 出站代理与冷启动

本机或 SSH tunnel 代理只适合 bootstrap, 不应成为永久运行依赖. 如果将 containerd
的 HTTP(S) proxy 指向集群内 Xray ClusterIP, 普通 Pod 或节点重启不会改变 Service IP,
但删除并重建 Service 或整个集群可能重新分配 ClusterIP. 更重要的是, 这会形成
containerd -> Cilium/Service -> Xray Pod -> containerd 的启动环:

- 重建前预拉取 Cilium、Xray、pause 和控制器镜像;
- 保留独立的 bootstrap egress 或镜像中转站;
- 记录 Xray Service IP, 并在 Service 重建后同步更新 containerd drop-in;
- 将 Pod、Service、节点、loopback、NFS 和集群 DNS 网段加入 `NO_PROXY`;
- 修改代理后重启 containerd, 用一个此前未缓存的小镜像验证真实拉取.

若采用镜像中转站, 应记录原始 digest 与中转后的 digest, 并继续在 GitOps 中固定
不可变 digest. Git push 不应经过拉取镜像所使用的 HTTP proxy.

### GitLab

因为 GitLab 的 Helm Chart 所能覆盖的配置有限, 在确认 GitLab 正确启动后,
管理员需要登录 root 用户并配置下列设置:

通过以下命令获取 root 用户的密码:

```sh
kubectl get secret -n prod gitlab-gitlab-initial-root-password \
  -o jsonpath="{.data.password}" | base64 -d
```

命名空间和 Secret 名称以当前 Helm release 为准. 使用外部 CloudNativePG、Valkey
和 Garage 时, 必须先验证数据库 migration、Gitaly、Sidekiq、Webservice、Registry、
Runner 注册和 Toolbox, 不能用单个 Web 页面 200 代替完整 install 验收.

课程当前不使用 GitLab incoming email. Helm values 应显式禁用 incoming email 和
Mailroom, 同时可以保留 outbound SMTP. 验收时确认没有 Mailroom Deployment/Pod;
不要因为看到 outbound email 配置而启用收件链路.

1. 抄写 root 用户的 email

   把 GitLab root 用户的 email 抄写下来, 然后将其设置为 SECoder 的 root 用户的
   email. 目的是让 SECoder 的 root 用户同样登录 gitlab 的 root 用户.

   **做完这一步之后必须用 SECoder 的 root 登录一次 GitLab, 不然禁止 GitLab 密码登录后就无法再登录 GitLab 了**.

   如果在 email 对齐前试登录并自动创建了重复用户, 恢复顺序必须是: 登录重复
   用户并解除 JWT identity, 将 GitLab root 的主 email 写入 SECoder root, 再把
   JWT identity 链接到 GitLab root, 最后删除重复用户. 完成后仍须用全新浏览器
   会话重新证明 SECoder SSO 落到 GitLab 管理员 root, 才能禁用密码登录.

1. 允许创建不过期的 PAT

   进入 `Admin > Settings > General > Account and limit`,
   - 禁用 `Access token expiration`
   - 禁用 `Allow new users to create top-level groups`

   点击 `Save changes` 保存选择.

1. 禁止注册

   进入 `Admin > Settings > General > Sign-up restrictions`,
   - 禁用 `Sign-up enabled`

   点击 `Save changes` 保存选择.

1. 禁止密码登录

   进入 `Admin > Settings > General > Sign-in restrictions`
   - 禁用 `Allow password authentication for the web interface`
   - 禁用 `Allow password authentication for Git over HTTP(S)`
   - 启用 `Disable password authentication for users with an SSO identity`

   在执行这一步之前, 必须先把 GitLab root email 设置为 SECoder root email,
   并用 SECoder root 完成一次真实 SSO 登录. 在独立浏览器会话验证 SSO 成功之前,
   不得禁用密码登录, 否则可能锁死管理员入口. 同样注意保存设置.

1. 设置仓库

   进入 `Admin > Settings > Repository > Default branch`
   - 设置初始分支为 `master`
   - 允许 `Maintainers` push 到受保护分支
   - 允许 `Developers + Maintainers` merge
   - 启用 `Allow developers to push to the initial commit`

   同样注意保存设置

1. 设置项目默认可见性

   进入 `Admin > Settings > General > Visibility and access controls`
   - 设置 `Default project visibility` 为 `Private`

   同样注意保存设置

1. 配置 CI/CD

   进入 `Admin > Settings > CI/CD > Continuous Integration and Deployment`
   - 禁用 `Default to Auto DevOps pipeline for all projects`

   同样注意保存设置

1. 创建 System hook

   进入 `Admin > System hooks`, 配置 URL 为 `http://exporter:8000`.
   是否配置 Secret token 必须与 exporter 的 `GITLAB_WEBHOOK_SECRET` 一致.
   先配置可用的 GitLab API token 并确认 exporter Ready, 再测试 hook;
   不要把 502 当作正常状态. 重建后的 GitLab 内置测试可能继续引用不存在的示例
   project/commit, 因而即使鉴权已修复也会返回 404; 最终验收必须创建真实项目并
   push 一次, 确认 exporter 成功处理该 Push event.

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

   如果 Secret 使用固定名称并通过环境变量注入, 更新 Secret 不会自动重启
   reconciler/exporter. 应显式 rollout restart 这些消费者, 或把 Secret checksum
   放入 Pod template annotation 以触发滚动更新. Grafana OAuth Secret 同理.

1. 创建顶级分组

   以 root 身份创建 `g2026`, `u2026`, `pub` 顶级组.
   前两个在后续配置中会用到.

1. 为 Grafana 配置 oauth

   [Configure GitLab OAuth authentication | Grafana documentation](https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/gitlab/)

   GitLab application 的 callback URL 是
   `https://grafana.@@SECODER_BASE_DOMAIN@@/login/gitlab`. 完成后, 记录下凭据,
   填写到集群配置中; Secret 生效并重启 Grafana 后, 用全新浏览器会话验证一次
   GitLab OAuth 登录.

### SECoder 使用

空数据库第一次启动时会创建 SECoder root 用户, 初始密码是 `root`.
平台对外开放前必须立即登录并修改密码, 然后确认初始密码已经返回 401.
如果保留或恢复了原来的 PVC, 则现有密码不会被 bootstrap 覆盖; 不要删除数据库来
“重置”密码.

集群重建后, 旧的用户 kubeconfig 即使尚未到期也不能继续使用, 因为 token 的
签名密钥和绑定对象属于旧集群. 以 root 登录 SECoder 后, 从个人页面重新获取 RBAC
token/kubeconfig, 并通过公网 Kubernetes API 验证:

```sh
chmod 600 u-root.kubeconfig
kubectl --kubeconfig ./u-root.kubeconfig get namespace u-root
kubectl --kubeconfig ./u-root.kubeconfig auth can-i '*' '*' --all-namespaces
kubectl --kubeconfig ./u-root.kubeconfig get nodes
```

`u-root` 应带有正确的 SECoder tenant label, root 的绑定应指向预期的
cluster-admin role. 普通用户还要验证只能访问自己的 namespace 和所在小组 namespace.

助教配置后端时, 需准备学期内选课学生的学号与初始密码, 格式为纯文本每行一个
(注意用 Unicode 编码):

```
197011201:123456
19701121:123456
```

这些添加过的学号允许注册, 其他未添加的不可以注册 SECoder. 允许多次添加.

### SonarQube

同样, 登录 admin 用户, 密码 `admin`. 第一次登录后会要求改密码.
新密码不仅有长度要求, 还必须同时满足 SonarQube 当前版本显示的大小写字母、数字、
特殊字符等复杂度规则; 纯十六进制随机串可能被拒绝.

如果 Community Edition 使用持久化内嵌 H2, 这只是单实例、非高可用方案.
必须持久化 SonarQube 数据目录并记录备份/恢复边界; 生产规模增长后应迁移到
受支持的外部数据库. Pod Ready 不能替代重启后的项目、分析历史和权限验证.

打开 `https://sonar.@@SECODER_BASE_DOMAIN@@/admin/settings`, 设置 `sonar.core.serverBaseURL` 为 `https://sonar.@@SECODER_BASE_DOMAIN@@`.

打开 `https://sonar.@@SECODER_BASE_DOMAIN@@/admin/projects_management`,

修改 Default visibility of new projects 为 Private.

打开 `https://sonar.@@SECODER_BASE_DOMAIN@@/admin/permission_templates`,

修改 Default Permission Template, 将它改成如下的设置:

| Group | Browse | See Source Code | Administer Issues | Administer Security Hotspots | Administer Architecture | Administer | Execute Analysis |
| --- | --- | --- | --- | --- | --- | --- | --- |
| sonar-administrators | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| sonar-users | Yes | No | No | No | No | No | No |
| Creators | Yes | Yes | Yes | Yes | Yes | Yes | Yes |

然后为 GitLab 配置登录:

打开
`https://sonar.@@SECODER_BASE_DOMAIN@@/admin/settings?category=authentication&tab=gitlab`,
参照 SonarQube 线上文档配置 GitLab 作为鉴权提供者. GitLab 那里依次填写
`https://sonar.@@SECODER_BASE_DOMAIN@@/oauth2/callback/gitlab` (redirect URL),
`Confidential`, `api`. 然后在 SonarQube 那里配置 Application ID,
GitLab URL 为 `https://gitlab.@@SECODER_BASE_DOMAIN@@`, 启用
`Synchronize user groups`. 填完这些后, 记得启用 `Allow users to sign up`,
`Allowed groups` 留空. 这表示任何能够通过该 GitLab 鉴权的用户都可进入
SonarQube, 当前版本会显示高风险确认对话框; 只有明确接受该暴露边界时才确认,
并在保存后执行一次全新会话 GitLab OAuth 登录.

接下来打开
`https://sonar.@@SECODER_BASE_DOMAIN@@/admin/settings?category=almintegration&alm=gitlab`,
允许登录到 SonarQube 的用户从 GitLab 中导入项目. GitLab API URL 填写
`https://gitlab.@@SECODER_BASE_DOMAIN@@/api/v4`, token 使用具有 `api` 权限的
Personal Access Token (可以复用之前的). 保存后必须看到 `Configuration valid`,
届时使用 SECoder 的学生将独立导入他们的项目.
