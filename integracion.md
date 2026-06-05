# Guía de integración


Esta guía detalla la integración de diferentes componentes en un stack distribuido de monitorización Grafana con Mimir, Loki, Tempo y Alloy como colector, junto con Langfuse para trazas contra LLMs.

---

## Casos de uso

1. Servicio desplegado dentro del propio cluster.
2. Servicio desplegado fuera del cluster.

## 1. Servicio desplegado dentro del propio cluster

Monitorización integral (trazas, métricas y logs) de un servicio desplegado dentro del propio cluster. El servicio cuenta con la particularidad de realizar consultas a LLMs, esta característica implica que cierta información como pueden ser la longitud de los prompts, calidad de la respuesta, número de tokens, modelo empleado quedan fuera de las capacidades de observabilidad de la monitorización clásica. Con el fin de salvar esta carencia se integran tanto la monitorización clásica (Stack Grafana) como la específica mediante **Langfuse**. 

Estrategia de instrumentación híbrida:
1. **APM Tradicional (Application Performance Monitoring):** Se utiliza **OpenTelemetry (OTel) Operator** para auto-instrumentar el servicio sin modificar el código base. Extrae trazas HTTP, consultas a bases de datos y métricas del sistema.
2. **Trazabilidad LLM:** Se utiliza el SDK de **Langfuse** para instrumentar específicamente las llamadas al LLM.

**Flujo de Datos:**
* Los datos de OTel viajan hacia **Grafana Alloy** (el colector central), el cual los enruta hacia **Tempo** (trazas), **Mimir** (métricas) y **Loki** (logs).
* Los datos de Langfuse viajan al backend de Langfuse, el cual almacena la información en **ClickHouse**. Grafana visualiza estos datos conectándose directamente a ClickHouse como *datasource*.

---

### 1.1. Arquitectura del Stack

* **Aplicación (Python / NestJS):** Servicio de negocio que ejecuta la lógica y consume LLMs.
* **OpenTelemetry Operator:** Componente de Kubernetes que inyecta automáticamente el agente de OTel en los pods para capturar telemetría estándar (soporta Python y Node.js).
* **Grafana Alloy:** El colector (basado en OpenTelemetry y Prometheus). Recibe OTLP, hace *scraping* de métricas de pods y recolecta logs.
* **Mimir:** Base de datos de series temporales a largo plazo para almacenar **métricas**.
* **Loki:** Sistema de agregación de **logs** inspirado en Prometheus.
* **Tempo:** Backend de almacenamiento distribuido para **trazas**.
* **Langfuse + ClickHouse:** Langfuse recopila la telemetría de IA generativa y la guarda en ClickHouse. Grafana consulta ClickHouse para cruzar métricas de negocio/IA con la infraestructura.
---

### 1.2. Instalación del OTel Operator

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --namespace monitoring \
  --set "manager.collectorImage.repository=otel/opentelemetry-collector-contrib"
```

> **Nota:** Dado que Alloy ya expone endpoints OTLP (`4317` gRPC y `4318` HTTP), **no es necesario instalar un OpenTelemetry Collector adicional**. El OTel Operator es un componente opcional cuyo único propósito es inyectar automáticamente el agente de instrumentación en los pods sin tocar el código.

---

### 1.3. Backend Python

#### 1.3.1. Recurso `Instrumentation`

Define dónde debe enviar el agente los datos (el endpoint OTLP de Alloy) y qué propagadores usar. Este recurso debe crearse **antes** de desplegar la aplicación.

```yaml
# otel-operator/instrumentation.yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: backend
  namespace: apps
spec:
  exporter:
    endpoint: http://alloy.monitoring.svc.cluster.local:4318
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_traceidratio
    argument: "1"
  python: {}
```

#### 1.3.2. Anotación en el Deployment

Con el recurso `Instrumentation` creado, basta con añadir una anotación al pod:

```yaml
# backend/k8s/deployment.yaml
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-python: "true"
```

El agente inyectado captura trazas HTTP, tiempos de respuesta y metadatos del proceso sin ningún cambio en el código Python.

---

### 1.4. Backend NestJS

#### 1.4.1. Recurso `Instrumentation` para Node.js

Se crea un CR separado con `nodejs: {}` en lugar de `python: {}`:

```yaml
# otel-operator/instrumentation-nest.yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: backend-nest
  namespace: apps
spec:
  exporter:
    endpoint: http://alloy.monitoring.svc.cluster.local:4318
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_traceidratio
    argument: "1"
  nodejs: {}
```

#### 1.4.2. Anotación en el Deployment

Cuando existen **varios CRs `Instrumentation` en el mismo namespace**, el valor `"true"` es ambiguo y el operador no inyecta nada. Hay que referenciar el CR por nombre explícitamente:

```yaml
# backend-nest/k8s/deployment.yaml
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-nodejs: "backend-nest"  # ← nombre del CR, no "true"
```

> **Importante:** Si solo existe un CR en el namespace, `"true"` funciona. En cuanto hay más de uno (ej. `backend` para Python y `backend-nest` para Node.js en el mismo namespace `apps`), es obligatorio usar el nombre.

El operador inyecta automáticamente:
- Un init container que copia el agente Node.js en un volumen compartido.
- `NODE_OPTIONS=--require /otel-auto-instrumentation-nodejs/autoinstrumentation.js`
- Todas las variables `OTEL_*` (endpoint, service name, resource attributes, propagators…).

#### 1.4.3. Métricas custom con TelemetryService

El backend NestJS expone adicionalmente métricas de negocio mediante la API de OTel (`@opentelemetry/api`), aprovechando que el SDK ya está activo en el proceso:

```typescript
// backend-nest/src/shared/telemetry.service.ts
@Injectable()
export class TelemetryService {
  private readonly counter = metrics
    .getMeter('backend-nest')
    .createCounter('backend_requests_total', {
      description: 'Total requests by tenant and endpoint',
    });

  record(tenantId: string, endpoint: string): void {
    this.counter.add(1, { 'tenant.id': tenantId, endpoint });
    trace.getActiveSpan()?.setAttribute('tenant.id', tenantId);
  }
}
```

Esta métrica (`backend_requests_total`) llega a Mimir vía Alloy y permite segmentar por tenant en los dashboards.

#### 1.4.4. Diferencias en las métricas HTTP respecto a Python

El SDK OTel de Node.js (`@opentelemetry/auto-instrumentations-node`) emite métricas HTTP con **nombres de labels distintos** al SDK Python:

| Label | Python OTel | Node.js OTel |
|---|---|---|
| Ruta HTTP | `http_target` | `http_route` |
| Código de estado | `http_status_code` | `http_status_code` ✓ |
| Método HTTP | `http_method` | `http_method` ✓ |

El nombre de la métrica en sí es el mismo: `http_server_duration_milliseconds_{count,sum,bucket}`.

Las queries PromQL para los dashboards de NestJS deben usar `http_route` en lugar de `http_target`:

```promql
# Request rate por ruta (NestJS)
sum(rate(http_server_duration_milliseconds_count{job="apps/backend-nest"}[2m])) by (http_route)

# Latencia p99 por ruta (NestJS)
histogram_quantile(0.99,
  sum(rate(http_server_duration_milliseconds_bucket{job="apps/backend-nest"}[2m])) by (le, http_route)
)

# Tasa de errores 5xx (NestJS) — http_status_code sí coincide con Python
sum(rate(http_server_duration_milliseconds_count{job="apps/backend-nest", http_status_code=~"5.."}[2m]))
  / sum(rate(http_server_duration_milliseconds_count{job="apps/backend-nest"}[2m]))
```

Para referencia, el conjunto completo de labels emitidos por el SDK Node.js:

```
__name__, http_flavor, http_method, http_route, http_scheme,
http_status_code, instance, job, net_host_name, net_host_port
```

Las queries del backend Python usan `http_target` — aplicar `http_route` a esas queries produciría resultados vacíos.

---

## 1.5. Integración con Langfuse (Trazabilidad LLM)

La instrumentación OTel no captura información semántica de las llamadas a LLMs (tokens, modelo, calidad). Para eso se usa el SDK de Langfuse directamente en el código.

> **Nota:** La integración mediante el SDK de Langfuse solo es necesaria cuando se despliegan herramientas que hacen uso de LLMs fuera de un framework. Plataformas como Dify o LangGraph pueden integrarse fácilmente con Langfuse sin necesidad del SDK.


### 1.5.1. Inicialización

El SDK se configura mediante variables de entorno inyectadas como secretos de Kubernetes:

```python
from langfuse import Langfuse

_lf = Langfuse(
    public_key=os.environ.get("LANGFUSE_PUBLIC_KEY", ""),
    secret_key=os.environ.get("LANGFUSE_SECRET_KEY", ""),
    host=os.environ.get("LANGFUSE_HOST", "http://localhost:3001"),
)
```

Las credenciales se montan desde un `Secret` de Kubernetes:

```yaml
# backend/k8s/deployment.yaml
env:
  - name: LANGFUSE_PUBLIC_KEY
    valueFrom:
      secretKeyRef:
        name: langfuse-backend
        key: public-key
  - name: LANGFUSE_SECRET_KEY
    valueFrom:
      secretKeyRef:
        name: langfuse-backend
        key: secret-key
  - name: LANGFUSE_HOST
    value: "http://langfuse-web.langfuse.svc.cluster.local:3000"
```

El mismo patrón aplica al backend NestJS (mismo Secret, mismas variables de entorno en `backend-nest/k8s/deployment.yaml`).

### 1.5.2. Instrumentación de una llamada LLM

Cada ejecución del agente se registra como una traza en Langfuse con sus pasos internos (retrieval, generation):

```python
# backend/app.py
trace = _lf.trace(
    id=run_id,
    name="agent-run",
    input={"query": body.query},
    tags=["agent", "demo"],
)

# Paso de recuperación
trace.span(
    name="retrieval",
    input={"query": body.query},
    output={"matches": retrieval_result},
)

# Paso de generación (llamada al LLM)
trace.generation(
    name="product-recommendation",
    model="gpt-4o-mini",
    input=[{"role": "system", "content": system_prompt},
           {"role": "user", "content": user_prompt}],
    output=answer,
    usage={"promptTokens": prompt_tokens, "completionTokens": completion_tokens},
)

_lf.flush()
```

Langfuse almacena estos datos en ClickHouse, y Grafana los visualiza conectándose a ClickHouse como datasource.

---

### 1.6. Configuración de Pipelines en Alloy

Alloy se configura mediante bloques de componentes que se conectan entre sí referenciando sus salidas. Cada componente tiene un nombre de tipo y una etiqueta única (`TIPO "etiqueta" { ... }`), y los datos fluyen de unos a otros a través de referencias explícitas.

El proyecto define tres pipelines en `alloy/values.yaml`:

### Pipeline 1 — Métricas → Mimir

Descubre pods de Kubernetes, filtra los relevantes y hace scraping de sus métricas Prometheus para enviarlas a Mimir.

```alloy
discovery.kubernetes "pods" { role = "pod" }

discovery.relabel "pod_metrics" {
  targets = discovery.kubernetes.pods.targets
  // filtra por nombre de pod, puerto y fase
}

prometheus.scrape "kubernetes_pods" {
  targets    = discovery.relabel.pod_metrics.output
  forward_to = [prometheus.remote_write.mimir.receiver]
}

prometheus.remote_write "mimir" {
  endpoint { url = "http://mimir-gateway.monitoring.svc.cluster.local/api/v1/push" }
}
```

### Pipeline 2 — Logs → Loki

Recolecta los logs de todos los pods vía la API de Kubernetes y los envía a Loki.

```alloy
loki.source.kubernetes "pods" {
  targets    = discovery.relabel.pod_logs.output
  forward_to = [loki.write.loki.receiver]
}

loki.write "loki" {
  endpoint { url = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push" }
}
```

### Pipeline 3 — Trazas OTLP → Tempo

Expone los puertos OTLP (gRPC `4317` y HTTP `4318`) para recibir trazas de los servicios instrumentados y las reenvía a Tempo. Las métricas generadas por las trazas se derivan también hacia Mimir.

```alloy
otelcol.receiver.otlp "default" {
  grpc { endpoint = "0.0.0.0:4317" }
  http { endpoint = "0.0.0.0:4318" }
  output {
    traces  = [otelcol.exporter.otlp.tempo.input]
    metrics = [otelcol.exporter.prometheus.mimir.input]
  }
}

otelcol.exporter.otlp "tempo" {
  client { endpoint = "tempo-distributor.monitoring.svc.cluster.local:4317" }
}
```

---

## 2. Servicio desplegado fuera del cluster

Monitorización de un servicio externo al cluster de Kubernetes, simulando un entorno fuera de la red interna. El backend corre en Docker Compose detrás de un API gateway y debe enviar telemetría al stack Grafana del cluster. Los principales retos son la conectividad, la instrumentación sin OTel Operator, y la seguridad del canal de telemetría.

Se plantean dos estrategias:

### Opción A — Alloy como agente local en Docker Compose *(desarrollada en ejemplo)*

```
┌─────────────────────────────────────────┐      ┌──────────────────────────────┐
│           Docker Compose                │      │       Cluster K8s            │
│                                         │      │                              │
│  Gateway (:80/:81)                      │      │  NodePort: Alloy  :30320     │
│      └── Backend (Python/NestJS)        │      │      └── Tempo               │
│           └── OTLP ──────► Alloy local  │─────►│      └── Mimir               │
│                                         │Bearer│      └── Loki                │
│                                         │Token │  NodePort: Langfuse :30900   │
└─────────────────────────────────────────┘      └──────────────────────────────┘
```

Se incluye una instancia de Alloy en el propio Docker Compose. El backend envía OTLP a Alloy localmente (red privada del Compose, sin autenticación). Alloy recolecta además los logs del daemon Docker y empuja todo al cluster vía NodePorts expuestos, añadiendo un API key como header en cada petición saliente.

* **Ventajas:** patrón estándar de producción (edge agent); el backend no tiene conocimiento del cluster; Alloy hace buffering si el cluster no está disponible.
* **Desventajas:** requiere exponer más NodePorts (Mimir, Loki, Tempo, Langfuse) y añade un componente al Compose.

### Opción B — Envío OTLP directo al Alloy del cluster

```
┌─────────────────────────────┐          ┌──────────────────────────────┐
│       Docker Compose        │          │       Cluster K8s            │
│                             │          │                              │
│  Gateway (:80/:81)          │          │  NodePort: Alloy OTLP :30320 │
│      └── Backend            │─────────►│                              │
│           OTLP con Bearer   │  Bearer  │  Alloy interno enruta        │
│                             │  Token   │  → Mimir / Loki / Tempo      │
└─────────────────────────────┘          └──────────────────────────────┘
```

El backend envía OTLP directamente al Alloy del cluster expuesto en un único NodePort, con un Bearer token como header. El Alloy interno enruta la telemetría a Mimir, Loki y Tempo como ya hace con los servicios internos.

* **Ventajas:** más simple; un solo NodePort a exponer; sin Alloy adicional en el Compose.
* **Desventajas:** el backend tiene acoplamiento directo al cluster; sin buffering local ante caídas; la validación del token requiere un proxy adicional delante del receiver de Alloy.

---

## 2.1. Arquitectura del Stack (Opción A)

* **Gateway (:80/:81):** API gateway. Recibe las peticiones externas y las redirige al backend. Nginx para Python, Apache para NestJS.
* **Aplicación (Python / NestJS):** Backend de negocio. Envía telemetría OTLP al Alloy local.
* **Grafana Alloy (local):** Agente incluido en el Docker Compose. Recibe OTLP del backend por red privada (sin autenticación) y reenvía todo al cluster con un Bearer token.
* **NodePort del Cluster (4320 → 30320):** Punto de entrada externo en el Alloy del cluster, protegido por Bearer token.
* **Alloy del Cluster (Pipeline 4):** Recibe la telemetría autenticada y la enruta hacia Tempo (trazas), Mimir (métricas) y Loki (logs), igual que hace con los servicios internos.
* **Langfuse + ClickHouse:** El backend instrumenta las llamadas LLM con el SDK de Langfuse, que escribe en ClickHouse vía el NodePort `30900`.

---

## 2.2. Backend Python — Instrumentación sin OTel Operator

Fuera del cluster no existe el OTel Operator, por lo que la auto-instrumentación se replica manualmente con la CLI `opentelemetry-instrument`. El resultado es equivalente: el código Python no necesita ningún cambio.

### 2.2.1. Dependencias OTel

Se añade un fichero separado para no contaminar el `requirements.txt` base:

```text
# external/requirements-otel.txt
opentelemetry-distro
opentelemetry-exporter-otlp
```

`opentelemetry-distro` incluye el SDK y la herramienta `opentelemetry-bootstrap`, que detecta los frameworks instalados (FastAPI, uvicorn, asyncio…) e instala sus instrumentors específicos.

### 2.2.2. Dockerfile

```dockerfile
# external/Dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY backend/requirements.txt external/requirements-otel.txt ./
RUN pip install --no-cache-dir -r requirements.txt -r requirements-otel.txt && \
    opentelemetry-bootstrap -a install
COPY backend/app.py .
EXPOSE 8000
CMD ["opentelemetry-instrument", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
```

El paso `opentelemetry-bootstrap -a install` detecta FastAPI/uvicorn ya instalados y añade sus instrumentors. El CMD envuelve uvicorn con `opentelemetry-instrument`, que activa la instrumentación en tiempo de arranque, exactamente como hace el OTel Operator mediante inyección en el pod.

### 2.2.3. Variables de entorno en Docker Compose

```yaml
# external/docker-compose.yml — servicio backend
environment:
  OTEL_SERVICE_NAME: backend
  OTEL_RESOURCE_ATTRIBUTES: service.namespace=external
  OTEL_EXPORTER_OTLP_ENDPOINT: http://alloy:4318
  OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
  OTEL_TRACES_EXPORTER: otlp
  OTEL_METRICS_EXPORTER: otlp
  OTEL_LOGS_EXPORTER: otlp
```

El backend envía a `http://alloy:4318` (nombre del servicio en la red `observability` del Compose). El Alloy local recibe sin autenticación porque comparten red privada.

### 2.2.4. Gateway Nginx

```nginx
# external/nginx/nginx.conf
server {
    listen 80;
    location / {
        proxy_pass http://backend:8000;
    }
}
```

---

## 2.3. Backend NestJS — Instrumentación sin OTel Operator

En el caso NestJS la instrumentación manual se realiza directamente desde el código TypeScript, sin el wrapper `opentelemetry-instrument`. Además, el gateway elegido es **Apache HTTP Server** en lugar de Nginx, y el backend necesita conectarse a Keycloak (expuesto con un certificado autofirmado) para validar los tokens JWT.

### 2.3.1. Instrumentación manual con `tracing.ts`

El SDK de OTel se inicializa en un módulo separado que se carga antes que la aplicación mediante la flag `-r` de Node.js. Esto replica exactamente lo que el OTel Operator haría en el cluster mediante la inyección de `NODE_OPTIONS`:

```typescript
// backend-nest/src/tracing.ts
import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';

const sdk = new NodeSDK({
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': { enabled: false },
    }),
  ],
});

sdk.start();
process.on('SIGTERM', () => sdk.shutdown());
```

La instrumentación de sistema de ficheros (`instrumentation-fs`) se deshabilita explícitamente para evitar ruido de trazas en operaciones internas del runtime de Node.

### 2.3.2. Dockerfile

```dockerfile
# external-nest/Dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY backend-nest/package*.json ./
RUN npm ci --ignore-scripts
COPY backend-nest/tsconfig.json .
COPY backend-nest/src ./src
RUN npx tsc

FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY backend-nest/package*.json ./
RUN npm ci --omit=dev --ignore-scripts
EXPOSE 3000
CMD ["node", "-r", "./dist/tracing.js", "dist/main.js"]
```

El flag `-r ./dist/tracing.js` hace que Node cargue `tracing.js` antes de cualquier otro módulo, garantizando que el SDK esté activo cuando se registran los instrumentors de Express/NestJS.

### 2.3.3. Variables de entorno en Docker Compose

```yaml
# external-nest/docker-compose.yml — servicio backend-nest
environment:
  OTEL_SERVICE_NAME: backend-nest
  OTEL_RESOURCE_ATTRIBUTES: service.namespace=external
  OTEL_EXPORTER_OTLP_ENDPOINT: http://alloy-nest:4318
  OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
  LANGFUSE_PUBLIC_KEY: ${LANGFUSE_PUBLIC_KEY}
  LANGFUSE_SECRET_KEY: ${LANGFUSE_SECRET_KEY}
  LANGFUSE_HOST: ${LANGFUSE_HOST}
  KEYCLOAK_URL: ${KEYCLOAK_URL:-https://keycloak.${MINIKUBE_IP}.nip.io}
  KEYCLOAK_REALM: ${KEYCLOAK_REALM:-poc}
  KEYCLOAK_AUDIENCE: ${KEYCLOAK_AUDIENCE:-backend-nest-external}
  NODE_TLS_REJECT_UNAUTHORIZED: "0"
```

### 2.3.4. Gateway Apache HTTP Server

El backend NestJS escucha en el puerto `3000` (vs `8000` del backend Python). El gateway usa **Apache HTTP Server** con `mod_proxy`:

```apache
# external-nest/apache/httpd.conf
ServerRoot "/usr/local/apache2"
Listen 81

LoadModule mpm_event_module    modules/mod_mpm_event.so
LoadModule authz_core_module   modules/mod_authz_core.so
LoadModule proxy_module        modules/mod_proxy.so
LoadModule proxy_http_module   modules/mod_proxy_http.so
LoadModule log_config_module   modules/mod_log_config.so
LoadModule unixd_module        modules/mod_unixd.so

User  daemon
Group daemon

<VirtualHost *:81>
    ProxyPreserveHost On
    ProxyPass        / http://backend-nest:3000/
    ProxyPassReverse / http://backend-nest:3000/
</VirtualHost>
```

Apache se expone en el puerto `81` (vs `80` de Nginx) para coexistir con el stack Python si ambos Compose están activos en el mismo host.

El servicio en `docker-compose.yml`:

```yaml
# external-nest/docker-compose.yml — servicio apache
services:
  apache:
    image: httpd:alpine
    ports:
      - "81:81"
    volumes:
      - ./apache/httpd.conf:/usr/local/apache2/conf/httpd.conf:ro
    networks:
      - observability-nest
    depends_on:
      - backend-nest
```

### 2.3.5. Certificados autofirmados — `NODE_TLS_REJECT_UNAUTHORIZED`

El backend NestJS valida los tokens JWT de los clientes consultando el JWKS endpoint de Keycloak. En el entorno externo, Keycloak está expuesto mediante un Ingress con dominio `nip.io` (ej. `keycloak.192.168.X.Y.nip.io`) cuyo certificado TLS es autofirmado o emitido por una CA interna del cluster.

La librería `jose` (usada en `JwksService`) rechazará por defecto conexiones HTTPS con certificados no verificables, produciendo un error `unable to verify the first certificate` al arrancar el backend. La solución para entornos de desarrollo y PoC es:

```yaml
NODE_TLS_REJECT_UNAUTHORIZED: "0"
```

Esta variable deshabilita la verificación de certificados TLS en **toda** la instancia de Node.js, no solo en las llamadas a Keycloak. Esto afecta también a cualquier llamada HTTPS saliente (Langfuse, APIs externas, etc.).

> **Advertencia de seguridad:** `NODE_TLS_REJECT_UNAUTHORIZED=0` **nunca debe usarse en producción**. Abre el proceso a ataques MITM. En producción la alternativa correcta es:
> 1. Provisionar un certificado firmado por una CA de confianza (Let's Encrypt via cert-manager).
> 2. O bien añadir la CA interna del cluster al bundle de CAs del contenedor (`NODE_EXTRA_CA_CERTS=/path/to/ca.crt`).

### 2.3.6. Redes Docker Compose

El Compose de NestJS externo define dos redes:

```yaml
networks:
  observability-nest:
    driver: bridge      # red interna: apache ↔ backend-nest ↔ alloy-nest
  minikube:
    external: true      # red del cluster minikube: acceso a Keycloak, Langfuse, Alloy
    name: minikube
```

Los servicios `backend-nest` y `alloy-nest` están en ambas redes: la interna para comunicarse entre sí y la red `minikube` para alcanzar los NodePorts del cluster (Keycloak para JWKS, Langfuse para trazas LLM, Alloy para telemetría).

---

## 2.4. Integración con Langfuse

Idéntica al caso 1 en cuanto al SDK. La diferencia es que las credenciales se pasan mediante el fichero `.env` del Compose en lugar de Secrets de Kubernetes.

```bash
# external/.env  (basado en .env.example)
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
LANGFUSE_HOST=http://<CLUSTER_NODE_IP>:30900
```

> **Nota sobre flush asíncrono:** `_lf.flush()` es una llamada bloqueante síncrona. Dentro de un endpoint `async` de FastAPI bloquea el event loop de uvicorn hasta que Langfuse responde o agota el timeout TCP (60+ s), lo que provoca 504 en el gateway. Se ejecuta en un thread pool con techo de 5 s:
>
> ```python
> await asyncio.wait_for(
>     asyncio.get_event_loop().run_in_executor(None, _lf.flush),
>     timeout=5.0,
> )
> ```

---

## 2.5. Pipeline del Alloy local (Docker Compose)

El Alloy local actúa como agente edge: recibe toda la señal OTLP del backend y la reenvía autenticada al cluster. La misma configuración `config.alloy` es compartida por los Compose de Python y NestJS:

```alloy
# external/alloy/config.alloy

// Recibe trazas, métricas y logs del backend (red privada, sin auth)
otelcol.receiver.otlp "local" {
  grpc { endpoint = "0.0.0.0:4317" }
  http { endpoint = "0.0.0.0:4318" }
  output {
    traces  = [otelcol.exporter.otlphttp.cluster.input]
    metrics = [otelcol.exporter.otlphttp.cluster.input]
    logs    = [otelcol.exporter.otlphttp.cluster.input]
  }
}

// Bearer token leído desde variable de entorno
otelcol.auth.bearer "cluster" {
  token = env("ALLOY_BEARER_TOKEN")
}

// Reenvía al receiver externo del Alloy del cluster vía HTTP
otelcol.exporter.otlphttp "cluster" {
  client {
    endpoint = env("CLUSTER_ALLOY_ENDPOINT")   // http://<NODE_IP>:30320
    auth     = otelcol.auth.bearer.cluster.handler
    tls { insecure = true }
  }
}
```

Las variables `ALLOY_BEARER_TOKEN` y `CLUSTER_ALLOY_ENDPOINT` se inyectan desde el `.env`:

```bash
ALLOY_BEARER_TOKEN=poc-alloy-external-token   # debe coincidir con el Secret K8s
CLUSTER_ALLOY_ENDPOINT=http://<CLUSTER_NODE_IP>:30320
```

---

## 2.6. Canal externo en el Alloy del Cluster (K8s)

El cluster expone un receiver OTLP adicional exclusivo para tráfico externo autenticado.

### 2.6.1. Secret con el Bearer token

```yaml
# alloy/external-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: alloy-external-token
  namespace: monitoring
type: Opaque
stringData:
  token: poc-alloy-external-token   # debe coincidir con ALLOY_BEARER_TOKEN del .env
```

### 2.6.2. NodePort para el receiver externo

```yaml
# alloy/nodeport-external.yaml
apiVersion: v1
kind: Service
metadata:
  name: alloy-external
  namespace: monitoring
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: alloy
  ports:
    - name: otlp-http-ext
      port: 4320
      targetPort: 4320
      protocol: TCP
      nodePort: 30320
```

### 2.6.3. Pipeline 4 en Alloy (values.yaml)

Se añade un cuarto pipeline al Alloy del cluster que autentica el tráfico entrante y lo enruta a los mismos backends internos:

```alloy
// Pipeline 4 — OTLP externo autenticado → Tempo / Mimir / Loki
otelcol.auth.bearer "external" {
  token = env("EXTERNAL_API_TOKEN")   // montado desde alloy-external-token
}

otelcol.receiver.otlp "external" {
  grpc {
    endpoint = "0.0.0.0:4319"
    auth     = otelcol.auth.bearer.external.handler
  }
  http {
    endpoint = "0.0.0.0:4320"
    auth     = otelcol.auth.bearer.external.handler
  }
  output {
    traces  = [otelcol.exporter.otlp.tempo.input]
    metrics = [otelcol.exporter.prometheus.mimir.input]
    logs    = [otelcol.exporter.loki.logs.input]
  }
}

otelcol.exporter.loki "logs" {
  forward_to = [loki.write.loki.receiver]
}
```

El puerto `4319` (gRPC) y `4320` (HTTP) se declaran también en `extraPorts` del chart de Alloy. Solo `4320` se expone como NodePort para el tráfico externo; `4319` queda reservado para uso interno.

El secret se monta mediante `extraEnv` en `alloy/values.yaml`:

```yaml
extraEnv:
  - name: EXTERNAL_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: alloy-external-token
        key: token
```

---

## 2.7. Resumen del flujo completo

### Python externo

```
[curl / cliente]
      │ HTTP :80
      ▼
   Nginx (Docker Compose)
      │ proxy_pass :8000
      ▼
   Backend FastAPI
   ├── OTLP http/protobuf → Alloy local :4318
   └── Langfuse SDK       → Langfuse NodePort :30900 → ClickHouse
      │
      ▼
   Alloy local (Docker Compose)
      │ OTLP HTTP + Bearer token
      ▼
   Alloy cluster NodePort :30320 (puerto interno 4320)
   ├── traces  → Tempo
   ├── metrics → Mimir
   └── logs    → Loki
```

### NestJS externo

```
[curl / cliente]
      │ HTTP :81
      ▼
   Apache HTTP Server (Docker Compose)
      │ ProxyPass :3000
      ▼
   Backend NestJS  (tracing.ts cargado vía node -r)
   ├── OTLP http/protobuf → Alloy local :4318
   ├── Langfuse SDK       → Langfuse NodePort :30900 → ClickHouse
   └── JWKS fetch         → Keycloak nip.io (TLS autofirmado, NODE_TLS_REJECT_UNAUTHORIZED=0)
      │
      ▼
   Alloy local (Docker Compose, config.alloy compartida)
      │ OTLP HTTP + Bearer token
      ▼
   Alloy cluster NodePort :30320 (puerto interno 4320)
   ├── traces  → Tempo
   ├── metrics → Mimir
   └── logs    → Loki
```

---

## Referencias

* [Instrument an application with OpenTelemetry](https://grafana.com/docs/opentelemetry/instrument/)
* [OTel Operator – Auto-instrumentation](https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/)
* [Langfuse SDK (Python)](https://langfuse.com/docs/sdk/python)
* [Alloy – Sintaxis de configuración](https://grafana.com/docs/alloy/latest/get-started/configuration-syntax/)
* [Alloy – Recopilar datos OpenTelemetry](https://grafana.com/docs/alloy/latest/collect/opentelemetry-data/)
