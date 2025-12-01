# Infrastructure Global

This repository manages the global infrastructure for the platform, providing a consistent foundation across all environments (local, prod).

## Overview

This repository is responsible for:

- **Cloud Infrastructure**: Provisioning and managing cloud resources using OpenTofu (Terraform-compatible)
- **Kubernetes Clusters**: Creating and managing Kubernetes clusters for all environments
- **Cluster-Level Components**: Bootstrapping essential platform components:
  - Ingress controllers (NGINX)
  - cert-manager (TLS certificate management)
  - Observability stack (Prometheus, Grafana, Loki, Promtail)
  - GitOps engine (Argo CD)
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

2. **Deploy infrastructure**:

   ```bash
   cd iac/envs/local
   tofu init
   tofu plan
   tofu apply
   ```

3. **Access services**:
   - Grafana: http://localhost:30080 (via ingress) or port-forward
   - Argo CD: http://localhost:30080 (via ingress) or port-forward

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

### Observability Module

Complete observability stack:

- **Prometheus**: Metrics collection and storage
- **Grafana**: Visualization and dashboards
- **Loki**: Log aggregation
- **Promtail**: Log collection agent

### Argo CD Module

GitOps deployment engine:

- Argo CD installation
- High availability configuration
- Ingress and TLS support

## Environments

### Local

- Uses `kind` for local Kubernetes cluster
- NodePort services for ingress (ports 30080/30443)
- Reduced resource requirements
- No TLS (for simplicity)
- Uses LocalStack with S3 for object storage (same scalable Loki configuration as prod)

### Prod

- Maximum availability and redundancy
- Largest resource allocations
- Production-grade security

See [docs/environments.md](docs/environments.md) for detailed environment documentation.

## Prerequisites

- OpenTofu (Terraform-compatible) >= 1.5.0
- Kubernetes provider >= 2.23
- Helm provider >= 2.11
- kubectl (for local development)
- kind (for local development)
- Docker and docker-compose (for LocalStack in local environment)
- AWS CLI (optional, for LocalStack bucket creation)

## Local Development Setup

The local environment uses LocalStack to provide S3-compatible object storage, allowing you to use the same scalable Loki configuration as production.

### Quick Start

Set up the complete local development environment with one command:

```bash
make local-setup
```

This will:

- Start LocalStack with S3
- Create the S3 bucket for Loki (`loki-logs-local`)
- Create the kind Kubernetes cluster
- Configure everything to work together

### Manual Setup

If you prefer to set up components individually:

1. **Start LocalStack:**

   ```bash
   make localstack-up
   ```

   This will start LocalStack and create the S3 bucket for Loki.

2. **Verify LocalStack is running:**

   ```bash
   make localstack-status
   ```

3. **Create the kind cluster:**

   ```bash
   make kind-up
   ```

   The kind configuration includes `host.docker.internal` mapping to allow Kubernetes pods to access LocalStack running on the host.

4. **Deploy infrastructure:**
   ```bash
   cd iac/envs/local
   make init
   make plan
   make apply
   ```

### Stopping Local Services

To stop all local services:

```bash
make local-teardown
```

Or stop individual services:

```bash
make localstack-down  # Stop LocalStack
make kind-down        # Delete kind cluster
```

You can add more services to `docker-compose.yml` as needed for local development (databases, message queues, etc.).

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

- `make local-setup` - Set up complete local environment (LocalStack + Kind)
- `make local-teardown` - Tear down local environment
- `make localstack-up` - Start LocalStack
- `make localstack-down` - Stop LocalStack
- `make localstack-status` - Check LocalStack status
- `make localstack-loki-bucket` - Create S3 bucket for Loki
- `make kind-up` - Create kind cluster
- `make kind-down` - Delete kind cluster
- `make kind-status` - Check kind cluster status

### Environment Variables

- `ENV` - Terraform environment (default: `local`)
- `CLUSTER_NAME` - Kind cluster name (default: `local`)
- `BUCKET_NAME` - S3 bucket name for Loki (default: `loki-logs-local`)

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

- Environment variables: `export TF_VAR_letsencrypt_email="admin@example.com"`
- Secret managers (AWS Secrets Manager, Azure Key Vault, etc.)
- CI/CD pipeline variables
- `terraform.tfvars` files (excluded from git via `.gitignore`)

### Environment Variables

Set environment-specific variables:

```bash
export TF_VAR_letsencrypt_email="admin@example.com"
export TF_VAR_grafana_host="grafana.prod.example.com"
export TF_VAR_argocd_host="argocd.prod.example.com"
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
