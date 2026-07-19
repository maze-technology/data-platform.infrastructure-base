# Temporal Setup Guide

This document describes the Temporal.io setup included in this infrastructure repository.

## Overview

Temporal is a workflow orchestration platform that provides:

- Durable execution of workflows
- Automatic retries and error handling
- Visibility into workflow execution
- Scalable and fault-tolerant architecture

Each environment (local, production) has its own dedicated Temporal cluster with two namespaces:

- **data-platform**: For data processing and ETL workflows
- **trading-platform**: For trading and financial workflows

## Architecture

### Components

1. **Temporal Server**: Core Temporal services

   - Frontend: gRPC API for client connections
   - History: Workflow execution history
   - Matching: Task queue management
   - Worker: System workflows

2. **Persistence**: Storage backend

   - **All Environments**: PostgreSQL (simpler, production-ready)
   - PostgreSQL provides excellent performance for most workloads and is operationally simpler than Cassandra

3. **Visibility**: Advanced workflow search

   - Elasticsearch for all environments

4. **Web UI**: Web-based workflow monitoring
   - Accessible via ingress

## Environments

### Local Environment

Configuration (formerly in env roots; now parameterized on the root module / composition repo):

```hcl
module "temporal" {
  source = "../../modules/temporal"

  cluster_name         = local.cluster_name
  environment          = local.environment
  replica_count        = 1
  enable_ha            = false
  ingress_enabled      = true
  ingress_host         = "temporal.local"
  enable_tls           = false
  temporal_namespaces  = ["data-platform", "trading-platform"]
  use_postgresql       = true
  postgresql_storage_size = "5Gi"
  elasticsearch_storage_size = "5Gi"
}
```

**Access Points**:

- Web UI: http://temporal.local:30080 (via NodePort ingress)
- Frontend gRPC: `temporal-frontend.temporal.svc.cluster.local:7233`

**Port-forward alternative**:

```bash
kubectl port-forward -n temporal svc/temporal-frontend 7233:7233
kubectl port-forward -n temporal svc/temporal-web 8080:8080
```

### Production Environment

Production configuration (composition repo inputs to this module):

```hcl
module "temporal" {
  source = "../../modules/temporal"

  cluster_name            = local.cluster_name
  environment             = local.environment
  replica_count           = 3
  enable_ha               = true
  ingress_enabled         = true
  ingress_host            = var.temporal_host
  enable_tls              = true
  temporal_namespaces     = ["data-platform", "trading-platform"]
  use_postgresql          = true  # Uses PostgreSQL
  postgresql_storage_size = "100Gi"
  elasticsearch_storage_size = "50Gi"
}
```

**Access Points**:

- Web UI: https://temporal.production.maze.tech (via LoadBalancer ingress with TLS)
- Frontend gRPC: `temporal-frontend.temporal.svc.cluster.local:7233`

## Temporal Namespaces

The setup automatically creates two Temporal namespaces:

1. **data-platform**

   - Purpose: Data processing, ETL pipelines, batch jobs
   - Use cases: Data ingestion, transformation, aggregation

2. **trading-platform**
   - Purpose: Trading workflows, order processing, risk management
   - Use cases: Order execution, settlement, market data processing

### Using Namespaces

When connecting to Temporal, specify the namespace:

**Go SDK Example**:

```go
c, err := client.Dial(client.Options{
    HostPort:  "temporal-frontend.temporal.svc.cluster.local:7233",
    Namespace: "data-platform",
})
```

**Python SDK Example**:

```python
client = await Client.connect(
    "temporal-frontend.temporal.svc.cluster.local:7233",
    namespace="data-platform",
)
```

**TypeScript SDK Example**:

```typescript
const connection = await Connection.connect({
  address: 'temporal-frontend.temporal.svc.cluster.local:7233'
});

const client = new Client({
  connection,
  namespace: 'data-platform'
});
```

## Deployment

### Initial Setup

1. **Deploy the infrastructure**:

   ```bash
   # From the infrastructure composition repo env root
   tofu init
   tofu plan
   tofu apply
   ```

2. **Wait for Temporal to be ready**:

   ```bash
   kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=temporal -n temporal --timeout=600s
   ```

3. **Verify namespaces were created**:
   ```bash
   kubectl logs -n temporal -l app=temporal-namespace-setup
   ```

### Verifying the Installation

**Check Temporal pods**:

```bash
kubectl get pods -n temporal
```

Expected pods:

- `temporal-frontend-*`
- `temporal-history-*`
- `temporal-matching-*`
- `temporal-worker-*`
- `temporal-web-*`
- `temporal-postgresql-*`
- `temporal-elasticsearch-*`

**Check Temporal services**:

```bash
kubectl get svc -n temporal
```

**Access Web UI**:

```bash
# Local environment
curl http://temporal.local:30080

# Production environment
curl https://temporal.production.maze.tech
```

### Using tctl (Temporal CLI)

Install tctl on your local machine:

```bash
brew install temporal  # macOS
# or
curl -sSf https://temporal.download/cli.sh | sh  # Linux
```

**List namespaces**:

```bash
tctl --namespace data-platform namespace describe
tctl --namespace trading-platform namespace describe
```

**Run a test workflow**:

```bash
tctl --namespace data-platform workflow run \
  --workflow_type HelloWorld \
  --task_queue hello-world \
  --input '"World"'
```

## Monitoring

### Prometheus Metrics

Temporal automatically exposes Prometheus metrics. These are scraped by the observability module.

**View metrics in Grafana**:

1. Access Grafana (http://grafana.local:30080 or https://grafana.production.maze.tech)
2. Import Temporal dashboards from https://github.com/temporalio/dashboards

### Web UI

The Temporal Web UI provides:

- Workflow execution history
- Search and filtering
- Workflow replay and debugging
- Task queue monitoring
- Namespace management

## Troubleshooting

### Pods not starting

Check pod status:

```bash
kubectl describe pod -n temporal <pod-name>
```

Check logs:

```bash
kubectl logs -n temporal <pod-name>
```

### Namespace creation failed

Check the namespace creation job:

```bash
kubectl get job -n temporal create-temporal-namespaces
kubectl logs -n temporal -l app=temporal-namespace-setup
```

Manually create namespaces:

```bash
kubectl exec -it -n temporal deployment/temporal-frontend -- \
  tctl --namespace data-platform namespace register

kubectl exec -it -n temporal deployment/temporal-frontend -- \
  tctl --namespace trading-platform namespace register
```

### Cannot connect to Temporal

Verify frontend service:

```bash
kubectl get svc -n temporal temporal-frontend
```

Test connectivity from a pod:

```bash
kubectl run -it --rm debug --image=busybox --restart=Never -- \
  nc -zv temporal-frontend.temporal.svc.cluster.local 7233
```

### Storage issues

**Check PostgreSQL**:

```bash
kubectl logs -n temporal deployment/temporal-postgresql
kubectl get pvc -n temporal
```

**Check PostgreSQL connectivity**:

```bash
kubectl exec -it -n temporal deployment/temporal-postgresql -- psql -U temporal -d temporal -c "\dt"
```

## Configuration Options

### Module Variables

Key variables that can be customized:

- `replica_count`: Number of replicas for each Temporal service
- `enable_ha`: Enable high availability (increases replicas automatically)
- `temporal_namespaces`: List of Temporal namespaces to create
- `use_postgresql`: Use PostgreSQL (recommended) or Cassandra for persistence
- `postgresql_storage_size`: Storage size for PostgreSQL (default choice)
- `cassandra_storage_size`: Storage size for Cassandra (if use_postgresql=false)
- `elasticsearch_storage_size`: Storage size for Elasticsearch

**Note**: PostgreSQL is recommended for most use cases due to operational simplicity. Cassandra should only be used for extreme scale (>1000 workflows/sec) or multi-region deployments.

See `iac/modules/temporal/variables.tf` for all available options.

### Resource Requests and Limits

Default values are conservative. For production, consider increasing:

```hcl
module "temporal" {
  # ... other config ...

  resource_requests = {
    frontend = { cpu = "500m", memory = "512Mi" }
    history  = { cpu = "500m", memory = "512Mi" }
    matching = { cpu = "500m", memory = "512Mi" }
    worker   = { cpu = "500m", memory = "512Mi" }
  }

  resource_limits = {
    frontend = { cpu = "2000m", memory = "2Gi" }
    history  = { cpu = "2000m", memory = "2Gi" }
    matching = { cpu = "2000m", memory = "2Gi" }
    worker   = { cpu = "2000m", memory = "2Gi" }
  }
}
```

## Security Considerations

### Network Policies

Consider implementing network policies to restrict access to Temporal:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: temporal-access
  namespace: temporal
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: temporal
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: data-platform
        - namespaceSelector:
            matchLabels:
              name: trading-platform
```

### TLS/mTLS

For production, consider enabling mTLS for client connections:

- Configure TLS certificates for Temporal frontend
- Update client SDKs to use TLS
- Implement client certificate authentication

### Secrets Management

Store sensitive credentials in Kubernetes secrets or external secret managers:

- Database passwords
- Elasticsearch credentials
- TLS certificates

## Scaling

### Horizontal Scaling

Increase replicas for specific services:

```hcl
module "temporal" {
  replica_count = 5  # Scales all services
  enable_ha     = true  # Automatically increases critical services
}
```

### Vertical Scaling

Increase resource limits:

- Adjust `resource_requests` and `resource_limits`
- Monitor pod resource usage with Prometheus/Grafana

### Storage Scaling

Increase persistent volume sizes:

- `postgresql_storage_size` (or `cassandra_storage_size` if using Cassandra)
- `elasticsearch_storage_size`

**Note**: PVC resizing depends on storage class capabilities.

### PostgreSQL High Availability

For production PostgreSQL, consider:

- **Managed Services**: AWS RDS, Azure Database for PostgreSQL, GCP Cloud SQL
- **HA Solutions**: Patroni, Stolon, or pgpool-II for automatic failover
- **Read Replicas**: Offload read traffic from primary

Example with external PostgreSQL:

```hcl
# Use external managed PostgreSQL instead of in-cluster
# Configure via Temporal's database settings in Helm values
```

## Additional Resources

- [Temporal Documentation](https://docs.temporal.io/)
- [Temporal Helm Chart](https://github.com/temporalio/helm-charts)
- [Temporal SDKs](https://docs.temporal.io/dev-guide)
- [Temporal Best Practices](https://docs.temporal.io/dev-guide/best-practices)
