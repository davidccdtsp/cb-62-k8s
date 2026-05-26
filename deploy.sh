#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="monitoring"
APPS_NAMESPACE="apps"
LANGFUSE_NAMESPACE="langfuse"
KUBECTL="minikube kubectl --"

echo "==> Creando namespaces..."
$KUBECTL create namespace "$NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL apply -f backend/k8s/namespace.yaml
$KUBECTL create namespace "$LANGFUSE_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -

echo "==> Añadiendo repos Helm..."
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo add jetstack https://charts.jetstack.io
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo add langfuse https://langfuse.github.io/langfuse-k8s
helm repo update grafana grafana-community jetstack langfuse

echo "==> Construyendo imagen del backend..."
minikube image build -t backend:latest backend/

echo "==> Desplegando cert-manager (prerequisito del OTel Operator)..."
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait --timeout=120s

echo "==> Desplegando OpenTelemetry Operator..."
helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
  -f otel-operator/values.yaml \
  -n "$NAMESPACE" \
  --wait --timeout=120s

echo "==> Desplegando Grafana..."
helm upgrade --install grafana oci://ghcr.io/grafana-community/helm-charts/grafana \
  -f grafana/values.yaml -n "$NAMESPACE"

echo "==> Desplegando Mimir..."
helm upgrade --install mimir oci://ghcr.io/grafana/helm-charts/mimir-distributed \
  -n "$NAMESPACE"

echo "==> Desplegando Loki..."
helm upgrade --install loki grafana-community/loki \
  -f loki/values.yaml -n "$NAMESPACE"

echo "==> Desplegando Tempo..."
helm upgrade --install tempo grafana/tempo-distributed \
  -f tempo/microservices-tempo-values.yaml -n "$NAMESPACE"
$KUBECTL apply -f tempo/microservices-extras.yaml -n "$NAMESPACE"

echo "==> Aplicando Secret del receiver externo de Alloy..."
$KUBECTL apply -f alloy/external-secret.yaml

echo "==> Desplegando Alloy..."
helm upgrade --install alloy grafana/alloy \
  -f alloy/values.yaml -n "$NAMESPACE"

echo "==> Aplicando NodePort externo de Alloy..."
$KUBECTL apply -f alloy/nodeport-external.yaml

echo "==> Aplicando Instrumentation CR y desplegando backend..."
$KUBECTL apply -f otel-operator/instrumentation.yaml
$KUBECTL apply -f backend/k8s/langfuse-secret.yaml
$KUBECTL apply -f backend/k8s/deployment.yaml
$KUBECTL apply -f backend/k8s/service.yaml

echo "==> Desplegando Langfuse..."
$KUBECTL apply -f langfuse/secret.yaml -n "$LANGFUSE_NAMESPACE"
helm upgrade --install langfuse langfuse/langfuse \
  -f langfuse/values.yaml \
  -n "$LANGFUSE_NAMESPACE"

echo "==> Aplicando NodePort externo de Langfuse..."
$KUBECTL apply -f langfuse/nodeport.yaml

MINIKUBE_IP=$(minikube ip 2>/dev/null || echo "<minikube-ip>")

echo ""
echo "Stack desplegado. Comprueba el estado con:"
echo "  minikube kubectl -- get pods -n $NAMESPACE"
echo "  minikube kubectl -- get pods -n $APPS_NAMESPACE"
echo "  minikube kubectl -- get pods -n $LANGFUSE_NAMESPACE"
echo "  docker compose -f external/docker-compose.yml ps"
echo ""
echo "Backend en cluster (port-forward):"
echo "  minikube kubectl -- port-forward svc/backend 8000 -n $APPS_NAMESPACE"
echo "  Abrir: http://localhost:8000/docs"
echo ""
echo "Backend externo (Docker Compose):"
echo "  http://localhost/docs"
echo ""
echo "Grafana (port-forward):"
echo "  minikube kubectl -- port-forward svc/grafana 3000:80 -n $NAMESPACE"
echo "  Abrir: http://localhost:3000  (admin / admin)"
echo ""
echo "Langfuse (port-forward):"
echo "  minikube kubectl -- port-forward svc/langfuse-web 3001:3000 -n $LANGFUSE_NAMESPACE"
echo "  Abrir: http://localhost:3001  (admin@admin.com / admin)"
echo ""
echo "Endpoints de telemetría (NodePorts — IP: ${MINIKUBE_IP}):"
echo "  Alloy receiver externo : http://${MINIKUBE_IP}:30320"
echo "  Langfuse               : http://${MINIKUBE_IP}:30900"
echo ""
echo "Backend externo (Docker Compose — arranque manual):"
echo "  Edita external/.env y ajusta CLUSTER_ALLOY_ENDPOINT y LANGFUSE_HOST"
echo "  con la IP del nodo: ${MINIKUBE_IP}"
echo "  Luego ejecuta:"
echo "    docker compose -f external/docker-compose.yml up --build -d"
