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

### 部署故障索引

- 节点 `NotReady`、CoreDNS `Pending`: 见“[Kubernetes 集群](#kubernetes-集群)”.
- Flux CRD/CR bootstrap、revision 未推进、Helm retries exhausted、首次 install
  误入 upgrade、Gateway API 大对象、CloudNativePG 或 Garage 初始化失败:
  见“[GitOps 依赖顺序与发布验证](#gitops-依赖顺序与发布验证)”.
- Route 未附着、外层 502、GitLab SSH 不通或两层 TLS 不一致:
  见“[反代](#反代)”.
- registry 拉取停滞或冷启动超时: 见“[镜像拉取与冷启动](#镜像拉取与冷启动)”.
- GitLab SSO、System Hook、固定 Secret、CI ApplySet 或邮件验收失败:
  见“[GitLab](#gitlab)”.
- SECoder root/RBAC/kubeconfig 失效: 见“[SECoder 使用](#secoder-使用)”.
- SonarQube 初始化、权限或 OAuth 失败: 见“[SonarQube](#sonarqube)”.

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

如果节点长期停留在 `NotReady`, 不要直接重复执行 `kubeadm init` 或重新安装所有组件.
先按下面的顺序缩小故障边界:

```sh
kubectl -n kube-system get pods -o wide
kubectl -n kube-system describe daemonset/cilium
kubectl -n kube-system logs daemonset/cilium --all-containers --tail=200
journalctl -u kubelet -u containerd --since=-15min --no-pager
crictl info
```

- Cilium Pod 尚未创建时, 检查 Helm release、节点 taint 和镜像拉取事件.
- Cilium 已运行而 CoreDNS 仍为 `Pending` 时, 检查 Pod CIDR、Service CIDR、
  `k8sServiceHost`、网卡名以及是否确实跳过了 kube-proxy.
- sandbox image 不一致时, 以 `kubeadm config images list` 为准修正 containerd,
  重启 containerd 和 kubelet 后重新检查, 不要重新初始化控制面.
- 日志显示 CRI 或 CNI 错误时, 先证明运行时和 Cilium 的实际故障已经消失,
  再等待节点条件恢复. 一个成功的 Helm 命令不等于数据面已经可用.

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

下面列出的恢复操作都应先确认故障对象、当前 Git revision 和实际工作负载状态.
不要因为上层 Kustomization 显示失败就删除整个 namespace; 很多情况下底层 Pod
已经恢复, 只是控制器仍保留着之前耗尽的失败状态.

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

如果 Garage Pod 为 `Running` 但 readiness 为 false, init Job 又一直等待
StatefulSet Ready, 这是首次 layout 的依赖环, 不是简单的慢启动. 恢复步骤是:

1. 让 init Job 只等待 Pod 进入 `Running` 且 Garage CLI 能返回 node ID;
2. 幂等地分配并 apply layout, 然后再等待 Pod Ready;
3. 继续创建 bucket、key 和派生 Secret;
4. 修改 Job 命令时使用新的版本化 Job 名称, 因为已有 Job 的 Pod template 不可变;
5. 从 live layout、派生 Secret 和 Job 完成日志三处验收, 最后再复位 Garage
   HelmRelease 和拥有它的 Kustomization 的旧失败状态.

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

普通的 reconcile 请求不会清除已经耗尽的 Helm remediation 次数. 当镜像拉取完成、
Pod 和依赖已经健康, 但 HelmRelease 仍报告 retries exhausted 时, 使用同一个新 token
同时请求 reconcile 和 reset:

```sh
token="$(date -Iseconds)"
namespace=NAMESPACE
release=RELEASE
kubectl -n "$namespace" annotate "helmrelease/$release" \
  reconcile.fluxcd.io/requestedAt="$token" \
  reconcile.fluxcd.io/resetAt="$token" --overwrite
kubectl -n "$namespace" get "helmrelease/$release" \
  -o jsonpath='{.status.lastHandledResetAt}{"\n"}'
kubectl -n "$namespace" wait --for=condition=Ready \
  "helmrelease/$release" --timeout=30m
```

只有 `.status.lastHandledResetAt` 已处理新的 token, 且 live workload 同时健康,
才能认为恢复成功. 随后还要显式 reconcile 并等待上层 Kustomization Ready:

```sh
stage=KUSTOMIZATION_NAME
kubectl -n flux-system annotate "kustomization/$stage" \
  reconcile.fluxcd.io/requestedAt="$token" --overwrite
kubectl -n flux-system wait --for=condition=Ready \
  "kustomization/$stage" --timeout=30m
```

如果首次 install 在 pre-install hook 中超时, 后续却持续执行 upgrade 并被
“没有上一版本”一类保护拒绝, 应先等待当前 Helm action 停止, 列出 Helm history、
Chart 管理的资源和独立 PVC/数据库. 确认有状态依赖不归该 HelmRelease 删除后,
只删除 `helmrelease/<release>` 并等待 finalizer 完成清理, 再让 Flux 从 Git
重新创建它. 这是恢复首次 install, 不是删除应用数据的手段.

发布前不仅要检查 HelmRelease values, 还要渲染实际 Chart 资源并断言关键字段.
至少执行:

```sh
kubectl kustomize overlays/<target> >/tmp/rendered.yaml
helm template <release> <repo>/<chart> --version <version> \
  --namespace <namespace> -f /tmp/effective-values.yaml >/tmp/chart.yaml
kubeconform -strict -summary -ignore-missing-schemas /tmp/chart.yaml
kubectl apply --server-side --dry-run=server -f /tmp/rendered.yaml
```

本地 render 与通用 JSON schema 不能覆盖 admission webhook 的全部规则. 例如
CloudNativePG 会拒绝把 operator 管理的 fixed parameter 放在普通
`spec.postgresql.parameters` 中. 遇到这类错误时, 保留 API Server 返回的完整错误,
查看 live CRD 提供的字段并改用专用字段:

```sh
kubectl explain cluster.spec.postgresql --api-version=postgresql.cnpg.io/v1
kubectl explain cluster.spec.postgresql.shared_preload_libraries \
  --api-version=postgresql.cnpg.io/v1
kubectl apply --server-side --dry-run=server -f /tmp/rendered.yaml
```

只有 live webhook 接受 dry-run 后才能提交并触发有状态资源创建.

Gateway API 的 experimental CRD bundle 可能超过 Helm release Secret 的 1 MiB
限制. 如果 `traefik-crds` 一类 release 因 `Secret too large` 失败, 不要删减 CRD
schema 或反复 reset release. 应从 Gateway API 官方 release 获取与 Chart annotation
一致的 bundle, 校验版本、channel、SHA-256 和所需 `TCPRoute` API, 将 bundle 作为
独立清单逐对象 server-side apply, 等待所有 CRD `Established`, 再移除失败的
CRD HelmRelease 并恢复依赖它的 Kustomization. Chart 注释不是版本的权威证据,
应以清单 annotation 和官方发布物比对为准.

Chart 大版本会移动 values 路径而不一定报错. 例如 Traefik Chart 41 的
Kubernetes Service 原生字段位于 `service.spec`; external IP 应写成:

```yaml
service:
  spec:
    externalIPs:
      - 10.128.1.111
```

因此还应解析 `/tmp/chart.yaml`, 确认最终 `Service.spec.externalIPs` 等关键字段
确实存在, 而不是仅确认 HelmRelease 保存了输入值. 如果 HelmRelease Ready 但 live
Service 缺少该字段, 应修正权威 values、重新 render 和 server-side dry-run, 再通过
Flux 发布并读回 Service; 不要只 patch live Service, 否则下次 reconcile 会覆盖修复.

首次创建新的 GitOps 仓库时, 可以使用与托管平台匹配的
`flux bootstrap gitlab`、`flux bootstrap github` 或 `flux bootstrap gitea`
生成组件和 sync 清单. 生成后先审查并签名提交. 已经准备好的 SECoder GitOps
仓库则不应再次运行会写仓库的 bootstrap 命令;
新集群只需要安装已提交的组件, 并使用只读 deploy key 创建 source Secret.
管理员的 Git 写凭据与集群内只读凭据必须分开保存和轮换.

如果 Flux controller 的出站配置依赖同一个 GitOps 仓库中的网络前置工作负载,
直接先安装 Flux 会形成“Flux 必须先拉到仓库才能创建自己的网络依赖”的启动环.
此时应在安装 Flux 前, 从已审核的本地 revision 手工应用该前置工作负载, 等待
Deployment Available, 验证其实际 listener, 再用一次真实的依赖源请求证明路径可用.
没有这类依赖的部署跳过该步骤. 这里的前置网络能力必须是平台配置的一部分,
不得引入未纳入平台配置和恢复演练的临时外部依赖.

对已准备好的仓库, bootstrap 顺序应明确分成两个 API discovery 周期:

```sh
kubectl create namespace flux-system
kubectl apply -f /secure/path/flux-read-secret.yaml
# 如有仓库内网络前置依赖, 在这里应用并完成 listener/依赖请求验收.
kubectl apply -f clusters/secoder/flux-system/gotk-components.yaml
kubectl wait --for=condition=Established \
  crd/gitrepositories.source.toolkit.fluxcd.io \
  crd/kustomizations.kustomize.toolkit.fluxcd.io --timeout=5m
kubectl apply -f clusters/secoder/flux-system/gotk-sync.yaml
```

如果把 CRD、controller 和 `GitRepository`/`Kustomization` CR 放在同一次
`kubectl apply` 中, 客户端可能因为 REST mapping 尚未刷新而拒绝后两种 CR.
这不表示 CRD 安装失败; 等 CRD `Established` 后单独重试 sync 清单即可.

验收不能只等待一个可能早已为 true 的 `Ready` 条件. 应等待这次发布对应的精确
artifact 和 applied revision:

```sh
revision='master@sha1:SIGNED_COMMIT_SHA'
kubectl -n flux-system wait \
  --for=jsonpath='{.status.artifact.revision}'="$revision" \
  gitrepository/flux-system --timeout=10m
kubectl -n flux-system wait \
  --for=jsonpath='{.status.lastAppliedRevision}'="$revision" \
  kustomization/flux-system --timeout=20m
flux get sources git -A
flux get kustomizations -A
flux get helmreleases -A
```

若 source Ready 但子 Kustomization 停滞, 依次查看它的 `dependsOn`、health check、
事件和 controller 日志. 只有精确 revision 已应用、所有依赖层 Ready、所有
HelmRelease Ready, 且不存在异常 Pod 时, bootstrap 才完成.

### 反代

反代通过 Traefik 的 LoadBalancer/External IP 暴露. 如果外层再部署 Nginx 并在
Nginx 终止 TLS, 需要单独维护外层证书、到 Traefik 的 upstream, 以及足够大的
`client_max_body_size`. 收到外层 502 报告后, 先从同一公网路径复测并记录当前响应;
不要基于已经恢复的旧故障直接修改入口. 若仍失败, 应同时检查:

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

### 镜像拉取与冷启动

部署前应逐一验证 Kubernetes、Cilium、Flux controller、Helm Chart 和业务镜像所用
registry 的实际可达性, 并预拉取 Cilium、pause、Flux controller 及其他启动链关键
镜像. registry 首页返回 401 可能只是正常的认证 challenge; 应结合 containerd 事件、
active transfer 和目标镜像是否最终出现来判断, 不能把一次 HTTP 状态码当成拉取成功.

containerd 的启动路径不能只依赖由同一个 containerd 启动的集群内网络工作负载,
否则会形成 runtime -> CNI/Service -> 网络 Pod -> runtime 的冷启动环. 如果采用镜像
中转站或内部 registry, 应保证它独立于待恢复集群, 记录原始与中转 digest, 并继续在
GitOps 中固定不可变 digest.

镜像大且节点缓存为空时, 先观察拉取是否持续推进. Helm 五分钟超时但 active transfer
仍增长通常是 action timeout, 不是 Chart 不兼容. 等待镜像完成后, 按上文的
`requestedAt`/`resetAt` 路径恢复; 如果拉取没有进展, 再检查 registry 认证、DNS、
节点磁盘、containerd 日志和 Pod event. 不要在镜像仍正常下载时删除 release 或 PVC.

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

#### 出站邮件验收与恢复

出站 SMTP 不能只靠 HelmRelease Ready 验收. 应按 source、live Secret、Rails runtime、
SMTP provider 和最终邮箱五层核对, 全程只比较选定的非敏感字段与凭据 SHA-256,
不得打印密码:

```sh
kubectl -n prod get helmrelease/gitlab
kubectl -n prod get deployments,pods -o name | grep -i mailroom || true
kubectl -n prod exec deployment/gitlab-toolbox -c toolbox -- \
  gitlab-rails runner 'require "json"; require "digest"; s=ActionMailer::Base.smtp_settings; puts({delivery_method: ActionMailer::Base.delivery_method, address: s[:address], port: s[:port], authentication: s[:authentication], starttls_auto: s[:enable_starttls_auto], verify_mode: s[:openssl_verify_mode], from: Gitlab.config.gitlab.email_from, reply_to: Gitlab.config.gitlab.email_reply_to, password_sha256: Digest::SHA256.hexdigest(s[:password].to_s)}.to_json)'
kubectl -n prod exec deployment/gitlab-toolbox -c toolbox -- \
  gitlab-rails runner 'Notify.test_email("operator@example.edu", "GitLab SMTP test", "delivery validation").deliver_now'
```

恢复时先定位不一致层级:

1. source 与 live Secret 哈希不同: 修正权威 GitOps source 并等待 Secret reconciliation;
2. live Secret 与 Rails runtime 哈希不同: 等待 Helm reconciliation, 并滚动重启实际读取
   该 Secret 的 GitLab workload;
3. runtime 一致但同步发送失败: 根据错误检查 DNS、端口、STARTTLS、证书校验、发件人
   allowlist 和 provider credential, 不要改为明文或关闭证书校验来掩盖问题;
4. SMTP transaction accepted 但未收到: 检查退信、垃圾邮件和 provider delivery log;
5. 最终必须由收件人确认主题、发件人和正文. 同时再次证明 incoming email 为 false,
   且集群中没有 Mailroom workload.

1. 抄写 root 用户的 email

   把 GitLab root 用户的 email 抄写下来, 然后将其设置为 SECoder 的 root 用户的
   email. 目的是让 SECoder 的 root 用户同样登录 gitlab 的 root 用户.

   **做完这一步之后必须用 SECoder 的 root 登录一次 GitLab, 不然禁止 GitLab 密码登录后就无法再登录 GitLab 了**.

   如果在 email 对齐前试登录并自动创建了重复用户, 恢复顺序必须是: 登录重复
   用户并解除 JWT identity, 将 GitLab root 的主 email 写入 SECoder root, 再把
   JWT identity 链接到 GitLab root, 最后删除重复用户. 完成后仍须用全新浏览器
   会话重新证明 SECoder SSO 落到 GitLab 管理员 root, 才能禁用密码登录.

   如果真实 SSO redirect 返回 JWT signature verification failed, 立即停止密码登录
   禁用操作. 分别对 SECoder 当前签名材料和 GitLab verifier 配置做不泄露内容的
   fingerprint/hash 比较, 从权威 GitOps source 修正不一致的一侧, 等待配置生效并
   重启读取固定 Secret/ConfigMap 的 workload. 之后使用全新浏览器会话重新执行完整
   redirect, 必须落到预期管理员账号. 仅看到 provider 按钮或 email 相同都不算通过.

1. 允许创建不过期的 PAT

   进入 `Admin > Settings > General > Account and limit`,
   - 禁用 `Access token expiration`
   - 禁用 `Allow new users to create top-level groups`

   点击 `Save changes` 保存选择.

   GitLab 19 的设置页会把折叠 accordion 中的控件保留在页面树中. 保存前先展开对应
   section, 保存后 hard reload 并逐项读回; 自动化工具报告点击成功并不能证明设置值
   已经改变.

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

#### CI 发布与 ApplySet 恢复

平台服务使用管理员 namespace 发布; 普通用户 namespace 的 HTTPRoute hostname
必须以 namespace 开头. admission 因 hostname/namespace 不匹配而拒绝 Route 时,
不能只修改变量后重试, 因为 `kubectl apply --applyset` 不是原子的: 排在 Route 前面的
Deployment、Service 和 ApplySet parent Secret 可能已经创建.

恢复时先从 job trace 取得 applyset 名称和失败对象, 再在原 namespace 中盘点带有该
ApplySet 标识的资源. 只删除本次失败创建的命名对象和 parent Secret, 确认没有旧版本
业务资源被误包含后, 修正 namespace/hostname 并重试原发布任务. 最终验收必须同时满足:

```sh
namespace=NAMESPACE
name=APPLICATION_NAME
kubectl -n "$namespace" get secret \
  -l applyset.kubernetes.io/id -o name
kubectl -n "$namespace" get deployment,service,httproute,secret \
  -l applyset.kubernetes.io/part-of -o name
kubectl -n "$namespace" get "deployment/$name" "service/$name"
kubectl -n "$namespace" get "httproute/$name" -o yaml
kubectl -n "$namespace" get pods -l "app.kubernetes.io/name=$name" -o wide
```

不要对 `applyset.kubernetes.io/part-of` 的全部结果直接执行批量删除; 先把 label 值、
parent Secret 和 job 中的 applyset 名称对应起来, 再逐个删除确认属于失败发布的对象.

- Deployment 使用目标 commit 对应的不可变镜像且 Ready;
- HTTPRoute 的 parent 同时为 `Accepted=True` 和 `ResolvedRefs=True`;
- 公网 HTTPS 返回预期内容;
- 失败 namespace 中不再残留同一发布的 workload 或 ApplySet parent.

BuildKit 成功 push 镜像不证明目标 Pod 有 pull 权限. 私有项目应配置最小权限的
Registry credential 和 `imagePullSecret`, 并从 Pod event 验证认证结果. 把项目改为
Public 是独立的安全决策, 只能在源码和镜像本来就允许公开且得到明确批准时采用.

GitLab CI/CD 变量需要隐藏时, 创建阶段使用当前 API 支持的
`masked_and_hidden=true`; `masked=true` 只保证 job log 脱敏, `hidden=true` 在部分
版本中不会得到相同的 API metadata. 创建后只读回 key、protected、masked、hidden
等 metadata, 不读取 value.

### SECoder 使用

空数据库第一次启动时会创建 SECoder root 用户, 初始密码是 `root`.
平台对外开放前必须立即登录并修改密码, 然后确认初始密码已经返回 401.
如果保留或恢复了原来的 PVC, 则现有密码不会被 bootstrap 覆盖; 不要删除数据库来
“重置”密码.

如果 SECoder core、exporter 或 reconciler 在首次启动时因 PostgreSQL 尚未就绪而
重启, 先检查数据库 Cluster/Pod、PVC、Service endpoint 和应用 Secret 引用. 数据库
恢复 Ready 后再次观察应用; 能自行恢复的 workload 不需要重建. 只有环境变量来自
固定名称 Secret 且已发生变更时才滚动重启对应 Deployment/StatefulSet. 不要通过删除
SECoder 数据库或轮换无关凭据来处理依赖启动顺序问题.

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

#### 以管理员身份导入小组名单

root 无需冒充学生来接受邀请. 在 SECoder 的 **管理员** 页面打开
**小组名单导入**, 上传 UTF-8 编码的 CSV 并先检查系统生成的变更预览. 文件必须使用
以下精确表头; `Member` 列可以按顺序继续增加:

```csv
CodeName,DisplayName,Leader,Member1,Member2,Member3
team-a,第一组,20260001,20260002,20260003
team-b,第二组,20260004,20260005,
,,,20260006,
```

- `CodeName` 是不可变且唯一的小组标识符, 必须符合页面所述的 RFC 1035 格式.
- `DisplayName` 是可修改的显示名称. CSV 中不存在的 `CodeName` 会创建为新小组;
  已存在的小组会按 CSV 更新显示名称和组长.
- `Leader` 会成为该小组组长, 并自动计入成员, 不要再次写入 `Member` 列.
- `CodeName`、`DisplayName` 和 `Leader` 同时为空的行表示未分组学生, 最多只能有一行.
- 每个现有小组都必须出现. 每个已注册、未封禁、非 sudo 学生也必须且只能出现一次;
  缺失、重复、未知或被封禁的账号都会使整份文件验证失败.
- 被封禁账号及其现有小组关系不会被名单导入修改.

验证成功后, 页面会列出新建或重命名的小组、组长转移和学生分组变化. 只有 root
再次确认后才会在一个数据库事务中应用全部变更; 任一验证错误都不会造成部分导入.
数据库提交后会同步 Kubernetes 小组 namespace 的 tenant label. 如果该同步失败,
页面会明确列出受影响的小组; 重新预览并应用同一文件即可重试标签同步.

名单导入不会自动修改 GitLab 子组成员. 学生仍按个人页面现有的
**同步 GitLab 子组** 流程触发 GitLab 同步.

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

#### SonarQube 故障恢复

- 新密码被拒绝时, 按当前页面列出的复杂度逐项满足要求; 不要假设长度足够, 也不要
  为绕过校验而保留默认 admin 密码.
- Pod Ready 但重启后项目或分析历史消失时, 立即停止新的初始化操作, 核对 PVC、挂载
  目录和 H2 文件是否来自预期持久卷. 不要创建新 PVC 来掩盖旧数据未挂载.
- GitLab OAuth redirect 失败时, 先保留 SonarQube 本地 admin 登录, 对照 callback URL、
  Application ID/Secret、GitLab base URL 与实际 Route; Secret 修正后重启读取它的
  SonarQube workload, 再用全新浏览器会话验收.
- GitLab DevOps integration 不是 OAuth 登录配置. `Configuration valid` 失败时,
  单独检查 API URL 是否以 `/api/v4` 结尾、PAT 是否具有 `api` scope、TLS/DNS
  可达性和 token 是否有效. OAuth 能登录不代表项目导入 API 已配置成功.
- `Allowed groups` 留空会扩大到所有可通过 GitLab 鉴权的用户. 如果当前版本出现高风险
  确认, 必须先确认这是课程的既定访问边界; 未获确认时应配置明确 group allowlist,
  不能为了让 OAuth 测试通过而无条件放开.
