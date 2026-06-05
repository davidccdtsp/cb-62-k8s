#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="monitoring"
APPS_NAMESPACE="apps"
LANGFUSE_NAMESPACE="langfuse"
KEYCLOAK_NAMESPACE="keycloak"
KUBECTL="minikube kubectl --"
VERBOSE=false
BACKENDS="all"

# ── Colores ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Uso: $(basename "$0") [OPCIONES]

Despliega el stack de observabilidad LGTM + Keycloak + Langfuse + backends en minikube.

OPCIONES:
  -h, --help              Muestra esta ayuda y sale
  -v, --verbose           Muestra todos los logs de despliegue
  --backends LISTA        Backends a desplegar (por defecto: all)
                          Valores: python | nest | all | none
                          Se pueden combinar con comas: python,nest

EJEMPLOS:
  $(basename "$0")                       Despliegue completo (silencioso)
  $(basename "$0") -v                    Despliegue completo con logs
  $(basename "$0") --backends python     Solo backend Python
  $(basename "$0") --backends nest       Solo backend NestJS
  $(basename "$0") --backends none       Infraestructura sin backends
  $(basename "$0") -v --backends python  Backend Python con logs detallados
EOF
}

step()      { echo -e "${BOLD}${BLUE}▶${NC} $*"; }
done_step() { echo -e "  ${GREEN}✓${NC} $*"; }

q() {
  if $VERBOSE; then
    "$@"
  else
    "$@" >/dev/null 2>&1
  fi
}

# Versión para pipes: el output siempre se suprime en modo silencioso
apply_namespace() {
  local ns="$1"
  if $VERBOSE; then
    $KUBECTL create namespace "$ns" --dry-run=client -o yaml | $KUBECTL apply -f -
  else
    $KUBECTL create namespace "$ns" --dry-run=client -o yaml 2>/dev/null \
      | $KUBECTL apply -f - >/dev/null 2>&1
  fi
}

want_python() {
  case "$BACKENDS" in
    none) return 1 ;;
    all|*python*) return 0 ;;
    *) return 1 ;;
  esac
}

want_nest() {
  case "$BACKENDS" in
    none) return 1 ;;
    all|*nest*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Argumentos ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      usage; exit 0 ;;
    -v|--verbose)
      VERBOSE=true; shift ;;
    --backends)
      [[ $# -gt 1 ]] || { echo "Error: --backends requiere un valor" >&2; exit 1; }
      BACKENDS="$2"; shift 2 ;;
    *)
      echo "Opción desconocida: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

MINIKUBE_IP=$(minikube ip 2>/dev/null || echo "<minikube-ip>")

# ── Despliegue ────────────────────────────────────────────────────────────────

step "Habilitando addon Ingress..."
q minikube addons enable ingress || true
done_step "Ingress"

step "Creando namespaces..."
apply_namespace "$NAMESPACE"
q $KUBECTL apply -f backend/k8s/namespace.yaml
apply_namespace "$LANGFUSE_NAMESPACE"
apply_namespace "$KEYCLOAK_NAMESPACE"
done_step "Namespaces"

step "Actualizando repositorios Helm..."
q helm repo add grafana https://grafana.github.io/helm-charts
q helm repo add grafana-community https://grafana-community.github.io/helm-charts
q helm repo add jetstack https://charts.jetstack.io
q helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
q helm repo add langfuse https://langfuse.github.io/langfuse-k8s
q helm repo update grafana grafana-community jetstack langfuse
done_step "Repos Helm"

if want_python || want_nest; then
  step "Construyendo imágenes de backends..."
  want_python && q minikube image build -t backend:latest backend/
  want_nest   && q minikube image build -t backend-nest:latest backend-nest/
  done_step "Imágenes"
fi

step "Desplegando cert-manager..."
q helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait --timeout=120s
done_step "cert-manager"

step "Desplegando OpenTelemetry Operator..."
q helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
  -f otel-operator/values.yaml \
  -n "$NAMESPACE" \
  --wait --timeout=120s
done_step "OpenTelemetry Operator"

step "Desplegando Grafana..."
q helm upgrade --install grafana oci://ghcr.io/grafana-community/helm-charts/grafana \
  -f grafana/values.yaml -n "$NAMESPACE"
done_step "Grafana"

step "Desplegando Mimir..."
q helm upgrade --install mimir oci://ghcr.io/grafana/helm-charts/mimir-distributed \
  -n "$NAMESPACE"
done_step "Mimir"

step "Desplegando Loki..."
q helm upgrade --install loki grafana-community/loki \
  -f loki/values.yaml -n "$NAMESPACE"
done_step "Loki"

step "Desplegando Tempo..."
q helm upgrade --install tempo grafana/tempo-distributed \
  -f tempo/microservices-tempo-values.yaml -n "$NAMESPACE"
q $KUBECTL apply -f tempo/microservices-extras.yaml -n "$NAMESPACE"
done_step "Tempo"

step "Desplegando Alloy..."
q $KUBECTL apply -f alloy/external-secret.yaml
q helm upgrade --install alloy grafana/alloy \
  -f alloy/values.yaml -n "$NAMESPACE"
q $KUBECTL apply -f alloy/nodeport-external.yaml
done_step "Alloy"

step "Desplegando Keycloak..."
q $KUBECTL create -f \
  https://raw.githubusercontent.com/keycloak/keycloak-quickstarts/refs/heads/main/kubernetes/keycloak.yaml \
  -n keycloak || true
if $VERBOSE; then
  wget -q -O - \
    https://raw.githubusercontent.com/keycloak/keycloak-quickstarts/refs/heads/main/kubernetes/keycloak-ingress.yaml \
    | sed "s/KEYCLOAK_HOST/keycloak.$(minikube ip).nip.io/" \
    | $KUBECTL create -f - -n keycloak || true
else
  wget -q -O - \
    https://raw.githubusercontent.com/keycloak/keycloak-quickstarts/refs/heads/main/kubernetes/keycloak-ingress.yaml \
    | sed "s/KEYCLOAK_HOST/keycloak.$(minikube ip).nip.io/" \
    | $KUBECTL create -f - -n keycloak >/dev/null 2>&1 || true
fi
done_step "Keycloak"

step "Aplicando Instrumentation CRs..."
q $KUBECTL apply -f otel-operator/instrumentation.yaml
q $KUBECTL apply -f otel-operator/instrumentation-nest.yaml
done_step "Instrumentation CRs"

if want_python; then
  step "Desplegando backend Python..."
  q $KUBECTL apply -f backend/k8s/langfuse-secret.yaml
  if $VERBOSE; then
    MINIKUBE_IP=$MINIKUBE_IP envsubst '${MINIKUBE_IP}' < backend/k8s/deployment.yaml \
      | $KUBECTL apply -f -
  else
    MINIKUBE_IP=$MINIKUBE_IP envsubst '${MINIKUBE_IP}' < backend/k8s/deployment.yaml \
      | $KUBECTL apply -f - >/dev/null 2>&1
  fi
  q $KUBECTL apply -f backend/k8s/service.yaml
  done_step "Backend Python"
fi

if want_nest; then
  step "Desplegando backend NestJS..."
  q $KUBECTL apply -f backend-nest/k8s/deployment.yaml
  q $KUBECTL apply -f backend-nest/k8s/service.yaml
  done_step "Backend NestJS"
fi

step "Desplegando Langfuse..."
q $KUBECTL apply -f langfuse/secret.yaml -n "$LANGFUSE_NAMESPACE"
q helm upgrade --install langfuse langfuse/langfuse \
  -f langfuse/values.yaml \
  -n "$LANGFUSE_NAMESPACE"
q $KUBECTL apply -f langfuse/nodeport.yaml
done_step "Langfuse"

# ── Resumen post-despliegue ───────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e " ${GREEN}${BOLD}Stack desplegado correctamente${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "VERIFICAR ESTADO"
echo "  minikube kubectl -- get pods -n $NAMESPACE"
echo "  minikube kubectl -- get pods -n $APPS_NAMESPACE"
echo "  minikube kubectl -- get pods -n $LANGFUSE_NAMESPACE"
echo "  minikube kubectl -- get pods -n $KEYCLOAK_NAMESPACE"
echo ""
echo "ACCESO A SERVICIOS  (via port-forward)"
echo ""
echo "  Grafana"
echo "    URL:     http://localhost:3000  (admin / admin)"
echo "    Comando: minikube kubectl -- port-forward svc/grafana 3000:80 -n $NAMESPACE"
echo ""
echo "  Langfuse"
echo "    URL:     http://localhost:3001  (admin@admin.com / admin)"
echo "    Comando: minikube kubectl -- port-forward svc/langfuse-web 3001:3000 -n $LANGFUSE_NAMESPACE"
echo ""
if want_python; then
  echo "  Backend Python"
  echo "    URL:     http://localhost:8100/docs"
  echo "    Comando: minikube kubectl -- port-forward svc/backend 8100:8000 -n $APPS_NAMESPACE"
  echo ""
fi
if want_nest; then
  echo "  Backend NestJS"
  echo "    URL:     http://localhost:8200/docs"
  echo "    Comando: minikube kubectl -- port-forward svc/backend-nest 8200:3000 -n $APPS_NAMESPACE"
  echo ""
fi
echo "ENDPOINTS TELEMETRÍA  (NodePorts — ${MINIKUBE_IP})"
echo "  Alloy receiver  →  http://${MINIKUBE_IP}:30320"
echo "  Langfuse        →  http://${MINIKUBE_IP}:30900"
echo "  Keycloak        →  https://keycloak.${MINIKUBE_IP}.nip.io  (admin / admin)"
echo ""
if want_python || want_nest; then
  echo "BACKENDS EXTERNOS  (Docker Compose — arranque manual)"
  if want_python; then
    echo "  Python:"
    echo "    1. Edita external/.env"
    echo "    2. docker compose -f external/docker-compose.yml up --build -d"
    echo "    3. Swagger: http://localhost/docs"
    echo ""
  fi
  if want_nest; then
    echo "  NestJS:"
    echo "    1. Edita external-nest/.env"
    echo "    2. docker compose -f external-nest/docker-compose.yml up --build -d"
    echo "    3. Swagger: http://localhost:81/docs"
    echo ""
  fi
fi
echo "Keycloak — ver sección 6 del README para configuración del realm y tokens."
echo ""
