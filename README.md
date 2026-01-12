# Infrastructure Global

This repository manages the global infrastructure for the platform, providing a consistent foundation across all environments (local, prod).

## Overview

This repository is responsible for:

- **Cloud Infrastructure**: Provisioning and managing cloud resources using OpenTofu (Terraform-compatible)
- **Kubernetes Clusters**: Creating and managing Kubernetes clusters for all environments
- **Cluster-Level Components**: Bootstrapping essential platform components:
  - Storage (Rook-Ceph: block storage, S3-compatible object storage)
  - Ingress controllers (NGINX)
  - cert-manager (TLS certificate management)
  - Observability stack (Prometheus, Grafana, Loki, Promtail)
  - GitOps engine (Argo CD)
  - Workflow orchestration (Temporal)
- **Global Networking**: VPC/VNet, subnets, routing, and network policies
- **IAM and Security**: Global IAM roles, policies, and security configurations
- **Shared Resources**: Cross-environment resources and configurations

## What This Repository Does NOT Do

- Deploy business microservices (data or trading services)
- Manage application-level configurations
- Handle environment-specific application deployments

## Quick Start

### Local Development

1. **Create a kind cluster**:

   ```bash
   make kind-up
   ```

2. **Configure storage devices (optional for local testing)**:

   For local/kind, you may need to set up loop devices or configure storage:

   ```bash
   # Example: Create loop devices for testing
   sudo losetup -fP /path/to/disk.img
   ```

   Then update `iac/envs/local/main.tf` with your device paths:

   ```hcl
   # SAFETY: Devices MUST be explicitly specified - automatic device discovery is disabled
   storage_devices = ["/dev/loop0"]  # Adjust based on your setup
   ```

3. **Deploy infrastructure**:

   ```bash
   cd iac/envs/local
   tofu init
   tofu plan
   tofu apply
   ```

   This will automatically:

   - Install Rook-Ceph CRDs
   - Deploy Rook-Ceph storage (RBD + RGW S3)
   - Deploy observability stack (Loki uses RGW for S3 storage)
   - Deploy other components

4. **Access services**:
   - Grafana: http://localhost:30080 (via ingress) or port-forward
   - Argo CD: http://localhost:30080 (via ingress) or port-forward
   - Temporal UI: http://localhost:30080 (via ingress) or port-forward
   - Ceph Dashboard: Port-forward to `rook-ceph-mgr-dashboard` service

### Cloud Environments

1. **Configure environment**:

   ```bash
   cd iac/envs/<environment>
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your values
   ```

2. **Deploy**:
   ```bash
   tofu init
   tofu plan -var-file=terraform.tfvars
   tofu apply
   ```

## Modules

### Cluster Module

Manages Kubernetes cluster creation and configuration. Supports:

- Local development with `kind`
- Cloud-managed Kubernetes clusters (AWS EKS, Azure AKS, GKE, etc.)

### Network Module

Manages networking infrastructure:

- VPC/VNet creation
- Subnet configuration (public/private)
- Routing and NAT gateways

### Ingress Module

Installs and configures ingress controllers:

- NGINX Ingress Controller (default)
- Service type configuration (LoadBalancer, NodePort)
- Metrics and monitoring integration

### Cert-Manager Module

Manages TLS certificates:

- cert-manager installation
- Let's Encrypt integration
- Automatic certificate provisioning

### Rook-Ceph Module

Production-grade distributed storage:

- **CephCluster**: MON, MGR, OSD daemons for distributed storage
- **RBD (Block Storage)**: Kubernetes StorageClass for persistent volumes (PostgreSQL, etc.)
- **RGW (Object Storage)**: S3-compatible object storage for applications and Loki
- **Recovery Throttling**: Configured for latency-sensitive workloads
- **High Availability**: Cluster remains HEALTH_OK with 1 node down

### Observability Module

Complete observability stack:

- **Prometheus**: Metrics collection and storage
- **Grafana**: Visualization and dashboards
- **Loki**: Log aggregation (uses Rook-Ceph RGW for S3 storage)
- **Promtail**: Log collection agent

### Argo CD Module

GitOps deployment engine:

- Argo CD installation
- High availability configuration
- Ingress and TLS support

### Temporal Module

Workflow orchestration platform:

- Temporal server installation
- Configurable persistence backend (PostgreSQL or Cassandra)
- Elasticsearch for advanced visibility
- Multiple Temporal namespaces support (data-platform, trading-platform)
- Web UI with ingress support
- High availability configuration for production

## Environments

### Local

- Uses `kind` for local Kubernetes cluster
- NodePort services for ingress (ports 30080/30443)
- Reduced resource requirements
- No TLS (for simplicity)
- Uses Rook-Ceph RGW for S3-compatible object storage (same scalable Loki configuration as prod)
- Single-node Ceph cluster (can be scaled for multi-node testing)

### Prod

- Maximum availability and redundancy
- Largest resource allocations
- Production-grade security

See [docs/environments.md](docs/environments.md) for detailed environment documentation.

## Prerequisites

- OpenTofu (Terraform-compatible) >= 1.5.0
- Kubernetes provider >= 2.23
- Helm provider >= 2.11
- kubectl (for local development and CRD installation)
- kind (for local development)
- Raw storage devices (for production) or loop devices (for local testing)

## Local Development Setup

The local environment uses Rook-Ceph RGW to provide S3-compatible object storage, allowing you to use the same scalable Loki configuration as production. This eliminates the need for external services like LocalStack.

### Quick Start

Set up the complete local development environment with one command:

```bash
make local-setup
```

This will:

- Create the kind Kubernetes cluster
- You can then deploy infrastructure which includes Rook-Ceph for storage

### Manual Setup

1. **Create the kind cluster:**

   ```bash
   make kind-up
   ```

2. **Configure storage devices (for local/kind):**

   For local testing, you can use loop devices:

   ```bash
   # Create a loop device (example)
   sudo losetup -fP /path/to/disk.img
   # This creates /dev/loop0, /dev/loop1, etc.
   ```

   Then update `iac/envs/local/main.tf` to reference these devices:

   ```hcl
   # SAFETY: Devices MUST be explicitly specified - automatic device discovery is disabled
   storage_devices = ["/dev/loop0"]  # Adjust based on your setup
   ```

3. **Deploy infrastructure:**

   ```bash
   cd iac/envs/local
   make init
   make plan
   make apply
   ```

   This will:

   - Install Rook-Ceph CRDs automatically
   - Deploy Rook-Ceph operator and cluster
   - Create RGW S3-compatible object store
   - Deploy observability stack (Loki will use RGW for storage)
   - Deploy other components (ingress, Argo CD, Temporal)

### Stopping Local Services

To stop all local services:

```bash
make local-teardown
```

This will delete the kind cluster. All data in Rook-Ceph will be lost (this is expected for local development).

## Makefile Commands

The project includes a comprehensive Makefile for common operations:

### Terraform/OpenTofu Commands

- `make format` - Format all Terraform files
- `make validate` - Validate Terraform configuration (defaults to local environment)
- `make plan` - Plan Terraform changes
- `make apply` - Apply Terraform changes
- `make destroy` - Destroy Terraform infrastructure
- `make init` - Initialize Terraform

### Local Development Commands

- `make local-setup` - Set up complete local environment (Kind cluster)
- `make local-teardown` - Tear down local environment
- `make kind-up` - Create kind cluster
- `make kind-down` - Delete kind cluster
- `make kind-status` - Check kind cluster status

### Environment Variables

- `ENV` - Terraform environment (default: `local`)
- `CLUSTER_NAME` - Kind cluster name (default: `local`)

Example:

```bash
make validate ENV=prod
make kind-up CLUSTER_NAME=dev
```

Run `make help` to see all available commands.

## Configuration

### Secrets Management

**Never commit secrets to the repository!**

Secrets should be provided via:

- Environment variables: `export TF_VAR_letsencrypt_email="admin@maze.tech"`
- Secret managers (AWS Secrets Manager, Azure Key Vault, etc.)
- CI/CD pipeline variables
- `terraform.tfvars` files (excluded from git via `.gitignore`)

### Environment Variables

Set environment-specific variables:

```bash
export TF_VAR_letsencrypt_email="admin@maze.tech"
export TF_VAR_grafana_host="grafana.prod.maze.tech"
export TF_VAR_argocd_host="argocd.prod.maze.tech"
```

## Documentation

- [Architecture Overview](docs/architecture.md)
- [Environment Guide](docs/environments.md)

## Style Guidelines

- Use UTF-8 encoding, 2 spaces for indentation, LF line endings
- No trailing whitespace, final newline required
- Small, composable modules with clear inputs/outputs
- Meaningful variable names with descriptions
- Environment differences via variables and `*.tfvars`, not copy-pasted resources
- Production-ready defaults (resource requests/limits, labels, annotations)

## Contributing

When making changes:

1. Ensure changes fit the repository's responsibilities (global infra only)
2. Respect the modular layout
3. Keep configuration environment-agnostic where possible
4. Push environment specifics into `envs/*` and variable values
5. Follow the existing code style and conventions

## License

[Add your license here]
