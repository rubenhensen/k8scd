# MariaDB Operator

This folder contains the MariaDB operator installation for the cluster.

## Components

- **operator-crds-helm.yaml**: Installs MariaDB operator CRDs (v25.10.4)
- **operator-helm.yaml**: Installs MariaDB operator (v25.10.4)
- **kustomization.yaml**: Kustomize manifest for organizing resources

## Configuration

- **Namespace**: `mariadb-system`
- **Chart Repository**: https://mariadb-operator.github.io/mariadb-operator
- **Chart Version**: 25.10.4
- **Metrics**: Enabled (ServiceMonitor disabled - Prometheus Operator not installed)

## Managed By

ArgoCD Application: `mariadb-operator-install` (defined in `/apps/templates/mariadb-operator-folder.yaml`)

## Usage

MariaDB instances are created using the `MariaDB` CRD in application namespaces.
See `/mbgwp/mariadb-cluster.yaml` for an example.
