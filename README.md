# Grafana LGTM + Langfuse en K8S

Stack de monitorización grafana LGTM sobre Kubernetes


## Prerrequisitos

- Kubernetes local en ejecución: [minikube](https://minikube.sigs.k8s.io/) o [kind](https://kind.sigs.k8s.io/)
- `helm` >= 3.x
- `docker` (para construir la imagen del backend)

> `kubectl` no es necesario como binario independiente si se usa minikube — `minikube kubectl --` internamente.

---

## Arquitectura

```
┌─────────────────────────────────────────────────────────┐
│  namespace: apps                                        │
│  ┌─────────────────────────────────────────────────┐    │
│  │  backend (FastAPI)                              │    │
│  │  OTel Operator inyecta el agente Python         │    │
│  └──────┬──────────────────────────────────────────┘    │
│         │ OTLP HTTP :4318 (trazas + métricas OTLP)      │
└─────────┼───────────────────────────────────────────────┘
          │
┌─────────┼───────────────────────────────────────────────┐
│  namespace: monitoring                                  │
│         │                                               │
│  ┌──────▼──────────────────────────────────────┐        │
│  │            Grafana Alloy                    │        │
│  │  ┌──────────┐ ┌──────────┐ ┌─────────────┐  │        │
│  │  │ Métricas │ │   Logs   │ │    Trazas   │  │        │
│  │  │ (scrape) │ │(k8s API) │ │ (OTLP recv) │  │        │
│  └──┼──────────┼─┼──────────┼─┼─────────────┼──┘        │
│     │          │ │          │ │             │           │
│     ▼          │ ▼          │ ▼             │           │
│   Mimir        │ Loki       │ Tempo         │           │
│  (métricas)    │ (logs)     │ (trazas)      │           │
│     ▲──────────┘ ▲──────────┘               │           │
│                                             │           │
│  ┌──────────────────────────────────────────┘           │
│  │  Grafana (datasources + dashboard provisionados)     │
└──┴──────────────────────────────────────────────────────┘
```

| Componente | Función |
|---|---|
| **Grafana** | UI de visualización; datasources y dashboard provisionados vía `values.yaml` |
| **Mimir** | Backend de métricas Prometheus-compatible (remote write) |
| **Loki** | Backend de logs |
| **Tempo** | Backend de trazas distribuidas |
| **Alloy** | Collector unificado: scrape métricas, recoge logs de pods, recibe trazas OTLP |
| **OTel Operator** | Inyecta el agente OpenTelemetry automáticamente en los pods del namespace `apps` |
| **backend** | Servicio FastAPI de demo; instrumentado sin cambios de código |
| **Langfuse** | Plataforma de observabilidad para LLMs; trazas, métricas y evaluaciones de modelos |

---

## Despliegue

```bash
./deploy.sh
```

El script gestiona el orden correcto de dependencias y despliega todo el stack en el cluster. El backend externo (Docker Compose) **no se arranca automáticamente** — una vez finalizado el script, arráncalo manualmente siguiendo los pasos de la sección [Servicio externo (Docker Compose)](#servicio-externo-docker-compose).

Para un despliegue **paso a paso**:

### Desplieuge paso a paso

```bash
# 1. Namespaces
kubectl create namespace monitoring
kubectl apply -f backend/k8s/namespace.yaml   # crea namespace "apps"

# 2. Repos Helm
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo add jetstack https://charts.jetstack.io
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo add langfuse https://langfuse.github.io/langfuse-k8s
helm repo update

# 3. cert-manager (prerequisito del OTel Operator)
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --set crds.enabled=true
kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s

# 4. OpenTelemetry Operator
helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
  -f otel-operator/values.yaml -n monitoring
kubectl rollout status deployment/opentelemetry-operator-controller-manager \
  -n monitoring --timeout=120s

# 5. Stack de observabilidad
helm upgrade --install grafana oci://ghcr.io/grafana-community/helm-charts/grafana \
  -f grafana/values.yaml -n monitoring
helm upgrade --install mimir oci://ghcr.io/grafana/helm-charts/mimir-distributed \
  -n monitoring
helm upgrade --install loki grafana-community/loki -f loki/values.yaml -n monitoring
helm upgrade --install tempo grafana/tempo-distributed \
  -f tempo/microservices-tempo-values.yaml -n monitoring
kubectl apply -f tempo/microservices-extras.yaml -n monitoring
helm upgrade --install alloy grafana/alloy -f alloy/values.yaml -n monitoring

# 6. Backend de demo
docker build -t backend:latest backend/
kubectl apply -f otel-operator/instrumentation.yaml
kubectl apply -f backend/k8s/deployment.yaml
kubectl apply -f backend/k8s/service.yaml

# 7. Langfuse (edita langfuse/secret.yaml antes con credenciales reales)
kubectl create namespace langfuse --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f langfuse/secret.yaml -n langfuse
helm upgrade --install langfuse langfuse/langfuse \
  -f langfuse/values.yaml -n langfuse

# 8. Servicio externo (Docker Compose)
# Recursos K8s en el cluster: Secret del bearer token y NodePort del receiver externo
minikube kubectl -- apply -f alloy/external-secret.yaml -n monitoring
minikube kubectl -- apply -f alloy/nodeport-external.yaml -n monitoring

# Configurar el entorno del Compose
cd external
cp .env.example .env
# Editar .env — valores mínimos necesarios:
#   ALLOY_BEARER_TOKEN=poc-alloy-external-token   # debe coincidir con external-secret.yaml
#   CLUSTER_ALLOY_ENDPOINT=http://$(minikube ip):30320
#   LANGFUSE_PUBLIC_KEY=pk-lf-poc00000000000000000000000001
#   LANGFUSE_SECRET_KEY=sk-lf-poc00000000000000000000000001
#   LANGFUSE_HOST=http://$(minikube ip):30900
cd ..

# Construir y arrancar el stack externo
docker compose -f external/docker-compose.yml up --build -d
```

## Uso del stack

### 1. Acceder a Grafana

```bash
kubectl port-forward svc/grafana 3000:80 -n monitoring
```

Abrir [http://localhost:3000](http://localhost:3000) — credenciales por defecto: `admin` / `admin`.

Los datasources **Mimir**, **Loki** y **Tempo** ya están provisionados automáticamente.

---

### 2. Generar métricas, logs y trazas

#### Backend en el cluster (namespace `apps`)

El backend de demo (FastAPI) está instrumentado automáticamente con el OTel Operator. Cualquier petición HTTP genera los tres signals a la vez.

Necesario port forward para exponer el servicio:

```bash
minikube kubectl -- port-forward svc/backend 8000 -n apps
```

La generación de tráfico es imprescindible para que los dashboards en Grafana se pueblen. Los datos pueden generarse a través del Swagger en [http://localhost:8000/docs](http://localhost:8000/docs):

```bash
# Listar productos (GET normal)
curl http://localhost:8000/products

# Obtener producto concreto
curl http://localhost:8000/products/1

# Crear un pedido (POST)
curl -X POST http://localhost:8000/orders \
  -H "Content-Type: application/json" \
  -d '{"product_id": 1, "quantity": 2}'

# Provocar un 404 (producto inexistente → genera log WARNING y traza con error)
curl http://localhost:8000/products/99

# Listar pedidos y usuarios
curl http://localhost:8000/orders
curl http://localhost:8000/users

# Endpoint LLM — registra traza completa en Langfuse (retrieval + generation)
curl -X POST http://localhost:8000/agent/run \
  -H "Content-Type: application/json" \
  -d '{"query": "gadgets under 50"}'
```

Para generar carga continua:

```bash
while true; do
  curl -s http://localhost:8000/products > /dev/null
  curl -s http://localhost:8000/orders > /dev/null
  curl -s http://localhost:8000/products/99 > /dev/null  # genera errores 404
  sleep 1
done
```

#### Backend externo (Docker Compose)

El backend externo corre detrás de nginx en el puerto `80`. No requiere port-forward — es accesible directamente desde el host. Telemetría disponible en el dashboard **Backend — Observabilidad (Externo)** (uid: `backend-ext-obs`) y en **LLM Traces — Langfuse / ClickHouse** (uid: `llm-traces-clickhouse`).

```bash
# Listar productos
curl http://localhost/products

# Crear un pedido
curl -X POST http://localhost/orders \
  -H "Content-Type: application/json" \
  -d '{"product_id": 1, "quantity": 2}'

# Provocar un 404
curl http://localhost/products/99

# Endpoint LLM — registra traza en Langfuse con modelo, tokens y latencia
curl -X POST http://localhost/agent/run \
  -H "Content-Type: application/json" \
  -d '{"query": "gadgets under 50"}'
```

Para generar carga continua sobre el backend externo:

```bash
while true; do
  curl -s http://localhost/products > /dev/null
  curl -s http://localhost/orders > /dev/null
  curl -s http://localhost/products/99 > /dev/null
  curl -s -X POST http://localhost/agent/run \
    -H "Content-Type: application/json" \
    -d '{"query": "cheap gadgets"}' > /dev/null
  sleep 2
done
```

> Las métricas del backend externo se distinguen por `job="external/backend"` frente a `job="apps/backend"` del backend en cluster. Ambos pueden consultarse simultáneamente en Grafana.

---

### 3. Ver telemetría en Grafana

#### Dashboard provisionado — Backend Observabilidad

Se integran por dfecto dos **Dashboards**: **Backend — Observabilidad** y **Agent Trace Dashboard** accesibles desde el panel lateral.

En el menú lateral ve a **Dashboards** y abre **"Backend — Observabilidad"**.

El dashboard **Backend — Observabilidad** incluye:

| Panel | Datasource | Qué muestra |
|---|---|---|
| Logs del backend | Loki | stdout/stderr del pod, incluyendo warnings de productos no encontrados |
| Request Rate (req/s) | Mimir | Tasa de peticiones por ruta HTTP |
| Latencia p99 | Mimir | Percentil 99 de duración de request por ruta |
| Tasa de errores 5xx | Mimir | Ratio de respuestas con error de servidor |

> Las métricas HTTP provienen del SDK OTel Python (`http_server_duration_milliseconds`),
> enviadas vía OTLP a Alloy y escritas en Mimir. El endpoint `/agent/run` además registra
> trazas de agente LLM en Langfuse.

El dashboard **Agent Trace Dashboard** incluye:

| Panel | Datasource | Qué muestra |
|---|---|---|
| Logs del backend | Loki | stdout/stderr del pod, incluyendo warnings de productos no encontrados |
| Request Rate (req/s) | Mimir | Tasa de peticiones por ruta HTTP |
| Latencia p99 | Mimir | Percentil 99 de duración de request por ruta |
| Tasa de errores 5xx | Mimir | Ratio de respuestas con error de servidor |

> Las métricas HTTP provienen del SDK OTel Python (`http_server_duration_milliseconds`),
> enviadas vía OTLP a Alloy y escritas en Mimir. El endpoint `/agent/run` además registra
> trazas de agente LLM en Langfuse.

#### Explorar logs (Loki)

**Explore** → datasource **Loki** → ejecutar la query:

```logql
{namespace="apps"}
```

Filtros útiles:

```logql
# Solo warnings y errores
{namespace="apps"} |= "WARNING" or |= "ERROR"

# Logs de un pod concreto
{namespace="apps", pod="backend-<hash>"}

# Buscar texto libre
{namespace="apps"} |= "product not found"
```

#### Explorar trazas (Tempo)

**Explore** → datasource **Tempo** → usar **Search** con:
- Service name: `backend`
- Span name: p. ej. `GET /products`
- Duration: filtrar por latencia mínima

Al abrir una traza puedes navegar de trazas → logs (correlación automática vía TraceID) y de trazas → métricas.

#### Explorar métricas (Mimir)

**Explore** → datasource **Mimir** → queries útiles:

```promql
# Tasa de peticiones por ruta
sum(rate(http_server_duration_milliseconds_count{job="apps/backend"}[2m])) by (http_target)

# Latencia p99 por ruta
histogram_quantile(0.99, sum(rate(http_server_duration_milliseconds_bucket{job="apps/backend"}[2m])) by (le, http_target))

# Tasa de errores 5xx
sum(rate(http_server_duration_milliseconds_count{job="apps/backend", http_status_code=~"5.."}[2m]))
  / sum(rate(http_server_duration_milliseconds_count{job="apps/backend"}[2m]))
```

---

### 4. Langfuse

Langfuse es la plataforma de observabilidad para LLMs del stack. Se despliega en su propio namespace (`langfuse`) con PostgreSQL, ClickHouse, Redis y MinIO incluidos.

#### Prerrequisito: configurar el secret

Antes del primer despliegue editar `langfuse/secret.yaml` y substituir los valores de ejemplo por credenciales reales:

```bash
# Genera valores seguros:
openssl rand -hex 32   # para encryption-key
openssl rand -hex 16   # para salt, nextauth-secret, passwords
```

El secret **debe existir en el namespace antes** de que el chart arranque — `deploy.sh` lo aplica automáticamente.

Además, actualiza el campo `secureJsonData.password` del datasource **Langfuse ClickHouse** en `grafana/values.yaml` con el mismo valor que hayas puesto en `langfuse/secret.yaml` para `clickhouse-password`:

```yaml
# grafana/values.yaml → datasources → Langfuse ClickHouse
secureJsonData:
  password: "tu-clickhouse-password-real"
```

#### Bootstrap automático

En el primer arranque Langfuse inicializa automáticamente la organización, el proyecto y las credenciales usando variables de entorno configuradas en `langfuse/values.yaml`:

| Recurso | Valor |
|---|---|
| Organización | `poc-company` |
| Proyecto | `poc-project` |
| Usuario | `admin@admin.com` / `admin` |
| Public key | `pk-lf-poc00000000000000000000000001` |
| Secret key | `sk-lf-poc00000000000000000000000001` |

Las mismas claves están preconfiguradas en `backend/k8s/langfuse-secret.yaml`, por lo que el backend queda conectado a Langfuse sin ningún paso manual.

#### Acceder a la UI

```bash
minikube kubectl -- port-forward svc/langfuse 3001:3000 -n langfuse
```

Abrir [http://localhost:3001](http://localhost:3001) e iniciar sesión con `admin@admin.com` / `admin`.

#### Endpoint del agente

`POST /agent/run` simula un agente de recomendación de productos con dos pasos internos:

| Paso | Qué hace | Qué registra en Langfuse |
|---|---|---|
| **retrieval** | Busca productos relevantes en el catálogo según la query | Span con matches encontrados |
| **generation** | Genera una respuesta simulando un LLM (`gpt-4o-mini`) | Generation con prompt, completion y tokens |

```bash
curl -X POST http://localhost:8000/agent/run \
  -H "Content-Type: application/json" \
  -d '{"query": "What products are available under $20?"}'
```

Cada llamada genera automáticamente trazas OTel (capturadas por Tempo), logs (capturados por Loki) y métricas HTTP (capturadas por Mimir), además del trace completo en Langfuse.

#### Comprobar estado

```bash
minikube kubectl -- get pods -n langfuse
```

Los componentes que deben estar `Running` son: `langfuse-web`, `langfuse-worker`, `postgresql`, `clickhouse`, `redis` y `langfuse-minio`.

---

### 5. Verificar el estado del stack

```bash
# Todos los pods del stack de observabilidad
minikube kubectl -- get pods -n monitoring

# Pod del backend instrumentado
minikube kubectl -- get pods -n apps

# Pods de Langfuse
minikube kubectl -- get pods -n langfuse

# Logs de Alloy (ver errores de pipeline)
minikube kubectl -- logs -n monitoring -l app.kubernetes.io/name=alloy --tail=50
```

---

## Servicio externo (Docker Compose)

Simula un servicio desplegado fuera del cluster. El backend corre en Docker Compose junto con un Alloy local que actúa como agente de telemetría, autenticándose contra el cluster mediante Bearer token.

> **Antes de ejecutar `deploy.sh`:** edita `alloy/external-secret.yaml` y sustituye `change-me-generate-a-strong-token` por un token real. El script aplica automáticamente ese Secret antes de desplegar Alloy, así como los NodePorts necesarios (30320 para el receiver OTLP externo de Alloy, 30900 para Langfuse).

### 1. Configurar el entorno

```bash
cd external
cp .env.example .env
```

Editar `.env` con los valores reales:

| Variable | Valor |
|---|---|
| `ALLOY_BEARER_TOKEN` | El mismo token que en `alloy/external-secret.yaml` |
| `CLUSTER_ALLOY_ENDPOINT` | `http://$(minikube ip):30320` |
| `LANGFUSE_PUBLIC_KEY` | `pk-lf-poc00000000000000000000000001` |
| `LANGFUSE_SECRET_KEY` | `sk-lf-poc00000000000000000000000001` |
| `LANGFUSE_HOST` | `http://$(minikube ip):30900` |

Obtener la IP del nodo:

```bash
minikube ip
```

### 2. Arrancar el Compose

```bash
cd external
docker compose up --build
```

El backend queda disponible en `http://localhost` a través de nginx. Swagger en `http://localhost/docs` (sin autenticación).

### 3. Generar tráfico

```bash
# Peticiones estándar a través del API Gateway
curl http://localhost/products
curl http://localhost/orders
curl -X POST http://localhost/orders \
  -H "Content-Type: application/json" \
  -d '{"product_id": 1, "quantity": 2}'

# Endpoint LLM — registra traza en Langfuse
curl -X POST http://localhost/agent/run \
  -H "Content-Type: application/json" \
  -d '{"query": "gadgets under 50"}'
```

### 4. Ver telemetría en Grafana

Dashboard provisionado: **Backend — Observabilidad (Externo)** (uid: `backend-ext-obs`).

Las queries usan `job="external/backend"` para distinguir la telemetría del servicio externo de la del servicio interno (`job="apps/backend"`). Ambos dashboards pueden consultarse a la vez.

### Arquitectura del flujo externo

```
[Docker Compose]                               [Cluster K8s — minikube]
  nginx :80
    └─► backend (opentelemetry-instrument)
          │ OTLP (red privada Docker)
          ▼
        Alloy ──── Bearer token ────────────► Alloy :30320 (NodePort)
                                                   │ (valida token)
                                                   ├─► Tempo   (trazas)
                                                   ├─► Mimir   (métricas)
                                                   └─► Loki    (logs OTLP)
  backend ──── SDK Langfuse ──────────────────► Langfuse :30900 (NodePort)
```

---

## Configuracion

Los datasources (Mimir, Loki, Tempo) se provisionan automáticamente al desplegar Grafana
a través de `grafana/values.yaml`. No es necesaria ninguna configuración manual adicional.

El dashboard **"Backend — Observabilidad"** también se provisiona automáticamente desde
`grafana/values.yaml` (UID: `backend-obs`).

Consultar [docs/alloy-pipelines.md](docs/alloy-pipelines.md) para la descripción detallada
de los pipelines de Alloy y los endpoints del stack.

## Solución de problemas

### `kubectl: command not found` al ejecutar `deploy.sh`

`kubectl` no está en el PATH del sistema. El script ya usa `minikube kubectl --` internamente, pero si ejecutas comandos manualmente usa siempre:

```bash
minikube kubectl -- <comando>
```

---

### Grafana en `Init:CrashLoopBackOff`

El init container `init-chown-data` falla con `Permission denied` al intentar cambiar el propietario de subdirectorios del PVC:

```
chown: /var/lib/grafana/png: Permission denied
chown: /var/lib/grafana/csv: Permission denied
```

El `fsGroup: 472` del pod ya garantiza los permisos correctos sobre el volumen. Desactiva el init container en `grafana/values.yaml`:

```yaml
initChownData:
  enabled: false
```

Luego actualiza el release:

```bash
helm upgrade grafana oci://ghcr.io/grafana-community/helm-charts/grafana \
  -f grafana/values.yaml -n monitoring
```

---

### El script falla al esperar al OTel Operator

`kubectl rollout status` se ejecutaba antes de que el Deployment existiera en el API. Está corregido en `deploy.sh` usando `--wait --timeout=120s` directamente en el `helm upgrade --install`, que bloquea hasta que todos los pods del release estén listos.

---

### Dashboard de Grafana muestra `no org id` en los paneles de Mimir

Mimir opera en modo multi-tenant y exige la cabecera `X-Scope-OrgID` en cada petición. El datasource de Grafana la envía vía `secureJsonData`, pero Grafana solo aplica ese campo en la creación inicial del datasource — las actualizaciones posteriores no lo sobreescriben.

La solución es forzar que Grafana borre y recree el datasource en cada arranque usando `deleteDatasources` en `grafana/values.yaml`:

```yaml
datasources:
  datasources.yaml:
    apiVersion: 1
    deleteDatasources:
      - name: Mimir
        orgId: 1
    datasources:
      - name: Mimir
        ...
        jsonData:
          httpHeaderName1: "X-Scope-OrgID"
        secureJsonData:
          httpHeaderValue1: "1"
```

Aplica el cambio:

```bash
helm upgrade grafana oci://ghcr.io/grafana-community/helm-charts/grafana \
  -f grafana/values.yaml -n monitoring
```

> **Tenant actual:** todas las señales (métricas, logs, trazas) se almacenan bajo el tenant `1`,
> enviado por Alloy y configurado en los datasources de Grafana mediante la cabecera `X-Scope-OrgID`.
>
> **Cuando se trabaje con múltiples tenants:** cada servicio deberá enviar su propio
> `X-Scope-OrgID` en las peticiones OTLP a Alloy (o Alloy deberá enriquecerlo según el
> namespace/label del pod). En Grafana habrá que crear un datasource por tenant, o
> usar variables de dashboard que parametricen la cabecera.

---

### Loki: `too many unhealthy instances in the ring`

Varios pods de Loki quedan en `Pending` por falta de recursos en minikube. Con réplicas insuficientes el ring queda incompleto y Loki rechaza todas las queries.

Reducir réplicas y factor de replicación a 1 en `loki/values.yaml`:

```yaml
loki:
  commonConfig:
    replication_factor: 1

backend:
  replicas: 1
read:
  replicas: 1
write:
  replicas: 1
```

```bash
helm upgrade loki grafana-community/loki -f loki/values.yaml -n monitoring
```

> En producción se mantienen 3 réplicas de write y replication_factor 3 para durabilidad.
> En minikube se reduce a 1 por limitación de recursos.

---

### Backend en `ImagePullBackOff` o `ErrImagePull`

La imagen `backend:latest` no existe dentro de minikube. Se construyó en el Docker del host pero minikube tiene su propio daemon. Solución:

```bash
minikube image build -t backend:latest backend/
minikube kubectl -- rollout restart deployment/backend -n apps
```

El `deploy.sh` ya usa `minikube image build` automáticamente. Si aun así el pod falla, verifica que la imagen está cargada:

```bash
minikube image ls | grep backend
```

---

## Desinstalar

```bash
helm uninstall grafana -n monitoring
helm uninstall mimir -n monitoring
helm uninstall loki -n monitoring
helm uninstall tempo -n monitoring
helm uninstall alloy -n monitoring
helm uninstall langfuse -n langfuse
minikube kubectl -- delete namespace langfuse
```

## Recursos

* [Mimir distributed](https://github.com/grafana/mimir/tree/main/operations/helm/charts/mimir-distributed)
* [Loki](https://github.com/grafana-community/helm-charts/tree/main/charts/loki)
* [Tempo distributed](https://github.com/grafana/tempo/tree/main/operations/helm/charts/tempo-distributed)
* [Grafana Alloy](https://grafana.com/docs/alloy/latest/)


## Fuentes

* [Grafana instrument an application](https://grafana.com/docs/opentelemetry/instrument/)
