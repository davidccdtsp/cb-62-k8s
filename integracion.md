# Guía de integración


Esta guía detalla la integración de diferentes componentes en un stack distribuido de monitorización Grafana con Mimir, Loki, Tempo y Alloy como colector, junto con Langfuse para trazas contra LLMs.

---

## Casos de uso

1. Servicio desplegado dentro del propio cluster.
2. Servicio desplegado fuera del cluster.

## 1. Servicio desplegado dentro del propio cluster

Monitorización integral (trazas, métricas y logs) de un servicio desplegado dentro del propio cluster. El servicio cuenta con la particularidad de realizar consultas a LLMs, esta característica implica que cierta información como pueden ser la longitud de los prompts, calidad de la respuesta, número de tokens, modelo empleado quedan fuera de las capacidades de observabilidad de la monitorización clásica. Con el fin de salvar esta carencia se integran tanto la monitorización clásica (Stack Grafana) como la específica mediante **Langfuse**. 

Estrategia de instrumentación híbrida:
1. **APM Tradicional (Application Performance Monitoring):** Se utiliza **OpenTelemetry (OTel) Operator** para auto-instrumentar el servicio Python sin modificar el código base. Este extrae trazas HTTP, consultas a bases de datos y métricas del sistema.
2. **Trazabilidad LLM:** Se utiliza el SDK de **Langfuse** para instrumentar específicamente las llamadas al LLM.

**Flujo de Datos:**
* Los datos de OTel viajan hacia **Grafana Alloy** (el colector central), el cual los enruta hacia **Tempo** (trazas), **Mimir** (métricas) y **Loki** (logs).
* Los datos de Langfuse viajan al backend de Langfuse, el cual almacena la información en **ClickHouse**. Grafana visualiza estos datos conectándose directamente a ClickHouse como *datasource*.

---

### 1.1. Arquitectura del Stack

* **Aplicación (Python):** Servicio de negocio que ejecuta la lógica y consume LLMs.
* **OpenTelemetry Operator:** Componente de Kubernetes que inyecta automáticamente el agente de OTel en los pods de Python para capturar telemetría estándar.
* **Grafana Alloy:** El colector (basado en OpenTelemetry y Prometheus). Recibe OTLP, hace *scraping* de métricas de pods y recolecta logs.
* **Mimir:** Base de datos de series temporales a largo plazo para almacenar **métricas**.
* **Loki:** Sistema de agregación de **logs** inspirado en Prometheus.
* **Tempo:** Backend de almacenamiento distribuido para **trazas**.
* **Langfuse + ClickHouse:** Langfuse recopila la telemetría de IA generativa y la guarda en ClickHouse. Grafana consulta ClickHouse para cruzar métricas de negocio/IA con la infraestructura.
---

### 1.2. Cambios Acometidos en el Backend (Python)

Gracias al uso de **OpenTelemetry Operator**, los cambios en el código para la instrumentación base son mínimos o nulos. La auto-instrumentación se inyecta mediante anotaciones en el `Deployment` de Kubernetes.

> **Nota:** Dado que Alloy ya expone endpoints OTLP (`4317` gRPC y `4318` HTTP), **no es necesario instalar un OpenTelemetry Collector adicional**. El OTel Operator es un componente opcional cuyo único propósito es inyectar automáticamente el agente de instrumentación en los pods sin tocar el código. Si se prefiere instrumentar la aplicación manualmente con el SDK de OTel, el operador no hace falta.

### 1.2.1. Instalación del OTel Operator

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --namespace monitoring \
  --set "manager.collectorImage.repository=otel/opentelemetry-collector-contrib"
```

### 1.2.2. Recurso `Instrumentation`

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

### 1.3. Anotación en el Deployment

Con el recurso `Instrumentation` creado, basta con añadir una anotación al pod para que el operador inyecte el agente automáticamente:

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

## 1.4. Integración con Langfuse (Trazabilidad LLM)

La instrumentación OTel no captura información semántica de las llamadas a LLMs (tokens, modelo, calidad). Para eso se usa el SDK de Langfuse directamente en el código.

> **Nota:** La integración mediante el SDK de Langfuse solo es necesaria cuando se despliegan herramientas que hacen uso de LLMs fuera de un framework. Plataformas como Dify o LangGraph pueden integrarse fácilmente con Langfuse sin necesidad del SDK.


### 1.4.1. Inicialización

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

### 1.4.2. Instrumentación de una llamada LLM

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

### 1.5. Configuración de Pipelines en Alloy

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

Monitorización de un servicio externo al cluster de Kubernetes, simulando un entorno fuera de la red interna. El backend corre en Docker Compose detrás de un API gateway (Traefik) y debe enviar telemetría al stack Grafana del cluster. Los principales retos son la conectividad, la instrumentación sin OTel Operator, y la seguridad del canal de telemetría.

Se plantean dos estrategias:

### Opción A — Alloy como agente local en Docker Compose *(desarrolada en ejemplo)*

```
┌─────────────────────────────────────────┐      ┌──────────────────────────────┐
│           Docker Compose                │      │       Cluster K8s            │
│                                         │      │                              │
│  Nginx (:80)                            │      │  NodePort: Alloy  :30320     │
│      └── Backend (FastAPI)              │      │      └── Tempo               │
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
│  Nginx (:80)                │          │  NodePort: Alloy OTLP :30320 │
│      └── Backend (FastAPI)  │─────────►│                              │
│           OTLP con Bearer   │  Bearer  │  Alloy interno enruta        │
│                             │  Token   │  → Mimir / Loki / Tempo      │
└─────────────────────────────┘          └──────────────────────────────┘
```

El backend envía OTLP directamente al Alloy del cluster expuesto en un único NodePort, con un Bearer token como header. El Alloy interno enruta la telemetría a Mimir, Loki y Tempo como ya hace con los servicios internos.

* **Ventajas:** más simple; un solo NodePort a exponer; sin Alloy adicional en el Compose.
* **Desventajas:** el backend tiene acoplamiento directo al cluster; sin buffering local ante caídas; la validación del token requiere un proxy adicional delante del receiver de Alloy.

---

## 2.1. Arquitectura del Stack (Opción A)

* **Nginx (:80):** API gateway. Recibe las peticiones externas y las redirige al backend.
* **Aplicación (Python / FastAPI):** Backend de negocio. Envía telemetría OTLP al Alloy local.
* **Grafana Alloy (local):** Agente incluido en el Docker Compose. Recibe OTLP del backend por red privada (sin autenticación) y reenvía todo al cluster con un Bearer token.
* **NodePort del Cluster (4320 → 30320):** Punto de entrada externo en el Alloy del cluster, protegido por Bearer token.
* **Alloy del Cluster (Pipeline 4):** Recibe la telemetría autenticada y la enruta hacia Tempo (trazas), Mimir (métricas) y Loki (logs), igual que hace con los servicios internos.
* **Langfuse + ClickHouse:** El backend instrumenta las llamadas LLM con el SDK de Langfuse, que escribe en ClickHouse vía el NodePort `30900`.

---

## 2.2. Instrumentación del Backend sin OTel Operator

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

La configuración del exportador se pasa íntegramente por variables de entorno, sin tocar el código:

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

---

## 2.3. Integración con Langfuse

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

## 2.4. Pipeline del Alloy local (Docker Compose)

El Alloy local actúa como agente edge: recibe toda la señal OTLP del backend y la reenvía autenticada al cluster.

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

## 2.5. Canal externo en el Alloy del Cluster (K8s)

El cluster expone un receiver OTLP adicional exclusivo para tráfico externo autenticado.

### 2.5.1. Secret con el Bearer token

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

### 2.5.2. NodePort para el receiver externo

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

### 2.5.3. Pipeline 4 en Alloy (values.yaml)

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

## 2.6. Resumen del flujo completo

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

---

## Referencias

* [Instrument an application with OpenTelemetry](https://grafana.com/docs/opentelemetry/instrument/)
* [OTel Operator – Auto-instrumentation](https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/)
* [Langfuse SDK (Python)](https://langfuse.com/docs/sdk/python)
* [Alloy – Sintaxis de configuración](https://grafana.com/docs/alloy/latest/get-started/configuration-syntax/)
* [Alloy – Recopilar datos OpenTelemetry](https://grafana.com/docs/alloy/latest/collect/opentelemetry-data/)