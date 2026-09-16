---
title: Technitium DNS cluster on Kubernetes
description: How to run a highly-available Technitium DNS cluster on Kubernetes
---

[Technitium DNS Server](https://technitium.com/dns) is a great alternative for running your own privacy-focused DNS server.
Starting with version 14, it also supports [running mulitple instances of Technitium DNS as a cluster](https://blog.technitium.com/2025/11/understanding-clustering-and-how-to.html).
This got me thinking immediately on how it could be used with Kubernetes to create a higly-available and declarative
Kubernetes deployment of Technitium.

## Problems

Technitium DNS is stateful, and cannot be configured only via static config files; the GUI or API must be used.
Since I'm impatient, I went with using the GUI for the few manual steps needed.

## Solution

### Assumptions

- You have persistent storage configured
- You know the CIDR of your Pod subnet

### Kubernetes resources

We use a StatefulSet to model the Technitium cluster, each with a matching PVC and Service.

```yaml
# statefulset.yaml
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: technitium
  namespace: technitium
spec:
  serviceName: technitium
  replicas: 3
  template:
    spec:
      containers:
        - name: technitium
          image: technitium/dns-server:15.4.0@sha256:df7d90ef0f7b6fff6916d291a7022cd902290cc31c3141d4158b6c375a641b41
          ports:
            - name: console-http
              containerPort: 5380
              protocol: TCP
            - name: console-https
              containerPort: 53443
              protocol: TCP
            - name: dns-udp
              containerPort: 53
              protocol: UDP
            - name: dns-tcp
              containerPort: 53
              protocol: TCP
          env:
            - name: DNS_SERVER_LOG_MAX_LOG_FILE_DAYS
              value: '1'
            - name: DNS_SERVER_BLOCK_LIST_URLS
              value: 'https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/pro-onlydomains.txt'
            - name: DNS_SERVER_FORWARDERS
              value: '1.1.1.1,8.8.8.8'
            - name: DNS_SERVER_ENABLE_BLOCKING
              value: 'true'
          envFrom:
            - secretRef:
                name: technitium
          readinessProbe:
            tcpSocket:
              port: 53
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 53
            initialDelaySeconds: 30
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            readOnlyRootFilesystem: true
          volumeMounts:
            - name: config
              mountPath: /etc/dns
            - name: tmp
              mountPath: /tmp
      securityContext:
        fsGroup: 65534
        runAsGroup: 65534
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile:
          type: RuntimeDefault
      volumes:
        - name: tmp
          emptyDir: {}
  volumeClaimTemplates:
    - metadata:
        name: config
      spec:
        accessModes: ['ReadWriteOnce']
        resources:
          requests:
            storage: 1Gi
```

Admin password is set via a Secret.

```yaml
# secret.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: technitium
  namespace: technitium
type: Opaque
data:
  DNS_SERVER_ADMIN_PASSWORD: <...>
```

We create one Service for each replica of the StatefulSet.
This could probably be templated dynamically, but I like to KISS.

```yaml
# service.yaml
---
apiVersion: v1
kind: Service
metadata:
  name: technitium-0
  namespace: technitium
spec:
  type: ClusterIP
  selector:
    statefulset.kubernetes.io/pod-name: technitium-0
  ports:
    - name: console-http
      port: 5380
      targetPort: 5380
      protocol: TCP
    - name: console-https
      port: 53443
      targetPort: 53443
      protocol: TCP
    - name: dns-udp
      port: 53
      targetPort: 53
      protocol: UDP
    - name: dns-tcp
      port: 53
      targetPort: 53
      protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: technitium-1
  namespace: technitium
spec:
  type: ClusterIP
  selector:
    statefulset.kubernetes.io/pod-name: technitium-1
  ports:
    - name: console-http
      port: 5380
      targetPort: 5380
      protocol: TCP
    - name: console-https
      port: 53443
      targetPort: 53443
      protocol: TCP
    - name: dns-udp
      port: 53
      targetPort: 53
      protocol: UDP
    - name: dns-tcp
      port: 53
      targetPort: 53
      protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: technitium-2
  namespace: technitium
spec:
  type: ClusterIP
  selector:
    statefulset.kubernetes.io/pod-name: technitium-2
  ports:
    - name: console-http
      port: 5380
      targetPort: 5380
      protocol: TCP
    - name: console-https
      port: 53443
      targetPort: 53443
      protocol: TCP
    - name: dns-udp
      port: 53
      targetPort: 53
      protocol: UDP
    - name: dns-tcp
      port: 53
      targetPort: 53
      protocol: TCP
```

### Configure the primary instance

1. Port-forward the primary pod

  ```bash
  kubectl -n technitium port-forward svc/technitium-0 8080:8080
  ```

  Go to `http://localhost:8080` and login with your admin password.

2. Create a cluster.

3. Enter some config stuff somewhere.

3. Enter CIDR of pod subnet somewhere.

### Configure the other instances

1. Port-forward the pod of the instance

  ```bash
  kubectl -n technitium port-forward svc/technitium-<instance> 8080:8080
  ```

  Go to `http://localhost:8080` and login with your admin password.

2. Join the cluster or something.

3. Enter CIDR of pod subnet somewhere.

### Test

1. ???

2. Profit

## Closing notes

I've been running more or less [this exact setup](https://github.com/bakseter/homelab/tree/b02b4c924255a19a14929cb7b6e70e477f6e31e8/manifests/cluster-addons/technitium)
for several months, and it is working great.
In the future, I'd like to create a more declarative setup for running clustered Technitium.
Maybe a Technitium Helm chart, or a Technitium Operator?
