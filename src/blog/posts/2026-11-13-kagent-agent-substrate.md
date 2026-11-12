---
title: Sandbox your agents with kagent 1.x and agent-substrate
description:
---

I run my homelab on Talos Kubernetes with Proxmox underneath, provisioned with OpenTofu and managed entirely through Argo CD and git.
I've used AI to guide me trough the homelab journey on topics I'm less familiar with (networking lol).
As the homelab has grown, so has the churn and time consuming manual processes I never bother to optimize.
So what if I made an agent with access to everything it needs? Could it help me?

Probably. But I don't trust LLMs, and I don't want to configure them without IaC or GitOps.
Thats why I've experimented with [kagent](kagent.dev), a framework for running and defining agents in Kubernetes.
They just released version 1, which bundles [agent-substrate](ate.dev).

I spent two nights following their very detailed but not-very-IaC-y install guide at the day of release,
so you don't have to! Heres how to do it yourself.

## The idea

**kagent** is where you define your agents and how you interact with them.
They have several CRs (`Agent`, `AgentTemplate`, `ModelConfig`, `RemoteMCPServer`, `Harness`).
You can configure different models and MCP servers, and how the agent can use them.

**agent-substrate** is the runtime underneath. The very smart people at Google and Solo.io figured that always-running pods are not a very efficient pattern if you run millions of agents.
So they diverged from the standard pod concept (gasp!). Instead, agent-substrate puts your agent in a "worker pool" that is sandboxed by gVisor,
issues it a SPIFFE identity, routes all its egress through an egress gateway, and suspends it by snapshotting to S3 when it's not actively being used.
Pretty cool!

## Prerequisites

- Kubernetes **1.37 or later**. Agent Substrate depends on `PodCertificateRequest` and `ClusterTrustBundle`.
- **Talos** is what makes node setup clean: nodes are immutable, so customization happens as declarative machine-config patches applied at bootstrap, not as runtime `sysctl -w` calls that vanish on reboot.
- Argo CD, Cilium, CloudNativePG, sealed-secrets, Longhorn — the usual GitOps stack.

## 1. Figure out what node you sacrifice

Agents don't run as normal pods, but the substrate's `atelet` DaemonSet and the worker pool need somewhere to be placed, and they have requirements.
Your node must support user namespaces, and increasing the neighbor table helps for networking. In Talos, this is a simple patch.

For my case, I figured a dedicated node fits well, but its not a hard requirement.
I label and taint one node with a Talos patch applied per-node by OpenTofu — `tofu/core/talos.tf` includes `manifests/agent-patches.yaml` when `agent.enabled` is set on the node. The patch ([permalink](https://github.com/bakseter/homelab/blob/74d6a98ad3a47859ebeff401e3174786bcfc9199/tofu/core/manifests/agent-patches.yaml)):

```yaml
apiVersion: v1alpha1
kind: KubeNodeConfig
labels:
  node-role.bakseter.net/agent: 'true'
taints:
  node-role.bakseter.net/agent: 'true:NoSchedule'
---
apiVersion: v1alpha1
kind: SysctlConfig
params:
  # Needed for gVisor
  user.max_user_namespaces: '11255'
  # Each sandbox gets its own network namespace. Proxy ARP/NDP lets sandbox
  # traffic route through the worker pod, and the larger neighbor table keeps
  # many sandboxes per node from overflowing it.
  # TODO: link
  net.ipv4.conf.all.proxy_arp: '1'
  net.ipv6.conf.all.proxy_ndp: '1'
  net.ipv4.neigh.default.gc_thresh1: '4096'
  net.ipv4.neigh.default.gc_thresh2: '16384'
  net.ipv4.neigh.default.gc_thresh3: '32768'
```

One gotcha, noted in the file itself: the taint isn't registered if the node already exists, so apply it once manually and keep the patch for reproducibility:

```bash
kubectl taint node <agent-node> node-role.bakseter.net/agent=true:NoSchedule # TODO: check
```

## 2. Install agent-substrate

Upstream offers two paths: the `kagent` CLI (imperative, eww) or Helm (declarative, yey!).
I obviously choose Helm via Argo CD since everything in my cluster is GitOps; this tutorial follows the Helm path.
The full app is [`manifests/cluster-addons/agent-substrate/`](https://github.com/bakseter/homelab/tree/74d6a98ad3a47859ebeff401e3174786bcfc9199/manifests/cluster-addons/agent-substrate),
deployed by the Argo CD Application [`agent-substrate.yaml`](https://github.com/bakseter/homelab/blob/74d6a98ad3a47859ebeff401e3174786bcfc9199/manifests/cluster-addons/agent-substrate.yaml):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: agent-substrate
  namespace: argocd
spec:
  destination:
    name: admin@homelab
  project: default
  source:
    path: manifests/cluster-addons/agent-substrate
    repoURL: https://github.com/bakseter/homelab.git
    targetRevision: HEAD
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

The Kustomization pulls three releases from `oci://ghcr.io/kagent-dev/substrate/helm` at `1.0.1` — `substrate` and `substrate-atelet` into `ate-system`, `substrate-podcert` (the PodCertificate controller) into `podcertificate-controller-system` — plus local resources (namespaces, ConfigMap, Job, SealedSecrets, CiliumNetworkPolicy) and securityContext patches on the substrate deployments:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: substrate
    repo: oci://ghcr.io/kagent-dev/substrate/helm
    version: 1.0.1
    releaseName: substrate
    namespace: ate-system
    valuesFile: values-substrate.yaml
  - name: substrate-atelet
    repo: oci://ghcr.io/kagent-dev/substrate/helm
    version: 1.0.1
    releaseName: substrate-atelet
    namespace: ate-system
    valuesFile: values-substrate-atelet.yaml
  - name: substrate-podcert
    repo: oci://ghcr.io/kagent-dev/substrate/helm
    version: 1.0.1
    releaseName: substrate-podcert
    namespace: podcertificate-controller-system

resources:
  - ciliumnetworkpolicy.yaml
  - configmap.yaml
  - job.yaml
  - namespace.yaml
  - sealedsecret.yaml
```

### Alas; manual steps

Agent Substrate authenticates its components with mTLS.
The CA and JWT pools that sign those identities are **not** created by any Helm chart.
Unfortunately you must use the `kubectl-ate` plugin and write them to Secrets.

I created them this way and then immediately put them into SealedSecrets instead.

```bash
# Install kubectl-ate from https://github.com/kagent-dev/substrate/releases

for pool in service-dns-ca-pool postgres-ca-pool pod-identity-ca-pool; do
  kubectl ate admin make-ca-pool --ca-id=1 --key-type=ED25519 \
    --name=${pool} --secret-namespace=podcertificate-controller-system
done

kubectl ate admin make-jwt-pool --key-id=1 \
  --name=actor-id-jwt-pool --secret-namespace=ate-system

kubectl ate admin make-ca-pool --ca-id=1 --key-type=ED25519 \
  --name=actor-id-ca-pool --secret-namespace=ate-system

kubectl ate admin make-ca-pool --ca-id=1 --key-type=ECDSAP256 \
  --name=egress-mitm-ca-pool --secret-namespace=ate-system
```

You also need the API-server authentication ConfigMap, which tells the substrate API how to validate Kubernetes ServiceAccount tokens. The issuer is cluster-specific — read it with `kubectl get --raw /.well-known/openid-configuration | jq -r .issuer`. Mine ([permalink](https://github.com/bakseter/homelab/blob/74d6a98ad3a47859ebeff401e3174786bcfc9199/manifests/cluster-addons/agent-substrate/configmap.yaml)) uses an in-cluster issuer, which needs the CA/token file lines:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ate-api-authentication
  namespace: ate-system
data:
  authentication.yaml: |
    jwtProviders:
    - name: kubernetes
      issuer: https://192.168.30.190:6443        # your API server issuer
      audiences: [api.ate-system.svc]
      certificateAuthorityFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      discoveryTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
```

(With an external issuer like GKE's, omit the last two lines — setting `certificateAuthorityFile` then breaks the TLS handshake to the public issuer.)

### Values

`values-substrate.yaml` ([permalink](https://github.com/bakseter/homelab/blob/74d6a98ad3a47859ebeff401e3174786bcfc9199/manifests/cluster-addons/agent-substrate/values-substrate.yaml)) — the parts that matter:

```yaml
atelet:
  enabled: false # runs in the separate substrate-atelet release

preview:
  - PerTemplateSnapshotLocation
  - GoldenEgressPolicy

ateApi:
  authorization:
    bootstrapOwners:
      - spiffe://cluster.local/ns/kagent/sa/kagent-controller
      - system:serviceaccount:ate-system:ate-client

atenetRouter:
  ingressAllowedSPIFFEIDs:
    - spiffe://cluster.local/ns/kagent/sa/kagent-controller

credentialProvider:
  namespacePolicies:
    - atespace: kagent
      allowedNamespaces: [kagent] # agents may read Secrets only in kagent
```

Two things worth understanding here. `bootstrapOwners` grants owner access to the substrate API; without the kagent controller entry, every Agent reports `RuntimePreparationFailed (PermissionDenied)`. And `credentialProvider.namespacePolicies` denies everything until a policy allows it — this is how agent-held credentials are scoped to a namespace.

The `atelet` DaemonSet is pinned to the agent node via a kustomize patch in the Kustomization (nodeSelector `node-role.bakseter.net/agent: 'true'` plus the matching toleration) — same for the kagent worker pool in section 3.

`values-substrate-atelet.yaml` points `atelet` at the object store used for agent snapshots. Mine uses the cluster's own RustFS via S3, and a PreSync Job (`job.yaml`) creates the `ate-snapshots` bucket:

```yaml
preview:
  - PerTemplateSnapshotLocation
  - GoldenEgressPolicy

objectStore:
  backend: s3
  endpoint: http://rustfs-svc.rustfs.svc.cluster.local:9000
  region: us-east-1
  pathStyle: true
  credentialsSecret: rustfs-credentials
```

If you don't run an S3-compatible store, the upstream guide shows the bundled rustfs option — for a tutorial cluster either works; the point is that the `preview` values must match between the `substrate` and `substrate-atelet` releases.

## 3. Install kagent

Same pattern: one Argo CD Application ([`kagent.yaml`](https://github.com/bakseter/homelab/blob/74d6a98ad3a47859ebeff401e3174786bcfc9199/manifests/cluster-addons/kagent.yaml)) deploying the umbrella chart in [`manifests/cluster-addons/kagent/`](https://github.com/bakseter/homelab/tree/74d6a98ad3a47859ebeff401e3174786bcfc9199/manifests/cluster-addons/kagent). `Chart.yaml` pulls `kagent-crds`, `substrate-crds` and `kagent`, all `1.0.1` from `oci://ghcr.io/kagent-dev/kagent/helm`.

### Database: CloudNativePG, not the bundled dev Postgres

The CLI path deploys a dev Postgres; I don't want that in a homelab, so the repo runs a CloudNativePG `Cluster` ([permalink](https://github.com/bakseter/homelab/blob/74d6a98ad3a47859ebeff401e3174786bcfc9199/manifests/cluster-addons/kagent/templates/cluster.yaml)):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: kagent-database
  namespace: kagent
spec:
  instances: 1
  storage:
    size: 5Gi
  imageCatalogRef:
    apiGroup: postgresql.cnpg.io
    kind: ClusterImageCatalog
    name: postgresql-minimal-trixie
    major: 18
  postgresql:
    extensions:
      - name: pgvector # long-term agent memory needs pgvector
    pg_hba:
      - hostssl all all all scram-sha-256
  bootstrap:
    initdb:
      database: kagent
      owner: kagent
```

plus a `Database` resource enabling the `vector` extension in an `extensions` schema. CNPG then emits the `kagent-database-app` (connection string) and `kagent-database-ca` (server CA) Secrets that the kagent values reference. The controller mounts the CA at `/run/postgres-ca` so connections verify the server certificate:

```yaml
controller:
  replicas: 2
  substrateClientCertificate:
    enabled: true # present a pod cert to the substrate API
  volumes:
    - name: postgres-ca
      secret:
        secretName: kagent-database-ca
        items:
          - key: ca.crt
            path: ca.crt
  volumeMounts:
    - name: postgres-ca
      mountPath: /run/postgres-ca
      readOnly: true

database:
  postgres:
    ownerConnectionStringSecretRef:
      name: kagent-database-app
      key: uri
    readWriteConnectionStringSecretRef:
      name: kagent-database-app
      key: uri
```

### The worker pool

This is where agents actually run — gVisor workers, pinned to the agent node:

```yaml
substrateWorkerPool:
  create: true
  workerImage: 'ghcr.io/kagent-dev/substrate/ateworker-gvisor:v1.0.1'
  template:
    nodeSelector:
      node-role.bakseter.net/agent: 'true'
    tolerations:
      - key: node-role.bakseter.net/agent
        operator: Equal
        value: 'true'
        effect: NoSchedule
```

The worker image tag must match the substrate version — the substrate controller starts each worker with flags from its own release.

### Namespace labels — the one that bites

The Application's `managedNamespaceMetadata` sets two labels on `kagent`:

```yaml
managedNamespaceMetadata:
  labels:
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/enforce: privileged
    ate.dev/api-access: 'true'
```

`ate.dev/api-access: 'true'` is a hard requirement: the substrate's default-deny NetworkPolicy only admits labelled namespaces to its API server, and without the label the kagent controller fails at startup with `context deadline exceeded`. The `privileged` enforcement is the one place I relax pod security — the sandbox workers need it. The `ate-system` namespace gets the same treatment in `agent-substrate/namespace.yaml`.

### UI

The UI gets an `HTTPRoute` on my Tailscale gateway, so it's reachable at `https://kagent.bakseter.net` over the tailnet without any public exposure:

```yaml
ui:
  externalUrl: https://kagent.bakseter.net
  httpRoute:
    enabled: true
    parentRefs:
      - group: gateway.networking.k8s.io
        kind: Gateway
        name: tailscale-home
        namespace: tailscale
    hostnames:
      - kagent.bakseter.net
```

Swap in your ingress/gateway of choice; for local testing, `kubectl port-forward -n kagent svc/kagent-ui 8082:8080`.

## 4. Model config

A `ModelConfig` CR plus a SealedSecret for the key — plaintext never touches git. Mine routes Mistral through the agentgateway proxy, which holds the real provider key as a "virtual key" (so the key is injected at egress, not sitting in a kagent Secret — though it is still a Secret, just sealed) ([permalink](https://github.com/bakseter/homelab/blob/74d6a98ad3a47859ebeff401e3174786bcfc9199/manifests/cluster-addons/kagent/templates/modelconfig.yaml)):

```yaml
apiVersion: api.kagent.dev/v1alpha3
kind: ModelConfig
metadata:
  name: mistral-large-4
  namespace: kagent
spec:
  model: mistral-large-4
  provider: Mistral
  mistral:
    baseUrl: http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1
  apiKeySecret: agentgateway-virtual-key
  apiKeySecretKey: VIRTUAL_KEY
```

Sealing the key:

```bash
kubectl create secret generic agentgateway-virtual-key -n kagent \
  --from-literal=VIRTUAL_KEY=$PROVIDER_API_KEY \
  --dry-run=client -o yaml | kubeseal --format yaml > sealedsecret.yaml
```

## 5. Define an agent

Three CRs (`api.kagent.dev/v1alpha3`): a `Harness`, an `AgentTemplate`, an `Agent`. The Harness tells the substrate where to keep agent snapshots and which worker pool to use ([permalink](https://github.com/bakseter/homelab/blob/74d6a98ad3a47859ebeff401e3174786bcfc9199/manifests/cluster-addons/kagent/templates/harness.yaml)):

```yaml
apiVersion: api.kagent.dev/v1alpha3
kind: Harness
metadata:
  name: kagent
  namespace: kagent
spec:
  kagent: {}
  substrate:
    snapshotPolicy:
      location: s3://ate-snapshots/kagent/
    workerPoolRef:
      name: kagent-default
  workload:
    image: ghcr.io/kagent-dev/kagent/golang-adk:1.0.1@sha256:d3b115...
```

The template carries the model, the system prompt (from a ConfigMap — keep the prompt in git, it's config, not secret), and the MCP tools. Mine ([permalink](https://github.com/bakseter/homelab/blob/74d6a98ad3a47859ebeff401e3174786bcfc9199/manifests/cluster-addons/kagent/templates/agents/homelab.yaml)):

```yaml
apiVersion: api.kagent.dev/v1alpha3
kind: AgentTemplate
metadata:
  name: homelab-agent
  namespace: kagent
spec:
  description: Helps manage the homelab.
  modelConfig:
    name: mistral-large-4
  systemPromptFrom:
    name: homelab-agent-prompt
    key: system-message
  tools:
    - mcp:
        server:
          kind: RemoteMCPServer
          name: github-mcp
        tools:
          [
            get_file_contents,
            search_code,
            list_commits,
            get_commit,
            list_branches,
          ]
    - mcp:
        server:
          kind: RemoteMCPServer
          name: kagent-tool-server
        tools:
          [
            k8s_get_resources,
            k8s_get_resource_yaml,
            k8s_describe_resource,
            k8s_get_events,
            k8s_get_pod_logs,
            k8s_get_available_api_resources,
            cilium_get_endpoints_list,
            cilium_status_and_version,
            prometheus_query_tool,
            prometheus_query_range_tool,
            ...,
          ]
---
apiVersion: api.kagent.dev/v1alpha3
kind: Agent
metadata:
  name: homelab-agent
  namespace: kagent
spec:
  template:
    ref:
      name: homelab-agent
  harnessRef:
    name: kagent
```

The RBAC behind "read-only" is worth stating plainly, because it's the actual security boundary: the tool server's ServiceAccount gets cluster-wide `view` plus `pods/log`, and get/list/watch on the CRD groups an agent might inspect — nothing else ([permalink](https://github.com/bakseter/homelab/blob/74d6a98ad3a47859ebeff401e3174786bcfc9199/manifests/cluster-addons/kagent/templates/rbac.yaml)):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kagent-tools-view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: ServiceAccount
    name: kagent-tools
    namespace: kagent
```

So the worst an agent can do through its tools is read. Writes fail with Forbidden, and every real change goes through git + Argo CD where a human reviews it. That's the whole point of running this way.

## 6. Verify

```bash
kubectl get pods -n ate-system        # atelet, atenet-egress, atenet-router, podcert controller
kubectl get pods -n kagent            # controller x2, ui, tools, kagent-default worker, database
kubectl get workerpools -n kagent     # kagent-default, READY >= 1
kubectl get agents,agenttemplates,modelconfigs -n kagent
argocd app get kagent                 # Synced / Healthy
argocd app get agent-substrate        # Synced / Healthy
```

Then open the UI and start a session. Expected live state at the time of writing: `ate-api-server` (2 replicas), `ate-controller`, `ate-idp-server` (2), `atelet` (DaemonSet on the agent node), `atenet-egress`, `atenet-router`, `k8s-credential-provider` in `ate-system`; `kagent-controller` (2), `kagent-ui`, `kagent-tools`, `kagent-default` worker and `kagent-database-1` in `kagent` — all Running, both Argo CD apps Synced/Healthy.

## Thoughts, after running it

- **The substrate is the interesting part, not kagent.** kagent's CRDs are a nice authoring layer, but the value is that agents are untrusted workloads: gVisor on a tainted dedicated node, SPIFFE identity instead of ambient cluster trust, per-actor egress policies through a gateway that MITMs TLS to inject credentials. The model API key never sits in a plaintext Secret an agent pod can read — it enters at the egress gateway.
- **Kubernetes 1.37 is a real floor.** Not because Talos is behind — my cluster is on 1.37.0 — but because the whole identity model leans on `PodCertificateRequest` and `ClusterTrustBundle`. On older clusters you'd be stubbing the thing that makes the setup sound, so don't.
- **Talos makes the node part trivial.** The sysctls gVisor and per-sandbox netns need (`user.max_user_namespaces`, proxy ARP/NDP, neighbor table sizing) are exactly the kind of thing that's fragile as runtime tweaks on a mutable-OS cluster and boring as a machine-config patch on Talos. That's the honest reason Talos is in the title.
- **The costs are real but small**: one dedicated node, a privileged pod-security exception in two namespaces, and a second Postgres cluster. The kagent namespace needs `enforce: privileged` because the workers spawn sandboxes; everything else stays restricted.
- **Watch the gotchas**: the node label needs one manual `kubectl label` on first boot, the `ate.dev/api-access` namespace label is load-bearing, the worker image tag must match the substrate chart version, and the `preview` feature gates must match between the `substrate` and `substrate-atelet` releases. Each of these fails loudly but confusingly if you miss it.
- **GitOps holds up.** Both installs are plain Argo CD Applications with `prune` + `selfHeal`; drift self-corrects, and the entire agent platform — substrate, controller, database, model config, agent definitions, RBAC, network policies — is reviewable diffs in one repo. The one thing git can't hold is the sealed identity pools and API keys, and that's what SealedSecrets are for.

The only thing I'd change next: run the database with more than one instance once agents actually matter for something, and give the egress gateway an explicit allowlist per agent instead of relying on the default policy.
